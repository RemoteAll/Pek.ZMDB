//! 内存数据库门面（对应 C# `cdb` + `MemoryDB` / Rust 版 `db.rs`）。
//!
//! - **多实例**：`MemoryDb.init(gpa, io, options)` 可创建相互隔离的库（测试/多租户）；
//! - **全局单例**：`configureGlobal` + `global()` 提供 `cdb` 风格的静态入口；
//! - **惰性建表**：按 `T.type_name` 自动创建表并加载 `Data/{type_name}.json`；
//! - **读多写少**：读操作并发无阻塞，写操作单写者保证主存储与索引一致；
//! - **后台持久化**：写操作只置脏并唤醒后台线程，不在调用线程做磁盘 IO。
//!
//! # `io` 参数从哪来
//! Zig 0.17 的锁与文件 IO 都要显式 `std.Io`。库把 `io` 存在实例里，调用方只需在构造时给一次：
//!
//! ```zig
//! var threaded: std.Io.Threaded = .init(std.heap.smp_allocator, .{});
//! const io = threaded.io();
//! var db = try MemoryDb.init(gpa, io, .{ .base_dir = "AppData" });
//! defer db.deinit();
//! ```
//!
//! `io` 必须是**线程安全**实现（`std.Io.Threaded`）：后台持久化线程与调用线程共用它。

const std = @import("std");
const zzig = @import("zzig");

const entity = @import("entity.zig");
const errors = @import("error.zig");
const model = @import("model.zig");
const persist = @import("persist.zig");
const table_mod = @import("table.zig");

pub const Error = errors.Error;
pub const Options = DbOptions;
pub const Violation = model.Violation;
pub const Condition = model.Condition;
pub const DbStatistics = model.DbStatistics;

const log = std.log.scoped(.zmdb);

/// 数据库选项（`base_dir` 会复制一份，调用方无需长期持有）。
pub const DbOptions = struct {
    /// 数据根目录（数据文件写入 `{base_dir}/Data/{type_name}.json`；空串 = 纯内存）。
    base_dir: []const u8 = "",
    /// 是否启用后台持久化线程（关闭后仍可用 `flush` 手动落盘）。
    auto_persist: bool = true,
    /// 最小写盘间隔（写合并窗口；默认 500ms，与 C# 版一致）。
    min_write_interval_ms: u64 = 500,
    /// 是否输出缩进换行的 JSON（默认 `true`，对齐 C# `SimpleJsonString` 可读格式）。
    pretty: bool = true,
    /// `MemoryDb.deinit` 时是否同步写盘（默认 `true`，避免丢尾部修改）。
    flush_on_drop: bool = true,
};

