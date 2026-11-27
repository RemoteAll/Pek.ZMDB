//! 单表存储：主存储（ID → 实体句柄）+ 类型感知索引 + 唯一约束索引。
//!
//! # 锁策略（读多写少）
//!
//! 整表状态放在一把 `std.Io.RwLock` 中：
//! - **读**（按 ID/字段/范围/分页查找）取共享锁，多线程无阻塞并发；
//! - **写**（插入/更新/删除/批量）取独占锁，单写者保证「主存储 + 普通索引 + 唯一索引」原子一致。
//!
//! 实体在堆上以 [`entity.Ref`]（原子引用计数）持有：读操作返回句柄，
//! 删除后内存延迟到最后一次 `release` 才释放 —— 与 Rust 版 `Arc<T>` 一致。

const std = @import("std");
const zzig = @import("zzig");

const entity = @import("entity.zig");
const errors = @import("error.zig");
const index = @import("index.zig");
const json = @import("json.zig");
const model = @import("model.zig");
const ordered = @import("ordered.zig");
const persist = @import("persist.zig");
const unique = @import("unique.zig");
const value = @import("value.zig");

const Error = errors.Error;
const Field = model.Field;
const CompositeUniqueRule = model.CompositeUniqueRule;
const Violation = model.Violation;
const FieldKind = value.FieldKind;
const Key = value.Key;
const Value = value.Value;

const log = std.log.scoped(.zmdb);

/// 加载数据文件的上限（防止误读超大文件拖垮进程）。
const max_load_bytes: usize = 256 * 1024 * 1024;

/// 类型擦除后的表接口（`MemoryDb` 的异构容器使用）。
pub const AnyTable = struct {
    ptr: *anyopaque,
    type_name: []const u8,
    vtable: *const VTable,

    pub const VTable = struct {
        /// 释放全部实体并销毁表本身。
        destroy: *const fn (ptr: *anyopaque) void,
        clear: *const fn (ptr: *anyopaque) void,
        isDirty: *const fn (ptr: *anyopaque) bool,
        markDirty: *const fn (ptr: *anyopaque) bool,
        saveTo: *const fn (ptr: *anyopaque, path: []const u8, pretty: bool) anyerror!u64,
        statistics: *const fn (ptr: *anyopaque, gpa: std.mem.Allocator) anyerror!model.TableStatistics,
        reloadIfChanged: *const fn (ptr: *anyopaque, path: []const u8) anyerror!bool,
    };

    pub fn cast(comptime T: type, self: AnyTable) *Table(T) {
        return @ptrCast(@alignCast(self.ptr));
    }
};

