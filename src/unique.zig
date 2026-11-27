//! 唯一约束索引与校验（对应 C# `UniqueConstraintManager` / Rust 版 `unique.rs`）。
//!
//! 接口按「字段描述 + 实体对象」设计（comptime 泛型），这样通用写路径与
//! 加载/持久化路径共用同一套索引逻辑。
//!
//! 与 C# 版差异（沿用 Rust 版修正）：
//! - 键值先按字段类型规范化（`i32` 与 `i64` 的 1 视为同值），比 `object` 相等更符合直觉；
//! - 数据文件加载时若发现冲突，**跳过该对象**（C# 版只记警告但对象仍在表中，
//!   会造成「对象存在、唯一索引缺失」的不一致）。

const std = @import("std");

const errors = @import("error.zig");
const model = @import("model.zig");
const value = @import("value.zig");

pub const Error = errors.Error;
pub const CompositeUniqueRule = model.CompositeUniqueRule;
pub const Field = model.Field;
pub const Key = value.Key;
pub const Violation = model.Violation;

/// 单字段唯一索引：值 → 对象 ID。
pub const KeyIdMap = std.HashMap(Key, i64, value.KeyContext, 80);

/// 复合键（按约束声明的字段顺序；拥有内存）。
pub const CompositeKey = struct {
    items: []Key,

    pub fn deinit(self: CompositeKey, gpa: std.mem.Allocator) void {
        for (self.items) |key| key.deinit(gpa);
        gpa.free(self.items);
    }
};

pub const CompositeContext = struct {
    pub fn hash(_: CompositeContext, key: CompositeKey) u64 {
        var h = std.hash.Wyhash.init(0xC0FF_EE00_1234_5678);
        for (key.items) |item| {
            const item_hash = item.hash();
            h.update(std.mem.asBytes(&item_hash));
        }
        return h.final();
    }

    pub fn eql(_: CompositeContext, a: CompositeKey, b: CompositeKey) bool {
        if (a.items.len != b.items.len) return false;
        for (a.items, b.items) |x, y| {
            if (!x.eql(y)) return false;
        }
        return true;
    }
};

/// 复合唯一索引：组合键 → 对象 ID。
pub const CompositeIdMap = std.HashMap(CompositeKey, i64, CompositeContext, 80);