/// 内存数据库实例。
pub const MemoryDb = struct {
    inner: *Inner,

    const Inner = struct {
        gpa: std.mem.Allocator,
        io: std.Io,
        options: DbOptions,
        base_dir: []u8,
        tables: std.StringHashMap(table_mod.AnyTable),
        tables_lock: std.Io.RwLock = .init,
        hub: persist.Hub = .{},
        worker: ?std.Thread = null,
    };

    // ------------------------------------------------------------------
    // 构造 / 销毁
    // ------------------------------------------------------------------

    /// 使用自定义选项创建。
    pub fn init(gpa: std.mem.Allocator, io: std.Io, options: DbOptions) Error!MemoryDb {
        const inner = try gpa.create(Inner);
        errdefer gpa.destroy(inner);

        const base_dir = try gpa.dupe(u8, options.base_dir);
        errdefer gpa.free(base_dir);

        var effective = options;
        effective.base_dir = base_dir;

        inner.* = .{
            .gpa = gpa,
            .io = io,
            .options = effective,
            .base_dir = base_dir,
            .tables = std.StringHashMap(table_mod.AnyTable).init(gpa),
            .worker = null,
        };
        errdefer inner.tables.deinit();

        if (effective.auto_persist and base_dir.len > 0) {
            inner.worker = std.Thread.spawn(.{}, workerMain, .{inner}) catch |err| {
                log.err("启动后台持久化线程失败：{s}", .{@errorName(err)});
                return error.ThreadSpawnFailed;
            };
        }
        return .{ .inner = inner };
    }

    /// 纯内存实例（不读写磁盘）。
    pub fn inMemory(gpa: std.mem.Allocator, io: std.Io) Error!MemoryDb {
        return init(gpa, io, .{
            .base_dir = "",
            .auto_persist = false,
            .flush_on_drop = false,
        });
    }

    /// 释放实例：停止后台线程 → （可选）写盘 → 释放全部表与实体。
    pub fn deinit(self: *MemoryDb) void {
        const inner = self.inner;
        inner.hub.stopAll(inner.io);
        if (inner.worker) |worker| worker.join();

        if (inner.options.flush_on_drop) {
            self.flush() catch |err| {
                log.warn("关闭前写盘失败：{s}", .{@errorName(err)});
            };
        }

        var iterator = inner.tables.valueIterator();
        while (iterator.next()) |any| any.vtable.destroy(any.ptr);
        inner.tables.deinit();
        inner.gpa.free(inner.base_dir);
        const gpa = inner.gpa;
        gpa.destroy(inner);
        self.inner = undefined;
    }

    // ------------------------------------------------------------------
    // 元信息
    // ------------------------------------------------------------------

    /// 数据根目录（纯内存模式为空串）。
    pub fn baseDir(self: *MemoryDb) []const u8 {
        return self.inner.base_dir;
    }

    /// 指定实体的数据文件路径（纯内存模式返回 `null`；调用方释放）。
    pub fn dataFile(self: *MemoryDb, comptime T: type) Error!?[]u8 {
        return self.dataFilePath(T);
    }

    /// 已加载（注册）的表名（按名称排序；外层切片由调用方释放）。
    pub fn loadedTables(self: *MemoryDb, gpa: std.mem.Allocator) ![][]const u8 {
        const inner = self.inner;
        inner.tables_lock.lockSharedUncancelable(inner.io);
        defer inner.tables_lock.unlockShared(inner.io);

        const names = try gpa.alloc([]const u8, inner.tables.count());
        errdefer gpa.free(names);
        var count: usize = 0;
        var iterator = inner.tables.keyIterator();
        while (iterator.next()) |key| : (count += 1) names[count] = key.*;
        if (count > 1) {
            std.mem.sortUnstable([]const u8, names, {}, struct {
                fn lessThan(_: void, a: []const u8, b: []const u8) bool {
                    return std.mem.lessThan(u8, a, b);
                }
            }.lessThan);
        }
        return names;
    }

    // ------------------------------------------------------------------
    // 写操作
    // ------------------------------------------------------------------

    /// 插入实体（分配并回写 ID，返回新 ID；失败时由库释放传入对象）。
    pub fn insert(self: *MemoryDb, comptime T: type, object: T, violation: ?*Violation) Error!i64 {
        const table = try self.tableFor(T);
        const id = try table.insert(object, violation);
        self.markDirty(table);
        return id;
    }

    /// 插入实体，只对指定字段建立普通索引（对应 C# `InsertByIndex`）。
    pub fn insertByIndex(
        self: *MemoryDb,
        comptime T: type,
        object: T,
        fields: []const []const u8,
        violation: ?*Violation,
    ) Error!i64 {
        const table = try self.tableFor(T);
        const id = try table.insertByIndex(object, fields, violation);
        self.markDirty(table);
        return id;
    }

    /// 批量插入（唯一冲突时**已插入的行保留**；返回的 ID 切片由调用方释放）。
    pub fn insertBatch(
        self: *MemoryDb,
        comptime T: type,
        objects: []T,
        violation: ?*Violation,
    ) Error![]i64 {
        if (objects.len == 0) return &.{};
        const table = try self.tableFor(T);
        const ids = try table.insertBatch(objects, violation);
        self.markDirty(table);
        return ids;
    }

    /// 更新实体（按 `getId()` 匹配；失败时由库释放传入对象）。
    pub fn update(self: *MemoryDb, comptime T: type, object: T, violation: ?*Violation) Error!void {
        const table = self.tableFor(T) catch |err| {
            var discard = object;
            discard.deinit();
            return err;
        };
        try table.update(object, violation);
        self.markDirty(table);
    }

    /// 删除实体（不存在返回 `false`）。
    pub fn delete(self: *MemoryDb, comptime T: type, id: i64) Error!bool {
        const table = try self.tableFor(T);
        const deleted = table.delete(id);
        if (deleted) self.markDirty(table);
        return deleted;
    }

    /// 清空指定类型的全部数据（并随后持久化为空表）。
    pub fn clear(self: *MemoryDb, comptime T: type) Error!void {
        const table = try self.tableFor(T);
        table.clear();
        self.markDirty(table);
    }

    /// 清空全部已加载表。
    pub fn clearAll(self: *MemoryDb) void {
        const inner = self.inner;
        var list: std.ArrayList(table_mod.AnyTable) = .empty;
        defer list.deinit(inner.gpa);

        inner.tables_lock.lockSharedUncancelable(inner.io);
        {
            var iterator = inner.tables.valueIterator();
            while (iterator.next()) |any| {
                list.append(inner.gpa, any.*) catch break;
            }
        }
        inner.tables_lock.unlockShared(inner.io);

        var changed = false;
        for (list.items) |any| {
            any.vtable.clear(any.ptr);
            changed = any.vtable.markDirty(any.ptr) or changed;
        }
        if (changed) inner.hub.notify(inner.io);
    }

    /// 同步写盘所有脏表（后台线程未启用时同样可用）。
    pub fn flush(self: *MemoryDb) Error!void {
        const inner = self.inner;
        if (inner.base_dir.len == 0) return;
        var list: std.ArrayList(table_mod.AnyTable) = .empty;
        defer list.deinit(inner.gpa);

        inner.tables_lock.lockSharedUncancelable(inner.io);
        {
            var iterator = inner.tables.valueIterator();
            while (iterator.next()) |any| {
                if (!any.vtable.isDirty(any.ptr)) continue;
                list.append(inner.gpa, any.*) catch {
                    inner.tables_lock.unlockShared(inner.io);
                    return error.OutOfMemory;
                };
            }
        }
        inner.tables_lock.unlockShared(inner.io);

        for (list.items) |any| {
            const path = persist.tablePathAlloc(inner.gpa, inner.base_dir, any.type_name) catch
                return error.OutOfMemory;
            defer inner.gpa.free(path);
            _ = any.vtable.saveTo(any.ptr, path, inner.options.pretty) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.PersistError,
            };
        }
    }

    // ------------------------------------------------------------------
    // 读操作
    // ------------------------------------------------------------------

    pub fn findById(self: *MemoryDb, comptime T: type, id: i64) Error!?entity.Ref(T) {
        const table = try self.tableFor(T);
        return table.findById(id);
    }

    pub fn findAll(self: *MemoryDb, comptime T: type) Error!entity.List(T) {
        const table = try self.tableFor(T);
        return table.findAll() catch |err| return mapAlloc(err);
    }

    pub fn findBy(
        self: *MemoryDb,
        comptime T: type,
        field: []const u8,
        input: model.Value,
    ) Error!entity.List(T) {
        const table = try self.tableFor(T);
        return table.findBy(field, input) catch |err| return mapAlloc(err);
    }

    pub fn findByRange(
        self: *MemoryDb,
        comptime T: type,
        field: []const u8,
        min_input: model.Value,
        max_input: model.Value,
    ) Error!entity.List(T) {
        const table = try self.tableFor(T);
        return table.findByRange(field, min_input, max_input) catch |err| return mapAlloc(err);
    }

    pub fn findByLike(self: *MemoryDb, comptime T: type, field: []const u8, pattern: []const u8) Error!entity.List(T) {
        const table = try self.tableFor(T);
        return table.findByLike(field, pattern) catch |err| return mapAlloc(err);
    }

    pub fn findByMultiple(
        self: *MemoryDb,
        comptime T: type,
        conditions: []const model.Condition,
    ) Error!entity.List(T) {
        const table = try self.tableFor(T);
        return table.findByMultiple(conditions) catch |err| return mapAlloc(err);
    }

    pub fn findByPage(
        self: *MemoryDb,
        comptime T: type,
        sort_field: ?[]const u8,
        page_index: usize,
        page_size: usize,
        ascending: bool,
    ) Error!entity.Page(T) {
        const table = try self.tableFor(T);
        return table.findByPage(sort_field, page_index, page_size, ascending) catch |err| return mapAlloc(err);
    }

    pub fn findByUnique(
        self: *MemoryDb,
        comptime T: type,
        field: []const u8,
        input: model.Value,
    ) Error!?entity.Ref(T) {
        const table = try self.tableFor(T);
        return table.findByUnique(field, input);
    }

    pub fn findByCompositeUnique(
        self: *MemoryDb,
        comptime T: type,
        group: []const u8,
        inputs: []const model.Condition,
    ) Error!?entity.Ref(T) {
        const table = try self.tableFor(T);
        return table.findByCompositeUnique(group, inputs);
    }

    pub fn isUniqueValueExists(
        self: *MemoryDb,
        comptime T: type,
        field: []const u8,
        input: model.Value,
        exclude_id: ?i64,
    ) Error!bool {
        const table = try self.tableFor(T);
        return table.isUniqueValueExists(field, input, exclude_id);
    }

    /// 全库统计（`statistics` 内部分配，用 `DbStatistics.deinit(gpa)` 释放）。
    pub fn statistics(self: *MemoryDb, gpa: std.mem.Allocator) Error!DbStatistics {
        const inner = self.inner;
        var list: std.ArrayList(table_mod.AnyTable) = .empty;
        defer list.deinit(inner.gpa);

        inner.tables_lock.lockSharedUncancelable(inner.io);
        {
            var iterator = inner.tables.valueIterator();
            while (iterator.next()) |any| {
                list.append(inner.gpa, any.*) catch {
                    inner.tables_lock.unlockShared(inner.io);
                    return error.OutOfMemory;
                };
            }
        }
        inner.tables_lock.unlockShared(inner.io);

        const tables = try gpa.alloc(model.TableStatistics, list.items.len);
        errdefer gpa.free(tables);
        var count: usize = 0;
        errdefer {
            for (tables[0..count]) |*stats| stats.deinit(gpa);
        }
        for (list.items) |any| {
            tables[count] = any.vtable.statistics(any.ptr, gpa) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.PersistError,
            };
            count += 1;
        }
        if (count > 1) {
            std.mem.sortUnstable(model.TableStatistics, tables, {}, struct {
                fn lessThan(_: void, a: model.TableStatistics, b: model.TableStatistics) bool {
                    return std.mem.lessThan(u8, a.type_name, b.type_name);
                }
            }.lessThan);
        }
        var total_rows: usize = 0;
        for (tables) |stats| total_rows += stats.rows;
        return .{ .tables = tables, .table_count = tables.len, .total_rows = total_rows };
    }

    /// 取表（高级用法：单表 flush/统计/直接操作；首次访问时创建并加载）。
    pub fn tableOf(self: *MemoryDb, comptime T: type) Error!*table_mod.Table(T) {
        return self.tableFor(T);
    }

    // ------------------------------------------------------------------
    // 内部
    // ------------------------------------------------------------------

    fn markDirty(self: *MemoryDb, table: anytype) void {
        // 纯内存实例（base_dir 为空）不落盘，也就不需要脏标记与后台唤醒
        if (self.inner.base_dir.len == 0) return;
        if (table.markDirty()) self.inner.hub.notify(self.inner.io);
    }

    fn dataFilePath(self: *MemoryDb, comptime T: type) Error!?[]u8 {
        if (self.inner.base_dir.len == 0) return null;
        return persist.tablePathAlloc(self.inner.gpa, self.inner.base_dir, entity.typeName(T)) catch
            error.OutOfMemory;
    }

    fn tableFor(self: *MemoryDb, comptime T: type) Error!*table_mod.Table(T) {
        const inner = self.inner;
        const name = entity.typeName(T);

        inner.tables_lock.lockSharedUncancelable(inner.io);
        if (inner.tables.get(name)) |any| {
            inner.tables_lock.unlockShared(inner.io);
            return table_mod.AnyTable.cast(T, any);
        }
        inner.tables_lock.unlockShared(inner.io);

        inner.tables_lock.lockUncancelable(inner.io);
        defer inner.tables_lock.unlock(inner.io);
        if (inner.tables.get(name)) |any| return table_mod.AnyTable.cast(T, any);

        const table = try inner.gpa.create(table_mod.Table(T));
        errdefer inner.gpa.destroy(table);
        table.* = try table_mod.Table(T).init(inner.gpa, inner.io);
        errdefer table.deinit();

        const maybe_path = try self.dataFilePath(T);
        if (maybe_path) |path| {
            defer inner.gpa.free(path);
            table.load(path);
        }
        try inner.tables.put(name, table.asAny());
        return table;
    }

    fn workerMain(inner: *Inner) void {
        while (true) {
            inner.hub.wait(inner.io);
            if (inner.hub.isStopped(inner.io)) return;
            inner.hub.takePending(inner.io);
            inner.hub.waitMinInterval(inner.io, inner.options.min_write_interval_ms);
            if (inner.hub.isStopped(inner.io)) return;

            var list: std.ArrayList(table_mod.AnyTable) = .empty;
            defer list.deinit(inner.gpa);
            {
                inner.tables_lock.lockSharedUncancelable(inner.io);
                defer inner.tables_lock.unlockShared(inner.io);
                var iterator = inner.tables.valueIterator();
                while (iterator.next()) |any| {
                    if (!any.vtable.isDirty(any.ptr)) continue;
                    list.append(inner.gpa, any.*) catch break;
                }
            }

            for (list.items) |any| {
                if (inner.hub.isStopped(inner.io)) return;
                const path = persist.tablePathAlloc(inner.gpa, inner.base_dir, any.type_name) catch continue;
                defer inner.gpa.free(path);
                _ = any.vtable.saveTo(any.ptr, path, inner.options.pretty) catch |err| {
                    log.err("后台写盘 {s} 失败：{s}", .{ any.type_name, @errorName(err) });
                    continue;
                };
            }
            inner.hub.markWritten(inner.io);
        }
    }
};