/// 单表实现（`T` 为实体类型，契约见 `entity.zig`）。
pub fn Table(comptime T: type) type {
    entity.assertContract(T);

    return struct {
        const Self = @This();

        pub const RefT = entity.Ref(T);
        pub const ListT = entity.List(T);
        pub const PageT = entity.Page(T);

        gpa: std.mem.Allocator,
        io: std.Io,
        type_name: []const u8,
        fields: []const Field,
        composites: []const CompositeUniqueRule,
        not_save: bool,

        lock: std.Io.RwLock = .init,
        by_id: std.AutoHashMap(i64, *RefT.Box),
        /// 升序 ID 表（墓碑式删除）：`findAll` / 分页 / 落盘无需再排序。
        ids: ordered.IdSet = .{},
        indexes: index.IndexSet,
        uniques: unique.UniqueSet,
        next_id: i64 = 1,
        loaded: bool = false,

        dirty: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        /// 已加载/已写盘文件的签名（mtime + 大小）：热加载的变化驱动判据。
        file_sig: ?persist.FileSignature = null,
        /// 行级同步哈希（ID → 上次与文件一致时的行内容哈希）：双向热更新的三方合并基准。
        synced: std.AutoHashMapUnmanaged(i64, u64) = .empty,
        /// 上次热加载检查时间（毫秒，读入口节流用）。
        last_reload_check_ms: std.atomic.Value(i64) = std.atomic.Value(i64).init(0),
        save_mutex: std.Io.Mutex = .init,
        persist_count: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
        persisted_bytes: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
        last_persist_ms: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

        // ------------------------------------------------------------------
        // 生命周期
        // ------------------------------------------------------------------

        pub fn init(gpa: std.mem.Allocator, io: std.Io) !Self {
            const declared_fields = entity.fieldsOf(T);
            var indexes = try index.IndexSet.initWithFields(gpa, declared_fields);
            errdefer indexes.deinit(gpa);
            return .{
                .gpa = gpa,
                .io = io,
                .type_name = entity.typeName(T),
                .fields = declared_fields,
                .composites = entity.compositesOf(T),
                .not_save = entity.notSave(T),
                .by_id = std.AutoHashMap(i64, *RefT.Box).init(gpa),
                .indexes = indexes,
                .uniques = unique.UniqueSet.init(gpa),
            };
        }

        pub fn deinit(self: *Self) void {
            self.lock.lockUncancelable(self.io);
            var iterator = self.by_id.valueIterator();
            while (iterator.next()) |box_ptr| {
                (RefT{ .box = box_ptr.* }).release();
            }
            self.by_id.deinit();
            self.ids.deinit(self.gpa);
            self.synced.deinit(self.gpa);
            self.indexes.deinit(self.gpa);
            self.uniques.deinit();
            self.lock.unlock(self.io);
        }

        /// 类型擦除视图（`MemoryDb` 异构容器使用）。
        pub fn asAny(self: *Self) AnyTable {
            return .{ .ptr = self, .type_name = self.type_name, .vtable = &vtable };
        }

        const vtable: AnyTable.VTable = .{
            .destroy = vtableDestroy,
            .clear = vtableClear,
            .isDirty = vtableIsDirty,
            .markDirty = vtableMarkDirty,
            .saveTo = vtableSaveTo,
            .statistics = vtableStatistics,
            .reloadIfChanged = vtableReloadIfChanged,
        };

        fn vtableMarkDirty(ptr: *anyopaque) bool {
            const self: *Self = @ptrCast(@alignCast(ptr));
            return self.markDirty();
        }

        fn vtableDestroy(ptr: *anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            const gpa = self.gpa;
            self.deinit();
            gpa.destroy(self);
        }

        fn vtableClear(ptr: *anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            self.clear();
        }

        fn vtableIsDirty(ptr: *anyopaque) bool {
            const self: *Self = @ptrCast(@alignCast(ptr));
            return self.isDirty();
        }

        fn vtableSaveTo(ptr: *anyopaque, path: []const u8, pretty: bool) anyerror!u64 {
            const self: *Self = @ptrCast(@alignCast(ptr));
            return self.saveTo(path, pretty);
        }

        fn vtableStatistics(ptr: *anyopaque, gpa: std.mem.Allocator) anyerror!model.TableStatistics {
            const self: *Self = @ptrCast(@alignCast(ptr));
            return self.statistics(gpa);
        }

        fn vtableReloadIfChanged(ptr: *anyopaque, path: []const u8) anyerror!bool {
            const self: *Self = @ptrCast(@alignCast(ptr));
            return self.reloadIfChanged(path);
        }

        // ------------------------------------------------------------------
        // 脏标记 / 统计计数
        // ------------------------------------------------------------------

        pub fn isInMemory(self: *Self) bool {
            return self.not_save;
        }

        pub fn isDirty(self: *Self) bool {
            return self.dirty.load(.acquire);
        }

        /// 标记脏数据（后台持久化线程据此写盘）。
        ///
        /// 返回 `true` 表示本次从「干净」变为「脏」（调用方据此唤醒后台线程，
        /// 连续写入时只在第一次唤醒，减少调度锁竞争）。
        pub fn markDirty(self: *Self) bool {
            if (self.not_save) return false;
            return !self.dirty.swap(true, .acq_rel);
        }

        pub fn rowCount(self: *Self) usize {
            self.lock.lockSharedUncancelable(self.io);
            defer self.lock.unlockShared(self.io);
            return self.by_id.count();
        }

        // ------------------------------------------------------------------
        // 加载
        // ------------------------------------------------------------------

        /// 从磁盘加载（首次访问时调用一次；文件不存在视为空表）。
        ///
        /// 兼容 C# 版 `Data/{Type.FullName}.json`：
        /// - 加载时**修正 ID 计数器**为 `max(id)+1`（C# 版未修正，加载后新增会从 1 开始覆盖旧数据）；
        /// - 唯一冲突的对象**直接跳过**并记警告（C# 版对象留在表中但唯一索引缺失，状态不一致）。
        pub fn load(self: *Self, path: []const u8) void {
            const sig = persist.FileSignature.ofFile(self.io, path) catch |err| blk: {
                log.warn("读取 {s} 数据文件签名失败（{s}）：{s}", .{ self.type_name, path, @errorName(err) });
                break :blk null;
            };
            {
                self.lock.lockUncancelable(self.io);
                defer self.lock.unlock(self.io);
                if (self.loaded) return;
                self.loaded = true;
                self.file_sig = sig;
            }
            if (self.not_save) return;

            const maybe_text = persist.readFileAlloc(self.io, self.gpa, path, max_load_bytes) catch |err| {
                log.err("加载 {s} 失败（数据文件 {s}）：{s}；将使用空表", .{ self.type_name, path, @errorName(err) });
                return;
            };
            const text = maybe_text orelse return;
            defer self.gpa.free(text);
            if (std.mem.trim(u8, text, " \t\r\n").len == 0) return;

            var arena = std.heap.ArenaAllocator.init(self.gpa);
            defer arena.deinit();
            const arena_gpa = arena.allocator();

            const node = json.parseLax(arena_gpa, text) catch |err| {
                log.err("解析 {s} 失败（数据文件 {s}）：{s}；将使用空表", .{ self.type_name, path, @errorName(err) });
                return;
            };

            self.lock.lockUncancelable(self.io);
            defer self.lock.unlock(self.io);
            switch (node) {
                .list => |items| {
                    // 预分配容量：避免逐行扩容时的重复 rehash / 搬移
                    self.by_id.ensureTotalCapacity(@intCast(items.len)) catch {};
                    self.ids.ids.ensureTotalCapacity(self.gpa, items.len) catch {};
                    for (items) |item| self.loadItem(item, path, arena_gpa);
                },
                .object => self.loadItem(node, path, arena_gpa),
                .null => {},
                else => log.err("{s} 数据文件顶层应为对象或数组（{s}）；将使用空表", .{ self.type_name, path }),
            }
            // 建立行级同步基准：后续热加载据此做三方合并
            self.rebuildSyncedLocked();
        }

        /// 解析单个 JSON 对象为实体（**不含** ID 校验与索引安装；调用方接管/释放）。
        fn parseEntity(self: *Self, node: json.Node, arena_gpa: std.mem.Allocator) ?T {
            if (node != .object) return null;
            var object = T.initEmpty(self.gpa);
            for (node.object) |entry| {
                const name = entry.name;
                if (std.ascii.eqlIgnoreCase(name, "Id")) {
                    if (nodeToI64(entry.value)) |id| object.setId(id);
                    continue;
                }
                if (std.ascii.eqlIgnoreCase(name, "Name")) {
                    if (nodeToText(arena_gpa, entry.value)) |text| {
                        entity.setName(&object, text) catch {};
                    }
                    continue;
                }
                const field = self.findDeclaredField(name) orelse continue;
                const converted = json.nodeToValue(entry.value, arena_gpa) catch continue;
                _ = object.setField(field.name, converted) catch false;
            }
            return object;
        }

        /// 行内容哈希（零分配）：双向热更新三方合并的判据。
        ///
        /// 只按**规范化后的值**计算（文本原字节、整数 i64、浮点 f64、时间秒），
        /// 因此「内存对象」与「从文件装载的对象」内容等价时哈希一致。
        pub fn entityHash(self: *Self, object: *const T) u64 {
            var hasher = std.hash.Wyhash.init(0);
            const id = object.getId();
            hasher.update(std.mem.asBytes(&id));
            hasher.update(entity.getName(object));
            for (self.fields) |field| {
                if (!field.save) continue;
                if (index.isIdOrName(field.name)) continue;
                const raw = object.getField(field.name) orelse {
                    hasher.update(&[_]u8{0});
                    continue;
                };
                hasher.update(&[_]u8{@backingInt(std.meta.activeTag(raw))});
                switch (raw) {
                    .null => {},
                    .boolean => |v| hasher.update(&[_]u8{@intFromBool(v)}),
                    .int => |v| hasher.update(std.mem.asBytes(&v)),
                    .float => |v| hasher.update(std.mem.asBytes(&v)),
                    .decimal => |d| {
                        const scaled = d.toI64() orelse 0;
                        hasher.update(std.mem.asBytes(&scaled));
                    },
                    .text => |text| {
                        if (field.kind == .json) {
                            hashJsonText(&hasher, text);
                        } else {
                            hasher.update(text);
                        }
                    },
                    .blob => |bytes| hasher.update(bytes),
                    .datetime => |dt| {
                        const seconds = dt.toUnixSeconds();
                        hasher.update(std.mem.asBytes(&seconds));
                    },
                }
            }
            return hasher.final();
        }

        /// 重建行级同步哈希（**持有写锁**；`load` / `saveTo` 后调用）。
        fn rebuildSyncedLocked(self: *Self) void {
            self.synced.clearRetainingCapacity();
            var iterator = self.by_id.iterator();
            while (iterator.next()) |entry| {
                const id = entry.key_ptr.*;
                const object: *const T = &entry.value_ptr.*.value;
                self.synced.put(self.gpa, id, self.entityHash(object)) catch {
                    // 内存不足：清空基准，热加载退化为「文件整体覆盖」
                    self.synced.clearRetainingCapacity();
                    return;
                };
            }
        }

        fn refreshSynced(self: *Self) void {
            self.lock.lockUncancelable(self.io);
            defer self.lock.unlock(self.io);
            self.rebuildSyncedLocked();
        }

        fn loadItem(self: *Self, node: json.Node, path: []const u8, arena_gpa: std.mem.Allocator) void {
            const parsed = self.parseEntity(node, arena_gpa) orelse {
                log.warn("{s}：数组元素不是对象，已跳过（数据文件 {s}）", .{ self.type_name, path });
                return;
            };
            var object = parsed;
            var consumed = false;
            defer if (!consumed) object.deinit();

            const id = object.getId();
            if (id <= 0) {
                log.warn("{s}：发现无效对象 ID {d}，已跳过（数据文件 {s}）", .{ self.type_name, id, path });
                return;
            }
            if (self.by_id.contains(id)) {
                log.warn("{s}：发现重复对象 ID {d}，已跳过（数据文件 {s}）", .{ self.type_name, id, path });
                return;
            }

            // 先建句柄，之后统一读写堆上的实体（避免栈副本与堆副本双释放）
            const ref = RefT.create(self.gpa, object) catch |err| {
                log.err("{s}：创建实体句柄失败（ID {d}）：{s}", .{ self.type_name, id, @errorName(err) });
                return;
            };
            consumed = true;
            const handle = ref.getMut();

            self.uniques.add(self.fields, self.composites, id, handle, null) catch |err| {
                log.warn("{s}：加载时唯一约束冲突，已跳过对象 ID {d}（{s}）", .{ self.type_name, id, @errorName(err) });
                ref.release();
                return;
            };
            self.indexEntity(id, handle, null) catch |err| {
                log.err("{s}：加载对象 ID {d} 建索引失败：{s}", .{ self.type_name, id, @errorName(err) });
                self.uniques.remove(self.fields, self.composites, handle) catch {};
                ref.release();
                return;
            };
            self.by_id.put(id, ref.box) catch |err| {
                log.err("{s}：加载对象 ID {d} 写入主存储失败：{s}", .{ self.type_name, id, @errorName(err) });
                self.removeIndexEntity(id, handle) catch {};
                self.uniques.remove(self.fields, self.composites, handle) catch {};
                ref.release();
                return;
            };
            _ = self.ids.insert(self.gpa, id) catch |err| {
                log.err("{s}：加载对象 ID {d} 写入 ID 顺序表失败：{s}", .{ self.type_name, id, @errorName(err) });
            };
            if (id >= self.next_id) self.next_id = id +| 1;
        }

        // ------------------------------------------------------------------
        // 写操作
        // ------------------------------------------------------------------

        /// 插入实体并分配 ID（失败时由库负责释放传入对象）。
        pub fn insert(self: *Self, object: T, violation: ?*Violation) Error!i64 {
            self.lock.lockUncancelable(self.io);
            defer self.lock.unlock(self.io);
            return self.insertLocked(object, null, violation);
        }

        /// 插入实体，只对指定字段建立普通索引（对应 C# `InsertByIndex`）。
        pub fn insertByIndex(self: *Self, object: T, only: []const []const u8, violation: ?*Violation) Error!i64 {
            self.lock.lockUncancelable(self.io);
            defer self.lock.unlock(self.io);
            return self.insertLocked(object, only, violation);
        }

        /// 批量插入（同一把写锁内完成）。
        ///
        /// 唯一冲突时**已插入的行保留**（与 C# / Rust 语义一致），未插入的对象由库释放；
        /// 成功返回的 ID 切片由调用方释放，**传入的对象归库所有，不得再 deinit**。
        pub fn insertBatch(self: *Self, objects: []T, violation: ?*Violation) Error![]i64 {
            const ids = try self.gpa.alloc(i64, objects.len);
            errdefer self.gpa.free(ids);

            self.lock.lockUncancelable(self.io);
            defer self.lock.unlock(self.io);

            // 预留容量：批量插入不再逐行扩容/搬移
            try self.by_id.ensureUnusedCapacity(@intCast(objects.len));
            try self.ids.ids.ensureUnusedCapacity(self.gpa, objects.len);

            var inserted: usize = 0;
            while (inserted < objects.len) : (inserted += 1) {
                ids[inserted] = self.insertLocked(objects[inserted], null, violation) catch |err| {
                    // 失败的那一条已由 insertLocked 释放；只清理其后未处理的
                    for (objects[inserted + 1 ..]) |*object| object.deinit();
                    return err;
                };
            }
            return ids;
        }

        /// 调用方必须已持有独占锁。
        fn insertLocked(self: *Self, object_arg: T, only: ?[]const []const u8, violation: ?*Violation) Error!i64 {
            var object = object_arg;
            var consumed = false;
            errdefer if (!consumed) object.deinit();

            const id = self.next_id;
            object.setId(id);

            const ref = try RefT.create(self.gpa, object);
            consumed = true;
            errdefer ref.release();

            const handle = ref.getMut();
            try self.uniques.add(self.fields, self.composites, id, handle, violation);
            errdefer self.uniques.remove(self.fields, self.composites, handle) catch {};
            try self.indexEntity(id, handle, only);
            errdefer self.removeIndexEntity(id, handle) catch {};

            _ = try self.ids.insert(self.gpa, id);
            errdefer _ = self.ids.remove(id);

            try self.by_id.put(id, ref.box);
            self.next_id = id +| 1;
            return id;
        }

        /// 以指定 ID 安装实体（**调用方必须已持写锁**；热加载合并用）。
        fn installRowLocked(self: *Self, id: i64, object_arg: T) Error!void {
            var object = object_arg;
            var consumed = false;
            errdefer if (!consumed) object.deinit();
            object.setId(id);

            const ref = try RefT.create(self.gpa, object);
            consumed = true;
            errdefer ref.release();

            const handle = ref.getMut();
            try self.uniques.add(self.fields, self.composites, id, handle, null);
            errdefer self.uniques.remove(self.fields, self.composites, handle) catch {};
            try self.indexEntity(id, handle, null);
            errdefer self.removeIndexEntity(id, handle) catch {};

            _ = try self.ids.insert(self.gpa, id);
            errdefer _ = self.ids.remove(id);

            try self.by_id.put(id, ref.box);
            if (id >= self.next_id) self.next_id = id +| 1;
        }

        /// 更新实体（按 `getId()` 匹配；不存在返回 `error.NotFound`）。
        ///
        /// **按字段 diff**：只重建真正变化的普通索引/唯一键（典型「改 1 个字段」的更新
        /// 不再全量删除 + 重建全部索引）。失败时由库负责释放传入对象。
        pub fn update(self: *Self, object: T, violation: ?*Violation) Error!void {
            self.lock.lockUncancelable(self.io);
            defer self.lock.unlock(self.io);
            try self.updateLocked(object, violation);
        }

        /// 更新（**调用方必须已持写锁**；失败时由库释放传入对象）。
        fn updateLocked(self: *Self, object: T, violation: ?*Violation) Error!void {
            const id = object.getId();
            const old_box = self.by_id.get(id) orelse {
                var discard = object;
                discard.deinit();
                log.warn("更新 {s} 失败：对象不存在（ID {d}）", .{ self.type_name, id });
                return error.NotFound;
            };
            const old_ref = RefT{ .box = old_box };
            const old_object = old_ref.get();

            const new_ref = RefT.create(self.gpa, object) catch |err| {
                var discard = object;
                discard.deinit();
                return err;
            };
            const handle = new_ref.getMut();
            var installed = false;
            errdefer if (!installed) new_ref.release();

            // 1. 全量校验（排除自身）；失败不改变任何状态
            try self.uniques.validate(self.fields, self.composites, handle, id, violation);
            // 2. 唯一索引按字段/复合键 diff（内部两阶段）
            try self.uniques.updateEntity(self.fields, self.composites, id, old_object, handle, violation);
            // 3. 普通索引按字段 diff（Name 单独处理）
            try self.updateIndexDiff(id, old_object, handle);

            installed = true;
            self.by_id.put(id, new_ref.box) catch unreachable; // 键已存在，不会扩容
            old_ref.release();
        }

        /// 删除实体（不存在返回 `false`）。
        pub fn delete(self: *Self, id: i64) bool {
            self.lock.lockUncancelable(self.io);
            defer self.lock.unlock(self.io);
            return self.deleteLocked(id);
        }

        /// 删除（**调用方必须已持写锁**）。
        fn deleteLocked(self: *Self, id: i64) bool {
            const box = self.by_id.get(id) orelse return false;
            const ref = RefT{ .box = box };
            const object = ref.get();
            self.removeIndexEntity(id, object) catch |err| {
                log.warn("删除 {s} 对象 ID {d} 时清理普通索引失败：{s}", .{ self.type_name, id, @errorName(err) });
            };
            self.uniques.remove(self.fields, self.composites, object) catch |err| {
                log.warn("删除 {s} 对象 ID {d} 时清理唯一索引失败：{s}", .{ self.type_name, id, @errorName(err) });
            };
            _ = self.by_id.remove(id);
            _ = self.ids.remove(id);
            ref.release();
            return true;
        }

        /// 清空表（内存与后续持久化都为空表）。
        pub fn clear(self: *Self) void {
            self.lock.lockUncancelable(self.io);
            defer self.lock.unlock(self.io);
            self.clearLocked();
        }

        /// 清空（**调用方必须已持写锁**）。
        fn clearLocked(self: *Self) void {
            var iterator = self.by_id.valueIterator();
            while (iterator.next()) |box_ptr| {
                (RefT{ .box = box_ptr.* }).release();
            }
            self.by_id.clearRetainingCapacity();
            self.ids.deinit(self.gpa);
            self.ids = .{};
            self.indexes.deinit(self.gpa);
            self.indexes = index.IndexSet.initWithFields(self.gpa, self.fields) catch |err| blk: {
                log.err("清空 {s} 后重建索引失败：{s}", .{ self.type_name, @errorName(err) });
                break :blk index.IndexSet.init(self.gpa);
            };
            self.uniques.clear();
            self.synced.clearRetainingCapacity();
            self.next_id = 1;
            self.loaded = true;
        }

        // ------------------------------------------------------------------
        // 热加载（文件 → 内存，文件优先）
        // ------------------------------------------------------------------

        /// 当前记录的文件签名（加锁读取）。
        pub fn fileSignature(self: *Self) ?persist.FileSignature {
            self.lock.lockSharedUncancelable(self.io);
            defer self.lock.unlockShared(self.io);
            return self.file_sig;
        }

        /// 记录文件签名（自身写盘后调用，避免把自己的写入当成外部变化）。
        fn setFileSignature(self: *Self, sig: ?persist.FileSignature) void {
            self.lock.lockUncancelable(self.io);
            defer self.lock.unlock(self.io);
            self.file_sig = sig;
        }

        /// 读入口节流：距上次检查不足 `interval_ms` 时返回 `false`（不重复 `stat`）。
        pub fn shouldCheckReload(self: *Self, interval_ms: u64) bool {
            if (interval_ms == 0) return true;
            const now_ns = std.Io.Timestamp.now(self.io, .awake).nanoseconds;
            const now_ms: i64 = @intCast(@divTrunc(now_ns, std.time.ns_per_ms));
            const last_ms = self.last_reload_check_ms.load(.monotonic);
            if (last_ms != 0 and now_ms - last_ms < @as(i64, @intCast(interval_ms))) return false;
            self.last_reload_check_ms.store(now_ms, .monotonic);
            return true;
        }

        /// 热加载（**三方合并**）：文件被外部修改时逐行对比内存 / 文件 / 上次同步基准。
        ///
        /// - 变化驱动：签名（mtime + 大小）未变时只做一次 `stat`，不读盘、不解析；
        /// - 只有内存改：保留内存（稍后写盘，文件同步为合并结果）；
        /// - 只有文件改：采用文件；
        /// - 两边都改（冲突）：**以文件为准**，并记 warn；
        /// - 文件缺失 / 解析失败：**保留内存数据**并报错，不影响后续读写；
        /// - 合并结果与文件不同时把表标记为脏（后台线程会把内存独有改动写回文件）。
        pub fn reloadIfChanged(self: *Self, path: []const u8) Error!bool {
            if (self.not_save) return false;

            const current = persist.FileSignature.ofFile(self.io, path) catch |err| {
                log.warn("检测 {s} 数据文件变化失败（{s}）：{s}", .{ self.type_name, path, @errorName(err) });
                return false;
            };
            const sig = current orelse return false; // 文件不存在：保留内存数据
            if (self.fileSignature()) |known| {
                if (known.eql(sig)) return false; // 未变化：不读盘、不解析
            }

            const maybe_text = persist.readFileAlloc(self.io, self.gpa, path, max_load_bytes) catch |err| {
                log.warn("热加载 {s} 失败（读取 {s}）：{s}；保留内存数据", .{ self.type_name, path, @errorName(err) });
                return error.PersistError;
            };
            const text = maybe_text orelse return false;
            defer self.gpa.free(text);

            var arena = std.heap.ArenaAllocator.init(self.gpa);
            defer arena.deinit();
            const arena_gpa = arena.allocator();

            const blank = std.mem.trim(u8, text, " \t\r\n").len == 0;
            const node: json.Node = if (blank) .null else json.parseLax(arena_gpa, text) catch |err| {
                log.warn("热加载 {s} 解析失败（数据文件 {s}）：{s}；保留内存数据", .{ self.type_name, path, @errorName(err) });
                return error.PersistError;
            };

            const FileRow = struct {
                id: i64,
                object: T,
                hash: u64,
                consumed: bool = false,
            };

            var file_rows: std.ArrayList(FileRow) = .empty;
            defer {
                for (file_rows.items) |*row| {
                    if (!row.consumed) row.object.deinit();
                }
                file_rows.deinit(self.gpa);
            }

            switch (node) {
                .list => |items| {
                    try file_rows.ensureTotalCapacity(self.gpa, items.len);
                    for (items) |item| {
                        const parsed = self.parseEntity(item, arena_gpa) orelse {
                            log.warn("{s}：数组元素不是对象，已跳过（数据文件 {s}）", .{ self.type_name, path });
                            continue;
                        };
                        var object = parsed;
                        const id = object.getId();
                        if (id <= 0) {
                            log.warn("{s}：发现无效对象 ID {d}，已跳过（数据文件 {s}）", .{ self.type_name, id, path });
                            var discard = object;
                            discard.deinit();
                            continue;
                        }
                        var duplicate = false;
                        for (file_rows.items) |existing| {
                            if (existing.id == id) {
                                duplicate = true;
                                break;
                            }
                        }
                        if (duplicate) {
                            log.warn("{s}：发现重复对象 ID {d}，已跳过（数据文件 {s}）", .{ self.type_name, id, path });
                            var discard = object;
                            discard.deinit();
                            continue;
                        }
                        const hash = self.entityHash(&object);
                        file_rows.appendAssumeCapacity(.{ .id = id, .object = object, .hash = hash });
                    }
                },
                .object => {
                    if (self.parseEntity(node, arena_gpa)) |object| {
                        const id = object.getId();
                        if (id > 0) {
                            const hash = self.entityHash(&object);
                            try file_rows.append(self.gpa, .{ .id = id, .object = object, .hash = hash });
                        } else {
                            var discard = object;
                            discard.deinit();
                        }
                    }
                },
                .null => {},
                else => log.err("{s} 数据文件顶层应为对象或数组（{s}）；热加载按空表合并", .{ self.type_name, path }),
            }

            self.lock.lockUncancelable(self.io);
            defer self.lock.unlock(self.io);

            var file_index = std.AutoHashMap(i64, usize).init(self.gpa);
            defer file_index.deinit();
            for (file_rows.items, 0..) |row, i| {
                const gop = try file_index.getOrPut(row.id);
                if (!gop.found_existing) gop.value_ptr.* = i;
            }

            const mem_ids = try self.gpa.alloc(i64, self.by_id.count());
            defer self.gpa.free(mem_ids);
            var mem_count: usize = 0;
            var iterator = self.by_id.keyIterator();
            while (iterator.next()) |key| : (mem_count += 1) mem_ids[mem_count] = key.*;

            var adopted: usize = 0;
            var kept: usize = 0;
            var conflicts: usize = 0;
            var removed: usize = 0;

            for (mem_ids) |id| {
                const box = self.by_id.get(id) orelse continue;
                const mem_hash = self.entityHash(&box.value);
                const base = self.synced.get(id);

                if (file_index.get(id)) |row_index| {
                    const row = &file_rows.items[row_index];
                    if (base) |base_hash| {
                        if (mem_hash == base_hash) {
                            // 内存未改：文件改了才采用
                            if (row.hash != base_hash) {
                                if (try self.applyFileRowLocked(row)) adopted += 1;
                            }
                        } else if (row.hash == base_hash) {
                            kept += 1; // 只有内存改 → 保留
                        } else if (mem_hash == row.hash) {
                            // 两边改成一样，无需动作
                        } else {
                            conflicts += 1; // 两边都改 → 文件优先
                            if (try self.applyFileRowLocked(row)) adopted += 1;
                        }
                    } else if (mem_hash != row.hash) {
                        // 无同步基准（双方都新增）→ 文件优先
                        conflicts += 1;
                        if (try self.applyFileRowLocked(row)) adopted += 1;
                    }
                    continue;
                }

                // 文件里没有该行
                if (base == null) {
                    kept += 1; // 内存新增（未同步）
                    continue;
                }
                if (mem_hash == base.?) {
                    if (self.deleteLocked(id)) removed += 1; // 内存未改、文件已删除
                    _ = self.synced.remove(id);
                } else {
                    conflicts += 1; // 内存改 / 文件删 → 文件优先
                    if (self.deleteLocked(id)) removed += 1;
                    _ = self.synced.remove(id);
                }
            }

            // 文件新增（内存没有的行）
            var file_iterator = file_index.iterator();
            while (file_iterator.next()) |entry| {
                const id = entry.key_ptr.*;
                if (self.by_id.contains(id)) continue;
                const row = &file_rows.items[entry.value_ptr.*];
                if (self.synced.get(id)) |base_hash| {
                    if (row.hash == base_hash) continue; // 文件未改且内存已删除 → 保持删除
                    conflicts += 1; // 内存删 / 文件改 → 文件优先（恢复）
                }
                if (try self.applyFileRowLocked(row)) adopted += 1;
            }

            self.file_sig = sig;
            // 保留了内存独有改动 → 需要把合并结果写回文件
            self.dirty.store(kept > 0, .release);

            if (adopted + kept + conflicts + removed == 0) return false;
            log.info(
                "热加载 {s}（合并）：采用文件 {d} / 保留内存 {d} / 冲突取文件 {d} / 删除 {d}（数据文件 {s}）",
                .{ self.type_name, adopted, kept, conflicts, removed, path },
            );
            return true;
        }

        /// 应用一条文件行（替换同 ID 内存行或新增）；返回是否成功。
        ///
        /// 失败（唯一约束/OOM）时保留内存行并记 warn；对象内存由 update/install 原语接管。
        fn applyFileRowLocked(self: *Self, row: anytype) Error!bool {
            const id = row.id;
            const object = row.object;
            row.consumed = true; // 无论成败，updateLocked/installRowLocked 都会处置这个对象

            if (self.by_id.contains(id)) {
                self.updateLocked(object, null) catch |err| {
                    log.warn("热加载 {s}：采用文件行 ID {d} 失败（{s}）；保留内存行", .{ self.type_name, id, @errorName(err) });
                    return false;
                };
            } else {
                self.installRowLocked(id, object) catch |err| {
                    log.warn("热加载 {s}：新增文件行 ID {d} 失败（{s}）；跳过该行", .{ self.type_name, id, @errorName(err) });
                    return false;
                };
            }
            if (self.by_id.get(id)) |box| {
                self.synced.put(self.gpa, id, self.entityHash(&box.value)) catch {};
            }
            return true;
        }

        // ------------------------------------------------------------------
        // 读操作
        // ------------------------------------------------------------------

        /// 主键查找（返回句柄，调用方 `release`）。
        pub fn findById(self: *Self, id: i64) ?RefT {
            self.lock.lockSharedUncancelable(self.io);
            defer self.lock.unlockShared(self.io);
            const box = self.by_id.get(id) orelse return null;
            return (RefT{ .box = box }).retain();
        }

        /// 全表查找（按 ID 升序）。
        pub fn findAll(self: *Self) !ListT {
            self.lock.lockSharedUncancelable(self.io);
            defer self.lock.unlockShared(self.io);
            return self.collectIdSetRefs(0, self.ids.count(), true);
        }

        /// 精确查找（走索引）。
        pub fn findBy(self: *Self, field: []const u8, input: Value) !ListT {
            const kind = self.fieldKind(field) orelse return ListT.empty(self.gpa);
            const key = (try value.normalize(input, kind, self.gpa)) orelse return ListT.empty(self.gpa);
            defer key.deinit(self.gpa);

            var ids: std.ArrayList(i64) = .empty;
            defer ids.deinit(self.gpa);

            self.lock.lockSharedUncancelable(self.io);
            defer self.lock.unlockShared(self.io);
            try self.indexes.find(self.gpa, field, key, &ids);
            return self.collectRefs(ids.items);
        }

        /// 范围查找（数值/时间有序索引；文本按小写字典序）。
        pub fn findByRange(self: *Self, field: []const u8, min_input: Value, max_input: Value) !ListT {
            const kind = self.fieldKind(field) orelse return ListT.empty(self.gpa);
            const min_key = (try value.normalize(min_input, kind, self.gpa)) orelse return ListT.empty(self.gpa);
            defer min_key.deinit(self.gpa);
            const max_key = (try value.normalize(max_input, kind, self.gpa)) orelse return ListT.empty(self.gpa);
            defer max_key.deinit(self.gpa);

            var ids: std.ArrayList(i64) = .empty;
            defer ids.deinit(self.gpa);

            self.lock.lockSharedUncancelable(self.io);
            defer self.lock.unlockShared(self.io);
            try self.indexes.range(self.gpa, field, min_key, max_key, &ids);
            return self.collectRefs(ids.items);
        }

        /// 模式匹配（文本 `*`/`?` 通配、布尔智能值、时间年/月/日）。
        pub fn findByLike(self: *Self, field: []const u8, pattern: []const u8) !ListT {
            const kind = self.fieldKind(field) orelse return ListT.empty(self.gpa);

            var ids: std.ArrayList(i64) = .empty;
            defer ids.deinit(self.gpa);

            self.lock.lockSharedUncancelable(self.io);
            defer self.lock.unlockShared(self.io);
            if (kind == .time) {
                if (value.dateRangeOf(pattern)) |range| {
                    try self.indexes.range(self.gpa, field, .{ .time = range.start }, .{ .time = range.end }, &ids);
                }
            } else {
                try self.indexes.pattern(self.gpa, field, pattern, &ids);
            }
            return self.collectRefs(ids.items);
        }

        /// 多条件交集查找。
        pub fn findByMultiple(self: *Self, conditions: []const model.Condition) !ListT {
            if (conditions.len == 0) return ListT.empty(self.gpa);

            self.lock.lockSharedUncancelable(self.io);
            defer self.lock.unlockShared(self.io);

            // 先查候选集最小的条件（减少交集规模）
            const order = try self.gpa.alloc(usize, conditions.len);
            defer self.gpa.free(order);
            for (order, 0..) |*slot, i| slot.* = i;
            const Context = struct {
                table: *Self,
                conditions: []const model.Condition,
            };
            const context = Context{ .table = self, .conditions = conditions };
            std.mem.sortUnstable(usize, order, context, struct {
                fn lessThan(ctx: Context, a: usize, b: usize) bool {
                    return ctx.table.indexes.idCount(ctx.conditions[a].field) <
                        ctx.table.indexes.idCount(ctx.conditions[b].field);
                }
            }.lessThan);

            var result: std.ArrayList(i64) = .empty;
            defer result.deinit(self.gpa);
            var stage: std.ArrayList(i64) = .empty;
            defer stage.deinit(self.gpa);
            var merged: std.ArrayList(i64) = .empty;
            defer merged.deinit(self.gpa);

            for (order) |position| {
                const condition = conditions[position];
                const kind = self.fieldKind(condition.field) orelse return ListT.empty(self.gpa);
                const key = (try value.normalize(condition.value, kind, self.gpa)) orelse return ListT.empty(self.gpa);
                defer key.deinit(self.gpa);

                stage.clearRetainingCapacity();
                try self.indexes.find(self.gpa, condition.field, key, &stage);
                if (result.items.len == 0) {
                    try result.appendSlice(self.gpa, stage.items);
                } else {
                    try intersectSorted(self.gpa, result.items, stage.items, &merged);
                    result.clearRetainingCapacity();
                    try result.appendSlice(self.gpa, merged.items);
                    merged.clearRetainingCapacity();
                }
                if (result.items.len == 0) return ListT.empty(self.gpa);
            }
            return self.collectRefs(result.items);
        }

        /// 唯一字段查找。
        pub fn findByUnique(self: *Self, field: []const u8, input: Value) ?RefT {
            const kind = self.fieldKind(field) orelse return null;
            const key = (value.normalize(input, kind, self.gpa) catch return null) orelse return null;
            defer key.deinit(self.gpa);

            self.lock.lockSharedUncancelable(self.io);
            defer self.lock.unlockShared(self.io);
            const id = self.uniques.findValue(field, key) orelse return null;
            const box = self.by_id.get(id) orelse return null;
            return (RefT{ .box = box }).retain();
        }

        /// 复合唯一约束查找（按约束声明的字段顺序取值；值顺序无关）。
        pub fn findByCompositeUnique(self: *Self, group: []const u8, inputs: []const model.Condition) ?RefT {
            const rule = self.findCompositeRule(group) orelse return null;

            var keys: std.ArrayList(Key) = .empty;
            defer {
                for (keys.items) |key| key.deinit(self.gpa);
                keys.deinit(self.gpa);
            }
            for (rule.fields) |name| {
                const kind = self.fieldKind(name) orelse return null;
                var found: ?Value = null;
                for (inputs) |condition| {
                    if (std.ascii.eqlIgnoreCase(condition.field, name)) {
                        found = condition.value;
                        break;
                    }
                }
                const input = found orelse return null;
                const key = (value.normalize(input, kind, self.gpa) catch return null) orelse return null;
                keys.append(self.gpa, key) catch {
                    key.deinit(self.gpa);
                    return null;
                };
            }

            self.lock.lockSharedUncancelable(self.io);
            defer self.lock.unlockShared(self.io);
            const id = self.uniques.findComposite(group, keys.items) orelse return null;
            const box = self.by_id.get(id) orelse return null;
            return (RefT{ .box = box }).retain();
        }

        /// 唯一值是否已存在（更新场景可排除自身）。
        pub fn isUniqueValueExists(self: *Self, field: []const u8, input: Value, exclude_id: ?i64) bool {
            const kind = self.fieldKind(field) orelse return false;
            const key = (value.normalize(input, kind, self.gpa) catch return false) orelse return false;
            defer key.deinit(self.gpa);

            self.lock.lockSharedUncancelable(self.io);
            defer self.lock.unlockShared(self.io);
            const existing = self.uniques.findValue(field, key) orelse return false;
            if (exclude_id) |excluded| return existing != excluded;
            return true;
        }

        /// 分页（优先按索引顺序取页，避免全表排序）。
        pub fn findByPage(
            self: *Self,
            sort_field: ?[]const u8,
            page_index: usize,
            page_size_input: usize,
            ascending: bool,
        ) !PageT {
            const page_size = @max(page_size_input, 1);
            const skip = page_index *| page_size;
            const take_end = skip +| page_size;

            self.lock.lockSharedUncancelable(self.io);
            defer self.lock.unlockShared(self.io);

            const total_count = self.by_id.count();
            var items: ListT = ListT.empty(self.gpa);

            var used_index = false;
            if (sort_field) |field| {
                // 索引覆盖全表时按索引顺序取前 take_end 条（有空值字段不建索引，退回全量排序）
                if (total_count > 0 and self.indexes.idCount(field) == total_count) {
                    var ordered_ids: std.ArrayList(i64) = .empty;
                    defer ordered_ids.deinit(self.gpa);
                    if (try self.indexes.takeOrdered(self.gpa, field, ascending, take_end, &ordered_ids)) {
                        const start = @min(skip, ordered_ids.items.len);
                        const end = @min(take_end, ordered_ids.items.len);
                        items = try self.collectRefs(ordered_ids.items[start..end]);
                        used_index = true;
                    }
                }
            }

            if (!used_index) {
                if (sort_field) |field| {
                    items = try self.pageBySortField(field, skip, take_end, ascending, total_count);
                } else {
                    // 无排序字段：直接按升序 ID 表取页（无排序、无临时数组）
                    items = try self.collectIdSetRefs(skip, take_end, ascending);
                }
            }

            return .{
                .items = items,
                .page_index = page_index,
                .page_size = page_size,
                .total_count = total_count,
                .total_pages = if (total_count == 0) 0 else (total_count + page_size - 1) / page_size,
            };
        }

        fn pageBySortField(
            self: *Self,
            field: []const u8,
            skip: usize,
            take_end: usize,
            ascending: bool,
            total_count: usize,
        ) !ListT {
            const Row = struct { key: ?Key, id: i64 };
            const rows = try self.gpa.alloc(Row, total_count);
            defer self.gpa.free(rows);
            var count: usize = 0;
            // 只释放已初始化的行（提前失败时未初始化的槽位不能当 `?Key` 解引用）
            defer {
                for (rows[0..count]) |row| {
                    if (row.key) |key| key.deinit(self.gpa);
                }
            }

            const kind = self.fieldKind(field);
            var iterator = self.by_id.iterator();
            while (iterator.next()) |entry| {
                const id = entry.key_ptr.*;
                const object: *const T = &entry.value_ptr.*.value;
                var key: ?Key = null;
                if (kind) |field_kind| {
                    if (object.getField(field)) |raw| {
                        key = try value.normalize(raw, field_kind, self.gpa);
                    }
                }
                rows[count] = .{ .key = key, .id = id };
                count += 1;
            }

            const Context = struct { ascending: bool };
            std.mem.sortUnstable(Row, rows, Context{ .ascending = ascending }, struct {
                fn lessThan(context: Context, a: Row, b: Row) bool {
                    var ordering: std.math.Order = .eq;
                    if (a.key == null and b.key == null) {
                        ordering = .eq;
                    } else if (a.key == null) {
                        ordering = .lt;
                    } else if (b.key == null) {
                        ordering = .gt;
                    } else {
                        ordering = Key.order(a.key.?, b.key.?);
                    }
                    if (!context.ascending) ordering = ordering.invert();
                    if (ordering == .eq) return a.id < b.id;
                    return ordering == .lt;
                }
            }.lessThan);

            const start = @min(skip, count);
            const end = @min(take_end, count);
            var out = std.ArrayList(RefT).empty;
            errdefer {
                for (out.items) |ref| ref.release();
                out.deinit(self.gpa);
            }
            try out.ensureTotalCapacity(self.gpa, end - start);
            for (rows[start..end]) |row| {
                const box = self.by_id.get(row.id) orelse continue;
                out.appendAssumeCapacity((RefT{ .box = box }).retain());
            }
            return .{ .gpa = self.gpa, .items = try out.toOwnedSlice(self.gpa) };
        }

        // ------------------------------------------------------------------
        // 统计 / 快照 / 持久化
        // ------------------------------------------------------------------

        /// 表统计。
        pub fn statistics(self: *Self, gpa: std.mem.Allocator) !model.TableStatistics {
            self.lock.lockSharedUncancelable(self.io);
            defer self.lock.unlockShared(self.io);

            var unique_fields: usize = 0;
            for (self.fields) |field| {
                if (field.unique != null) unique_fields += 1;
            }
            return .{
                .type_name = self.type_name,
                .rows = self.by_id.count(),
                .indexes = try self.indexes.statistics(gpa),
                .unique_fields = unique_fields,
                .unique_composites = self.composites.len,
                .persist_count = self.persist_count.load(.monotonic),
                .persisted_bytes = self.persisted_bytes.load(.monotonic),
                .last_persist_ms = self.last_persist_ms.load(.monotonic),
                .in_memory = self.not_save,
            };
        }

        /// 序列化快照（按 ID 升序，输出稳定便于 diff）。
        pub fn snapshotText(self: *Self, gpa: std.mem.Allocator, pretty: bool) ![]u8 {
            var buffer = zzig.Buf.init(gpa);
            errdefer buffer.deinit();

            self.lock.lockSharedUncancelable(self.io);
            defer self.lock.unlockShared(self.io);

            if (pretty) {
                try buffer.add("[\r\n");
            } else {
                try buffer.add("[ ");
            }

            var first = true;
            for (self.ids.ids.items) |id| {
                if (id < 0) continue;
                const box = self.by_id.get(id) orelse continue;
                if (!first) {
                    if (pretty) {
                        try buffer.add(",\r\n");
                    } else {
                        try buffer.add(", ");
                    }
                }
                if (pretty) try buffer.addByte('\t');
                try self.writeEntity(gpa, &buffer, &box.value);
                first = false;
            }

            if (pretty) {
                if (!first) try buffer.add("\r\n");
                try buffer.addByte(']');
            } else {
                try buffer.add(" ]");
            }
            return buffer.toOwnedSlice();
        }

        fn writeEntity(self: *Self, gpa: std.mem.Allocator, buffer: *zzig.Buf, object: *const T) !void {
            try buffer.add("{ Id:");
            try buffer.fmt("{d}", .{object.getId()});
            try buffer.add(", Name:");
            try json.writeQuoted(&buffer.alloc.writer, entity.getName(object));
            for (self.fields) |field| {
                if (index.isIdOrName(field.name)) continue;
                if (!field.save) continue;
                const raw = object.getField(field.name) orelse continue;
                if (value.isNull(raw)) continue;
                try buffer.add(", ");
                try buffer.add(field.name);
                try buffer.addByte(':');
                try json.writeValue(gpa, &buffer.alloc.writer, raw, field.kind);
            }
            try buffer.add(" }");
        }

        /// 保存到磁盘（原子替换；后台线程与 `flush` 共用）。
        pub fn saveTo(self: *Self, path: []const u8, pretty: bool) Error!u64 {
            if (self.not_save) return 0;

            self.save_mutex.lockUncancelable(self.io);
            defer self.save_mutex.unlock(self.io);

            // 先「取走」脏标记：写入期间的新修改会重新置脏，由下一轮补写
            self.dirty.store(false, .release);
            const started = std.Io.Timestamp.now(self.io, .awake);

            const text = self.snapshotText(self.gpa, pretty) catch |err| {
                self.dirty.store(true, .release);
                log.err("序列化 {s} 失败：{s}", .{ self.type_name, @errorName(err) });
                return if (err == error.OutOfMemory) error.OutOfMemory else error.PersistError;
            };
            defer self.gpa.free(text);

            persist.writeFileAtomic(self.io, self.gpa, path, text) catch |err| {
                self.dirty.store(true, .release);
                log.err("持久化 {s} 失败（数据文件 {s}）：{s}", .{ self.type_name, path, @errorName(err) });
                return error.PersistError;
            };

            _ = self.persist_count.fetchAdd(1, .monotonic);
            _ = self.persisted_bytes.fetchAdd(text.len, .monotonic);
            const elapsed = std.Io.Timestamp.durationTo(started, std.Io.Timestamp.now(self.io, .awake));
            self.last_persist_ms.store(@intCast(@max(elapsed.toMilliseconds(), 0)), .monotonic);

            // 记录自己的写入签名：避免下一轮热加载把自己的写盘误判为外部变化
            const sig = persist.FileSignature.ofFile(self.io, path) catch self.fileSignature();
            self.setFileSignature(sig);
            // 写盘即「全部行已与文件一致」：重建行级同步基准
            self.refreshSynced();
            return text.len;
        }

        // ------------------------------------------------------------------
        // 内部：索引维护与辅助
        // ------------------------------------------------------------------

        /// 建立普通索引（`only == null` 表示全部；`Some` 时仅指定字段，对应 C# `InsertByIndex`）。
        fn indexEntity(self: *Self, id: i64, object: *const T, only: ?[]const []const u8) Error!void {
            if (wantedIndex(only, "Id")) {
                try self.indexes.add(self.gpa, "Id", .int, .{ .int = id }, id);
            }
            if (wantedIndex(only, "Name")) {
                const name_key = Key{ .text = try self.gpa.dupe(u8, entity.getName(object)) };
                try self.indexes.add(self.gpa, "Name", .text, name_key, id);
            }
            for (self.fields) |field| {
                if (!field.indexed) continue;
                if (index.isIdOrName(field.name)) continue;
                if (!wantedIndex(only, field.name)) continue;
                const raw = object.getField(field.name) orelse continue;
                const key = (try value.normalize(raw, field.kind, self.gpa)) orelse continue;
                try self.indexes.add(self.gpa, field.name, field.kind, key, id);
            }
        }

        fn removeIndexEntity(self: *Self, id: i64, object: *const T) Error!void {
            try self.indexes.remove(self.gpa, "Id", .{ .int = id }, id);
            try self.removeTextIndexValue("Name", entity.getName(object), id);
            for (self.fields) |field| {
                if (!field.indexed) continue;
                if (index.isIdOrName(field.name)) continue;
                const raw = object.getField(field.name) orelse continue;
                const key = (value.normalize(raw, field.kind, self.gpa) catch continue) orelse continue;
                self.indexes.remove(self.gpa, field.name, key, id) catch {};
                key.deinit(self.gpa);
            }
        }

        fn removeTextIndexValue(self: *Self, field: []const u8, text: []const u8, id: i64) Error!void {
            const key = Key{ .text = try self.gpa.dupe(u8, text) };
            try self.indexes.remove(self.gpa, field, key, id);
            key.deinit(self.gpa);
        }

        /// 普通索引按字段 diff（只重建真正变化的键）。
        fn updateIndexDiff(self: *Self, id: i64, old_object: *const T, new_object: *const T) Error!void {
            const old_name = entity.getName(old_object);
            const new_name = entity.getName(new_object);
            if (!std.mem.eql(u8, old_name, new_name)) {
                try self.removeTextIndexValue("Name", old_name, id);
                const name_key = Key{ .text = try self.gpa.dupe(u8, new_name) };
                try self.indexes.add(self.gpa, "Name", .text, name_key, id);
            }

            for (self.fields) |field| {
                if (!field.indexed) continue;
                if (index.isIdOrName(field.name)) continue;

                const old_raw = old_object.getField(field.name);
                const new_raw = new_object.getField(field.name);

                // 快路径：未变化（或同为 null）的字段直接跳过，省掉两次 normalize 分配
                if (old_raw == null and new_raw == null) continue;
                if (old_raw != null and new_raw != null and value.maybeEqualRaw(old_raw.?, new_raw.?)) continue;

                const old_key: ?Key = if (old_raw) |raw|
                    try value.normalize(raw, field.kind, self.gpa)
                else
                    null;
                const new_key: ?Key = if (new_raw) |raw|
                    try value.normalize(raw, field.kind, self.gpa)
                else
                    null;

                const same = (old_key == null and new_key == null) or
                    (old_key != null and new_key != null and Key.eql(old_key.?, new_key.?));
                if (same) {
                    if (old_key) |key| key.deinit(self.gpa);
                    if (new_key) |key| key.deinit(self.gpa);
                    continue;
                }
                if (old_key) |key| {
                    try self.indexes.remove(self.gpa, field.name, key, id);
                    key.deinit(self.gpa);
                }
                if (new_key) |key| {
                    try self.indexes.add(self.gpa, field.name, field.kind, key, id);
                }
            }
        }

        fn collectRefs(self: *Self, ids: []const i64) !ListT {
            var out = std.ArrayList(RefT).empty;
            errdefer {
                for (out.items) |ref| ref.release();
                out.deinit(self.gpa);
            }
            try out.ensureTotalCapacity(self.gpa, ids.len);
            for (ids) |id| {
                const box = self.by_id.get(id) orelse continue;
                out.appendAssumeCapacity((RefT{ .box = box }).retain());
            }
            return .{ .gpa = self.gpa, .items = try out.toOwnedSlice(self.gpa) };
        }

        /// 从升序 ID 表取 `[skip, take_end)` 区间（不分配临时 ID 数组）。
        fn collectIdSetRefs(self: *Self, skip: usize, take_end: usize, ascending: bool) !ListT {
            var out = std.ArrayList(RefT).empty;
            errdefer {
                for (out.items) |ref| ref.release();
                out.deinit(self.gpa);
            }
            const wanted = if (take_end > skip) take_end - skip else 0;
            try out.ensureTotalCapacity(self.gpa, @min(wanted, self.ids.count()));

            var position: usize = 0;
            if (ascending) {
                for (self.ids.ids.items) |id| {
                    if (id < 0) continue;
                    if (position >= take_end) break;
                    if (position >= skip) {
                        if (self.by_id.get(id)) |box| out.appendAssumeCapacity((RefT{ .box = box }).retain());
                    }
                    position += 1;
                }
            } else {
                var cursor: usize = self.ids.ids.items.len;
                while (cursor > 0) {
                    cursor -= 1;
                    const id = self.ids.ids.items[cursor];
                    if (id < 0) continue;
                    if (position >= take_end) break;
                    if (position >= skip) {
                        if (self.by_id.get(id)) |box| out.appendAssumeCapacity((RefT{ .box = box }).retain());
                    }
                    position += 1;
                }
            }
            return .{ .gpa = self.gpa, .items = try out.toOwnedSlice(self.gpa) };
        }

        fn fieldKind(self: *Self, field: []const u8) ?FieldKind {
            if (std.ascii.eqlIgnoreCase(field, "Id")) return .int;
            if (std.ascii.eqlIgnoreCase(field, "Name")) return .text;
            for (self.fields) |declared| {
                if (std.mem.eql(u8, declared.name, field)) return declared.kind;
            }
            return null;
        }

        fn findDeclaredField(self: *Self, name: []const u8) ?*const Field {
            for (self.fields) |*field| {
                if (std.mem.eql(u8, field.name, name)) return field;
            }
            for (self.fields) |*field| {
                if (std.ascii.eqlIgnoreCase(field.name, name)) return field;
            }
            return null;
        }

        fn findCompositeRule(self: *Self, group: []const u8) ?*const CompositeUniqueRule {
            for (self.composites) |*rule| {
                if (std.mem.eql(u8, rule.group, group)) return rule;
            }
            return null;
        }
    };
}