/// 唯一约束索引集合。
pub const UniqueSet = struct {
    gpa: std.mem.Allocator,
    /// 单字段：字段名 → 值 → 对象 ID。
    fields: std.StringHashMap(KeyIdMap),
    /// 复合：约束组名 → 组合键 → 对象 ID。
    composites: std.StringHashMap(CompositeIdMap),

    pub fn init(gpa: std.mem.Allocator) UniqueSet {
        return .{
            .gpa = gpa,
            .fields = std.StringHashMap(KeyIdMap).init(gpa),
            .composites = std.StringHashMap(CompositeIdMap).init(gpa),
        };
    }

    pub fn deinit(self: *UniqueSet) void {
        var field_iterator = self.fields.iterator();
        while (field_iterator.next()) |entry| {
            freeKeyIdMap(self.gpa, entry.value_ptr);
        }
        self.fields.deinit();

        var composite_iterator = self.composites.iterator();
        while (composite_iterator.next()) |entry| {
            freeCompositeMap(self.gpa, entry.value_ptr);
        }
        self.composites.deinit();
    }

    pub fn clear(self: *UniqueSet) void {
        var field_iterator = self.fields.iterator();
        while (field_iterator.next()) |entry| freeKeyIdMap(self.gpa, entry.value_ptr);
        self.fields.clearRetainingCapacity();

        var composite_iterator = self.composites.iterator();
        while (composite_iterator.next()) |entry| freeCompositeMap(self.gpa, entry.value_ptr);
        self.composites.clearRetainingCapacity();
    }

    /// 单字段唯一值 → 对象 ID（`key` 为借用探针，不转移所有权）。
    pub fn findValue(self: *UniqueSet, field: []const u8, key: Key) ?i64 {
        const map = self.fields.getPtr(field) orelse return null;
        return map.get(key);
    }

    /// 复合约束组合 → 对象 ID（`items` 为借用探针）。
    pub fn findComposite(self: *UniqueSet, group: []const u8, items: []const Key) ?i64 {
        const map = self.composites.getPtr(group) orelse return null;
        return map.get(.{ .items = @constCast(items) });
    }

    /// 校验对象的全部唯一约束（`exclude` 为更新时排除的自身 ID）。
    pub fn validate(
        self: *UniqueSet,
        fields: []const Field,
        composites: []const CompositeUniqueRule,
        obj: anytype,
        exclude: ?i64,
        violation: ?*Violation,
    ) Error!void {
        for (fields) |field| {
            const rule = field.unique orelse continue;
            const raw = obj.getField(field.name) orelse value.Value{ .null = {} };
            if (value.isNull(raw)) {
                if (!rule.allow_null) {
                    fillViolation(violation, .{
                        .property_name = field.name,
                        .constraint_type = .single,
                        .detail = .null_not_allowed,
                        .message = rule.message,
                    });
                    return error.UniqueViolation;
                }
                continue;
            }
            const key = (try value.normalize(raw, field.kind, self.gpa)) orelse continue;
            defer key.deinit(self.gpa);
            if (self.findValue(field.name, key)) |existing| {
                if (exclude == null or exclude.? != existing) {
                    fillViolation(violation, .{
                        .property_name = field.name,
                        .constraint_type = .single,
                        .conflicting_id = existing,
                        .message = rule.message,
                    });
                    return error.UniqueViolation;
                }
            }
        }

        for (composites) |rule| {
            const built = try buildCompositeKey(self.gpa, fields, rule, obj);
            defer freeCompositeParts(self.gpa, built);
            if (built.has_null) {
                if (rule.allow_null) continue;
                fillViolation(violation, .{
                    .property_name = rule.group,
                    .fields = rule.fields,
                    .constraint_type = .composite,
                    .detail = .null_not_allowed,
                    .message = rule.message,
                });
                return error.UniqueViolation;
            }
            if (self.findComposite(rule.group, built.key)) |existing| {
                if (exclude == null or exclude.? != existing) {
                    fillViolation(violation, .{
                        .property_name = rule.group,
                        .fields = rule.fields,
                        .constraint_type = .composite,
                        .conflicting_id = existing,
                        .message = rule.message,
                    });
                    return error.UniqueViolation;
                }
            }
        }
    }

    /// 写入对象的唯一约束索引（两阶段：先全部校验，再统一写入；失败时索引保持不变）。
    pub fn add(
        self: *UniqueSet,
        fields: []const Field,
        composites: []const CompositeUniqueRule,
        obj_id: i64,
        obj: anytype,
        violation: ?*Violation,
    ) Error!void {
        var pending_fields: std.ArrayList(struct { name: []const u8, key: Key }) = .empty;
        defer {
            for (pending_fields.items) |item| item.key.deinit(self.gpa);
            pending_fields.deinit(self.gpa);
        }
        var pending_composites: std.ArrayList(struct { group: []const u8, key: CompositeKey }) = .empty;
        defer {
            for (pending_composites.items) |item| item.key.deinit(self.gpa);
            pending_composites.deinit(self.gpa);
        }

        for (fields) |field| {
            const rule = field.unique orelse continue;
            const raw = obj.getField(field.name) orelse value.Value{ .null = {} };
            if (value.isNull(raw)) {
                if (!rule.allow_null) {
                    fillViolation(violation, .{
                        .property_name = field.name,
                        .constraint_type = .single,
                        .detail = .null_not_allowed,
                        .message = rule.message,
                    });
                    return error.UniqueViolation;
                }
                continue;
            }
            const key = (try value.normalize(raw, field.kind, self.gpa)) orelse continue;
            if (self.findValue(field.name, key)) |existing| {
                key.deinit(self.gpa);
                fillViolation(violation, .{
                    .property_name = field.name,
                    .constraint_type = .single,
                    .conflicting_id = existing,
                    .message = rule.message,
                });
                return error.UniqueViolation;
            }
            try pending_fields.append(self.gpa, .{ .name = field.name, .key = key });
        }

        for (composites) |rule| {
            const built = try buildCompositeKey(self.gpa, fields, rule, obj);
            if (built.has_null) {
                freeCompositeParts(self.gpa, built);
                if (!rule.allow_null) {
                    fillViolation(violation, .{
                        .property_name = rule.group,
                        .fields = rule.fields,
                        .constraint_type = .composite,
                        .detail = .null_not_allowed,
                        .message = rule.message,
                    });
                    return error.UniqueViolation;
                }
                continue;
            }
            if (self.findComposite(rule.group, built.key)) |existing| {
                freeCompositeParts(self.gpa, built);
                fillViolation(violation, .{
                    .property_name = rule.group,
                    .fields = rule.fields,
                    .constraint_type = .composite,
                    .conflicting_id = existing,
                    .message = rule.message,
                });
                return error.UniqueViolation;
            }
            try pending_composites.append(self.gpa, .{ .group = rule.group, .key = .{ .items = built.key } });
        }

        // 校验全部通过：写入不会失败（失败只会是 OOM，此时按半写入处理并返回错误）
        for (pending_fields.items) |item| {
            const gop = try self.fields.getOrPut(item.name);
            if (!gop.found_existing) gop.value_ptr.* = KeyIdMap.init(self.gpa);
            try gop.value_ptr.put(item.key, obj_id);
        }
        pending_fields.clearRetainingCapacity();

        for (pending_composites.items) |item| {
            const gop = try self.composites.getOrPut(item.group);
            if (!gop.found_existing) gop.value_ptr.* = CompositeIdMap.init(self.gpa);
            try gop.value_ptr.put(item.key, obj_id);
        }
        pending_composites.clearRetainingCapacity();
    }

    /// 更新对象的唯一约束索引（按字段/复合键 diff；两阶段：先校验全部变更，再统一应用）。
    pub fn updateEntity(
        self: *UniqueSet,
        fields: []const Field,
        composites: []const CompositeUniqueRule,
        obj_id: i64,
        old_obj: anytype,
        new_obj: anytype,
        violation: ?*Violation,
    ) Error!void {
        const FieldChange = struct { name: []const u8, old: ?Key, new: ?Key };
        const CompositeChange = struct { group: []const u8, old: ?CompositeKey, new: ?CompositeKey };

        var field_changes: std.ArrayList(FieldChange) = .empty;
        defer {
            for (field_changes.items) |change| {
                if (change.old) |key| key.deinit(self.gpa);
                if (change.new) |key| key.deinit(self.gpa);
            }
            field_changes.deinit(self.gpa);
        }
        var composite_changes: std.ArrayList(CompositeChange) = .empty;
        defer {
            for (composite_changes.items) |change| {
                if (change.old) |key| key.deinit(self.gpa);
                if (change.new) |key| key.deinit(self.gpa);
            }
            composite_changes.deinit(self.gpa);
        }

        for (fields) |field| {
            const rule = field.unique orelse continue;
            const old_key = try normalizeField(self.gpa, field, old_obj);
            const new_key = try normalizeField(self.gpa, field, new_obj);
            const same = (old_key == null and new_key == null) or
                (old_key != null and new_key != null and old_key.?.eql(new_key.?));
            if (same) {
                if (old_key) |key| key.deinit(self.gpa);
                if (new_key) |key| key.deinit(self.gpa);
                continue;
            }
            if (new_key) |key| {
                if (self.findValue(field.name, key)) |existing| {
                    if (existing != obj_id) {
                        if (old_key) |old| old.deinit(self.gpa);
                        key.deinit(self.gpa);
                        fillViolation(violation, .{
                            .property_name = field.name,
                            .constraint_type = .single,
                            .conflicting_id = existing,
                            .message = rule.message,
                        });
                        return error.UniqueViolation;
                    }
                }
            }
            try field_changes.append(self.gpa, .{ .name = field.name, .old = old_key, .new = new_key });
        }

        for (composites) |rule| {
            const old_key = try buildCompositeKeyOpt(self.gpa, fields, rule, old_obj, violation);
            const new_key = try buildCompositeKeyOpt(self.gpa, fields, rule, new_obj, violation);
            const same = (old_key == null and new_key == null) or
                (old_key != null and new_key != null and
                    CompositeContext.eql(.{}, old_key.?, new_key.?));
            if (same) {
                if (old_key) |key| key.deinit(self.gpa);
                if (new_key) |key| key.deinit(self.gpa);
                continue;
            }
            if (new_key) |key| {
                if (self.findComposite(rule.group, key.items)) |existing| {
                    if (existing != obj_id) {
                        if (old_key) |old| old.deinit(self.gpa);
                        key.deinit(self.gpa);
                        fillViolation(violation, .{
                            .property_name = rule.group,
                            .fields = rule.fields,
                            .constraint_type = .composite,
                            .conflicting_id = existing,
                            .message = rule.message,
                        });
                        return error.UniqueViolation;
                    }
                }
            }
            try composite_changes.append(self.gpa, .{ .group = rule.group, .old = old_key, .new = new_key });
        }

        // 校验全部通过：应用变更（先删旧键再写新键）
        //
        // 注意：`old` 是本地探针（拥有内存），用完后必须立即释放并把槽位置空；
        // `new` 的所有权转移给索引。不置空的话函数尾部的 defer 会二次释放。
        for (field_changes.items) |*change| {
            if (change.old) |old_key| {
                self.removeFieldValue(change.name, old_key);
                old_key.deinit(self.gpa);
                change.old = null;
            }
            if (change.new) |new_key| {
                const gop = try self.fields.getOrPut(change.name);
                if (!gop.found_existing) gop.value_ptr.* = KeyIdMap.init(self.gpa);
                try gop.value_ptr.put(new_key, obj_id);
                change.new = null;
            }
        }
        for (composite_changes.items) |*change| {
            if (change.old) |old_key| {
                self.removeCompositeValue(change.group, old_key.items);
                old_key.deinit(self.gpa);
                change.old = null;
            }
            if (change.new) |new_key| {
                const gop = try self.composites.getOrPut(change.group);
                if (!gop.found_existing) gop.value_ptr.* = CompositeIdMap.init(self.gpa);
                try gop.value_ptr.put(new_key, obj_id);
                change.new = null;
            }
        }
    }

    /// 移除对象的唯一约束索引（对未写入的键同样安全）。
    pub fn remove(
        self: *UniqueSet,
        fields: []const Field,
        composites: []const CompositeUniqueRule,
        obj: anytype,
    ) Error!void {
        for (fields) |field| {
            if (field.unique == null) continue;
            const raw = obj.getField(field.name) orelse value.Value{ .null = {} };
            const key = (try value.normalize(raw, field.kind, self.gpa)) orelse continue;
            self.removeFieldValue(field.name, key);
            key.deinit(self.gpa);
        }
        for (composites) |rule| {
            const built = try buildCompositeKey(self.gpa, fields, rule, obj);
            if (!built.has_null) self.removeCompositeValue(rule.group, built.key);
            freeCompositeParts(self.gpa, built);
        }
    }

    fn removeFieldValue(self: *UniqueSet, field: []const u8, probe: Key) void {
        const map = self.fields.getPtr(field) orelse return;
        if (map.fetchRemove(probe)) |removed| {
            var stored_key = removed.key;
            stored_key.deinit(self.gpa);
        }
        if (map.count() == 0) {
            map.deinit();
            _ = self.fields.remove(field);
        }
    }

    fn removeCompositeValue(self: *UniqueSet, group: []const u8, probe: []const Key) void {
        const map = self.composites.getPtr(group) orelse return;
        if (map.fetchRemove(.{ .items = @constCast(probe) })) |removed| {
            removed.key.deinit(self.gpa);
        }
        if (map.count() == 0) {
            map.deinit();
            _ = self.composites.remove(group);
        }
    }
};