fn mapAlloc(err: anyerror) Error {
    return if (err == error.OutOfMemory) error.OutOfMemory else error.PersistError;
}

// ----------------------------------------------------------------------
// 全局单例（cdb 风格）
// ----------------------------------------------------------------------

var g_instance: std.atomic.Value(?*MemoryDb) = std.atomic.Value(?*MemoryDb).init(null);

/// 配置全局实例（只能调用一次；须在首次使用 `global()` 之前）。
pub fn configureGlobal(gpa: std.mem.Allocator, io: std.Io, options: DbOptions) Error!void {
    if (g_instance.load(.acquire) != null) return error.AlreadyConfigured;
    const db = try gpa.create(MemoryDb);
    errdefer gpa.destroy(db);
    db.* = try MemoryDb.init(gpa, io, options);
    if (g_instance.cmpxchgStrong(null, db, .acq_rel, .acquire) != null) {
        db.deinit();
        gpa.destroy(db);
        return error.AlreadyConfigured;
    }
}

/// 全局实例（未配置返回 `error.NotConfigured`）。
pub fn global() Error!*MemoryDb {
    return g_instance.load(.acquire) orelse error.NotConfigured;
}

/// 销毁全局实例（测试/进程退出前调用）。
pub fn deinitGlobal() void {
    const db = g_instance.swap(null, .acq_rel) orelse return;
    const gpa = db.inner.gpa;
    db.deinit();
    gpa.destroy(db);
}