/// JSON 文本哈希（忽略字符串外的空白，使「内存原文」与「文件解析后的紧凑文本」等价）。
fn hashJsonText(hasher: *std.hash.Wyhash, text: []const u8) void {
    var in_string = false;
    var escaped = false;
    for (text) |c| {
        if (in_string) {
            hasher.update(&[_]u8{c});
            if (escaped) {
                escaped = false;
            } else if (c == '\\') {
                escaped = true;
            } else if (c == '"') {
                in_string = false;
            }
            continue;
        }
        switch (c) {
            ' ', '\t', '\r', '\n' => continue,
            '"' => {
                in_string = true;
                hasher.update(&[_]u8{c});
            },
            else => hasher.update(&[_]u8{c}),
        }
    }
}

fn wantedIndex(only: ?[]const []const u8, name: []const u8) bool {
    const names = only orelse return true;
    for (names) |item| {
        if (std.mem.eql(u8, item, name)) return true;
    }
    return false;
}

/// 两个升序 ID 列表求交集，写入 `out`（先清空）。
fn intersectSorted(gpa: std.mem.Allocator, a: []const i64, b: []const i64, out: *std.ArrayList(i64)) !void {
    out.clearRetainingCapacity();
    var i: usize = 0;
    var j: usize = 0;
    while (i < a.len and j < b.len) {
        if (a[i] == b[j]) {
            try out.append(gpa, a[i]);
            i += 1;
            j += 1;
        } else if (a[i] < b[j]) {
            i += 1;
        } else {
            j += 1;
        }
    }
}

fn nodeToI64(node: json.Node) ?i64 {
    return switch (node) {
        .integer => |number| number,
        .number => |number| if (std.math.isFinite(number) and @abs(number) < 9.2e18)
            @as(i64, @intFromFloat(number))
        else
            null,
        .string => |text| std.fmt.parseInt(i64, std.mem.trim(u8, text, " \t\r\n"), 10) catch null,
        .boolean => |flag| @as(i64, @intFromBool(flag)),
        else => null,
    };
}

fn nodeToText(arena_gpa: std.mem.Allocator, node: json.Node) ?[]const u8 {
    return switch (node) {
        .string => |text| text,
        .integer => |number| std.fmt.allocPrint(arena_gpa, "{d}", .{number}) catch null,
        .number => |number| std.fmt.allocPrint(arena_gpa, "{d}", .{number}) catch null,
        .boolean => |flag| if (flag) "true" else "false",
        else => null,
    };
}