fn freeKeyIdMap(gpa: std.mem.Allocator, map: *KeyIdMap) void {
    var iterator = map.iterator();
    while (iterator.next()) |entry| entry.key_ptr.deinit(gpa);
    map.deinit();
}

fn freeCompositeMap(gpa: std.mem.Allocator, map: *CompositeIdMap) void {
    var iterator = map.iterator();
    while (iterator.next()) |entry| entry.key_ptr.deinit(gpa);
    map.deinit();
}

fn fillViolation(violation: ?*Violation, details: Violation) void {
    if (violation) |out| out.* = details;
}

const BuiltComposite = struct {
    key: []Key,
    has_null: bool,
};

fn freeCompositeParts(gpa: std.mem.Allocator, built: BuiltComposite) void {
    for (built.key) |key| key.deinit(gpa);
    gpa.free(built.key);
}

fn normalizeField(gpa: std.mem.Allocator, field: Field, obj: anytype) Error!?Key {
    const raw = obj.getField(field.name) orelse value.Value{ .null = {} };
    return value.normalize(raw, field.kind, gpa);
}

/// 构造复合键（按约束声明的字段顺序；任一值为空时 `has_null = true`）。
fn buildCompositeKey(
    gpa: std.mem.Allocator,
    fields: []const Field,
    rule: CompositeUniqueRule,
    obj: anytype,
) Error!BuiltComposite {
    const items = try gpa.alloc(Key, rule.fields.len);
    errdefer gpa.free(items);

    var has_null = false;
    var filled: usize = 0;
    errdefer {
        for (items[0..filled]) |key| key.deinit(gpa);
    }

    for (rule.fields, 0..) |name, index| {
        const field = findField(fields, name) orelse return error.InvalidField;
        const raw = obj.getField(field.name) orelse value.Value{ .null = {} };
        if (try value.normalize(raw, field.kind, gpa)) |key| {
            items[index] = key;
            filled += 1;
        } else {
            // 空值用「空文本」占位（不参与比较；`has_null = true` 时整键不写入索引）
            items[index] = .{ .text = try gpa.dupe(u8, "") };
            filled += 1;
            has_null = true;
        }
    }
    return .{ .key = items, .has_null = has_null };
}

/// 构造复合键；含空值时返回 `None`（允许空）或错误（不允许空）。
fn buildCompositeKeyOpt(
    gpa: std.mem.Allocator,
    fields: []const Field,
    rule: CompositeUniqueRule,
    obj: anytype,
    violation: ?*Violation,
) Error!?CompositeKey {
    const built = try buildCompositeKey(gpa, fields, rule, obj);
    if (!built.has_null) return CompositeKey{ .items = built.key };
    freeCompositeParts(gpa, built);
    if (rule.allow_null) return null;
    fillViolation(violation, .{
        .property_name = rule.group,
        .fields = rule.fields,
        .constraint_type = .composite,
        .detail = .null_not_allowed,
        .message = rule.message,
    });
    return error.UniqueViolation;
}

fn findField(fields: []const Field, name: []const u8) ?*const Field {
    for (fields) |*field| {
        if (std.mem.eql(u8, field.name, name)) return field;
    }
    return null;
}