// —— 全局自由函数（cdb 风格） ——

pub fn insert(comptime T: type, object: T, violation: ?*Violation) Error!i64 {
    return (try global()).insert(T, object, violation);
}

pub fn insertByIndex(
    comptime T: type,
    object: T,
    fields: []const []const u8,
    violation: ?*Violation,
) Error!i64 {
    return (try global()).insertByIndex(T, object, fields, violation);
}

pub fn insertBatch(comptime T: type, objects: []T, violation: ?*Violation) Error![]i64 {
    return (try global()).insertBatch(T, objects, violation);
}

pub fn update(comptime T: type, object: T, violation: ?*Violation) Error!void {
    return (try global()).update(T, object, violation);
}

pub fn delete(comptime T: type, id: i64) Error!bool {
    return (try global()).delete(T, id);
}

pub fn clear(comptime T: type) Error!void {
    return (try global()).clear(T);
}

pub fn flush() Error!void {
    return (try global()).flush();
}

pub fn clearAll() void {
    const db = global() catch return;
    db.clearAll();
}

pub fn findById(comptime T: type, id: i64) Error!?entity.Ref(T) {
    return (try global()).findById(T, id);
}

pub fn findAll(comptime T: type) Error!entity.List(T) {
    return (try global()).findAll(T);
}

pub fn findBy(comptime T: type, field: []const u8, input: model.Value) Error!entity.List(T) {
    return (try global()).findBy(T, field, input);
}

pub fn findByRange(
    comptime T: type,
    field: []const u8,
    min_input: model.Value,
    max_input: model.Value,
) Error!entity.List(T) {
    return (try global()).findByRange(T, field, min_input, max_input);
}

pub fn findByLike(comptime T: type, field: []const u8, pattern: []const u8) Error!entity.List(T) {
    return (try global()).findByLike(T, field, pattern);
}

pub fn findByMultiple(comptime T: type, conditions: []const model.Condition) Error!entity.List(T) {
    return (try global()).findByMultiple(T, conditions);
}

pub fn findByPage(
    comptime T: type,
    sort_field: ?[]const u8,
    page_index: usize,
    page_size: usize,
    ascending: bool,
) Error!entity.Page(T) {
    return (try global()).findByPage(T, sort_field, page_index, page_size, ascending);
}

pub fn findByUnique(comptime T: type, field: []const u8, input: model.Value) Error!?entity.Ref(T) {
    return (try global()).findByUnique(T, field, input);
}

pub fn findByCompositeUnique(
    comptime T: type,
    group: []const u8,
    inputs: []const model.Condition,
) Error!?entity.Ref(T) {
    return (try global()).findByCompositeUnique(T, group, inputs);
}

pub fn isUniqueValueExists(
    comptime T: type,
    field: []const u8,
    input: model.Value,
    exclude_id: ?i64,
) Error!bool {
    return (try global()).isUniqueValueExists(T, field, input, exclude_id);
}

pub fn statistics(gpa: std.mem.Allocator) Error!DbStatistics {
    return (try global()).statistics(gpa);
}
