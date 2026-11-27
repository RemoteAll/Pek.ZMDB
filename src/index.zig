//! 类型感知索引（对应 C# `TypedIndexManager` / Rust 版 `index.rs`）。
//!
//! | 字段类型 | 索引结构 | 能力 |
//! |---|---|---|
//! | 布尔 | 双桶 `IdSet` | 精确（O(1)）、智能值模式 |
//! | 整数/浮点/时间 | [`KeyMap`]（有序 Treap） | 精确、范围 `O(log n + k)`、分页顺序 |
//! | 文本 | 精确哈希 + 小写有序 Treap | 精确（区分大小写）、大小写不敏感精确/前缀/包含/后缀/通配、范围、分页顺序 |
//! | JSON | 文本哈希 | 按 JSON 文本精确 |
//!
//! 与 C# 版的差异（对齐 Rust 版并保留其修正）：
//! - 值用 [`Key`] 枚举而非 `object` 装箱，跨类型查询按字段类型规范化；
//! - 范围查询走有序结构（C# 为遍历字典 `O(n)`）；
//! - 字符串前缀查询走有序范围，只有包含/后缀/复杂通配才遍历键。

const std = @import("std");
const zzig = @import("zzig");

const model = @import("model.zig");
const ordered = @import("ordered.zig");
const value = @import("value.zig");

pub const Field = model.Field;
pub const FieldKind = value.FieldKind;
pub const Key = value.Key;
pub const IdSet = ordered.IdSet;
pub const KeyMap = ordered.KeyMap;

/// 文本索引：精确（区分大小写）+ 小写有序（大小写不敏感查询）。
pub const TextIndex = struct {
    exact: std.StringHashMap(IdSet),
    lower: KeyMap,

    pub fn init(gpa: std.mem.Allocator) TextIndex {
        return .{ .exact = std.StringHashMap(IdSet).init(gpa), .lower = KeyMap.init(gpa) };
    }

    pub fn deinit(self: *TextIndex, gpa: std.mem.Allocator) void {
        var iterator = self.exact.iterator();
        while (iterator.next()) |entry| {
            gpa.free(entry.key_ptr.*);
            entry.value_ptr.deinit(gpa);
        }
        self.exact.deinit();
        self.lower.deinit();
    }
};

/// 单字段索引（按字段类型分派）。
pub const TypedIndex = union(enum) {
    boolean: [2]IdSet,
    ordered: KeyMap,
    text: TextIndex,
    /// JSON 等复杂值：按文本精确索引。
    exact: std.StringHashMap(IdSet),

    pub fn init(gpa: std.mem.Allocator, kind: FieldKind) TypedIndex {
        return switch (kind) {
            .boolean => .{ .boolean = .{ .{}, .{} } },
            .int, .float, .time => .{ .ordered = KeyMap.init(gpa) },
            .text => .{ .text = TextIndex.init(gpa) },
            .json => .{ .exact = std.StringHashMap(IdSet).init(gpa) },
        };
    }

    pub fn deinit(self: *TypedIndex, gpa: std.mem.Allocator) void {
        switch (self.*) {
            .boolean => |*buckets| {
                buckets[0].deinit(gpa);
                buckets[1].deinit(gpa);
            },
            .ordered => |*map| map.deinit(),
            .text => |*index| index.deinit(gpa),
            .exact => |*map| {
                var iterator = map.iterator();
                while (iterator.next()) |entry| {
                    gpa.free(entry.key_ptr.*);
                    entry.value_ptr.deinit(gpa);
                }
                map.deinit();
            },
        }
    }

    /// 加索引（**接管 `key` 的所有权**；未使用时由这里释放）。返回是否新增了 ID。
    pub fn add(self: *TypedIndex, gpa: std.mem.Allocator, key: Key, id: i64) !bool {
        switch (self.*) {
            .boolean => |*buckets| {
                const slot: usize = if (key == .boolean and key.boolean) 1 else 0;
                return buckets[slot].insert(gpa, id);
            },
            .ordered => |*map| {
                const entry = try map.getOrPut(key);
                return entry.node.ids.insert(gpa, id);
            },
            .exact => |*map| {
                const text = switch (key) {
                    .text => |t| t,
                    else => {
                        key.deinit(gpa);
                        return false;
                    },
                };
                const entry = try map.getOrPut(text);
                if (!entry.found_existing) {
                    entry.key_ptr.* = text;
                    entry.value_ptr.* = .{};
                } else {
                    gpa.free(text);
                }
                return entry.value_ptr.insert(gpa, id);
            },
            .text => |*index| {
                const text = switch (key) {
                    .text => |t| t,
                    else => {
                        key.deinit(gpa);
                        return false;
                    },
                };
                const exact_entry = try index.exact.getOrPut(text);
                if (!exact_entry.found_existing) {
                    exact_entry.key_ptr.* = text;
                    exact_entry.value_ptr.* = .{};
                } else {
                    gpa.free(text);
                }
                const added = try exact_entry.value_ptr.insert(gpa, id);

                const lower_text = try asciiLowerAlloc(gpa, exact_entry.key_ptr.*);
                const lower_entry = try index.lower.getOrPut(.{ .text = lower_text });
                if (!lower_entry.created) gpa.free(lower_text);
                _ = try lower_entry.node.ids.insert(gpa, id);
                return added;
            },
        }
    }

    /// 删索引（键不存在安全）。
    pub fn remove(self: *TypedIndex, gpa: std.mem.Allocator, key: Key, id: i64) !bool {
        switch (self.*) {
            .boolean => |*buckets| {
                const slot: usize = if (key == .boolean and key.boolean) 1 else 0;
                return buckets[slot].remove(id);
            },
            .ordered => |*map| {
                const node = map.findNode(key) orelse return false;
                const removed = node.ids.remove(id);
                if (node.ids.count() == 0) _ = map.remove(key);
                return removed;
            },
            .exact => |*map| {
                const text = switch (key) {
                    .text => |t| t,
                    else => return false,
                };
                const entry = map.getEntry(text) orelse return false;
                const removed = entry.value_ptr.remove(id);
                if (entry.value_ptr.count() == 0) {
                    const removed_entry = map.fetchRemove(text).?;
                    gpa.free(removed_entry.key);
                    var ids = removed_entry.value;
                    ids.deinit(gpa);
                }
                return removed;
            },
            .text => |*index| {
                const text = switch (key) {
                    .text => |t| t,
                    else => return false,
                };
                var removed = false;
                if (index.exact.getEntry(text)) |entry| {
                    removed = entry.value_ptr.remove(id);
                    if (entry.value_ptr.count() == 0) {
                        const removed_entry = index.exact.fetchRemove(text).?;
                        gpa.free(removed_entry.key);
                        var ids = removed_entry.value;
                        ids.deinit(gpa);
                    }
                }
                const lower_text = try asciiLowerAlloc(gpa, text);
                defer gpa.free(lower_text);
                if (index.lower.findNode(.{ .text = lower_text })) |node| {
                    _ = node.ids.remove(id);
                    if (node.ids.count() == 0) _ = index.lower.remove(.{ .text = lower_text });
                }
                return removed;
            },
        }
    }

    /// 精确查询（结果追加到 `out`）。
    pub fn find(self: *TypedIndex, gpa: std.mem.Allocator, key: Key, out: *std.ArrayList(i64)) !void {
        switch (self.*) {
            .boolean => |*buckets| {
                const slot: usize = if (key == .boolean and key.boolean) 1 else 0;
                try buckets[slot].appendTo(gpa, out);
            },
            .ordered => |*map| {
                if (map.findNode(key)) |node| try node.ids.appendTo(gpa, out);
            },
            .exact => |*map| {
                if (key == .text) {
                    if (map.getPtr(key.text)) |ids| try ids.appendTo(gpa, out);
                }
            },
            .text => |*index| {
                if (key == .text) {
                    if (index.exact.getPtr(key.text)) |ids| try ids.appendTo(gpa, out);
                }
            },
        }
    }

    /// 范围查询（闭区间；文本按小写字典序）。
    pub fn range(self: *TypedIndex, gpa: std.mem.Allocator, min: Key, max: Key, out: *std.ArrayList(i64)) !void {
        if (Key.order(min, max) == .gt) return;
        switch (self.*) {
            .ordered => |*map| try collectRange(gpa, map, min, max, out),
            .text => |*index| {
                const min_text = switch (min) {
                    .text => |t| t,
                    else => return,
                };
                const max_text = switch (max) {
                    .text => |t| t,
                    else => return,
                };
                const lower_min = try asciiLowerAlloc(gpa, min_text);
                defer gpa.free(lower_min);
                const lower_max = try asciiLowerAlloc(gpa, max_text);
                defer gpa.free(lower_max);
                try collectRange(gpa, &index.lower, .{ .text = lower_min }, .{ .text = lower_max }, out);
            },
            else => {},
        }
    }

    /// 模式查询（`*`/`?` 通配、大小写不敏感；布尔智能值）。
    pub fn pattern(self: *TypedIndex, gpa: std.mem.Allocator, pattern_text: []const u8, out: *std.ArrayList(i64)) !void {
        if (pattern_text.len == 0) return;
        switch (self.*) {
            .boolean => |*buckets| {
                const flag = value.parseBoolPattern(pattern_text) orelse return;
                try buckets[@intFromBool(flag)].appendTo(gpa, out);
            },
            .text => |*index| try textPattern(gpa, index, pattern_text, out),
            else => {},
        }
    }

    /// 唯一值数量（统计用）。
    pub fn uniqueValueCount(self: *TypedIndex) usize {
        return switch (self.*) {
            .boolean => |*buckets| (if (buckets[0].count() > 0) @as(usize, 1) else 0) +
                (if (buckets[1].count() > 0) @as(usize, 1) else 0),
            .ordered => |*map| map.countOf(),
            .text => |*index| index.exact.count(),
            .exact => |*map| map.count(),
        };
    }

    /// 按索引顺序取前 `limit` 个 ID；不支持的索引类型返回 `false`。
    pub fn takeOrdered(
        self: *TypedIndex,
        gpa: std.mem.Allocator,
        ascending: bool,
        limit: usize,
        out: *std.ArrayList(i64),
    ) !bool {
        switch (self.*) {
            .ordered => |*map| {
                try takeFromMap(gpa, map, ascending, limit, out);
                return true;
            },
            .text => |*index| {
                try takeFromMap(gpa, &index.lower, ascending, limit, out);
                return true;
            },
            else => return false,
        }
    }
};

fn collectRange(
    gpa: std.mem.Allocator,
    map: *KeyMap,
    min: Key,
    max: Key,
    out: *std.ArrayList(i64),
) !void {
    var node = map.lowerBound(min);
    while (node) |n| {
        if (Key.order(n.key, max) == .gt) break;
        try n.ids.appendTo(gpa, out);
        node = map.next(n);
    }
}

fn takeFromMap(
    gpa: std.mem.Allocator,
    map: *KeyMap,
    ascending: bool,
    limit: usize,
    out: *std.ArrayList(i64),
) !void {
    var node = if (ascending) map.first() else map.last();
    while (node) |n| {
        for (n.ids.ids.items) |id| {
            try out.append(gpa, id);
            if (out.items.len >= limit) return;
        }
        node = if (ascending) map.next(n) else map.prev(n);
    }
}

fn textPattern(
    gpa: std.mem.Allocator,
    index: *TextIndex,
    pattern: []const u8,
    out: *std.ArrayList(i64),
) !void {
    const lower_pattern = try asciiLowerAlloc(gpa, pattern);
    defer gpa.free(lower_pattern);

    const has_star = std.mem.indexOfScalar(u8, pattern, '*') != null;
    if (!has_star) {
        // 精确（大小写不敏感，对齐 C# `StringIndex.GetByPattern`）
        if (index.lower.findNode(.{ .text = lower_pattern })) |node| {
            try node.ids.appendTo(gpa, out);
        }
        return;
    }

    const starts_star = pattern[0] == '*';
    const ends_star = pattern[pattern.len - 1] == '*';
    if (starts_star and ends_star) {
        // `*abc*` —— 包含
        const needle = std.mem.trim(u8, lower_pattern, "*");
        if (needle.len == 0) {
            try collectAllLower(gpa, index, out);
            return;
        }
        var node = index.lower.first();
        while (node) |n| {
            if (zzig.ascii.containsIgnoreCase(n.key.text, needle)) try n.ids.appendTo(gpa, out);
            node = index.lower.next(n);
        }
        return;
    }
    if (ends_star) {
        // `abc*` —— 前缀（有序范围）
        const prefix = std.mem.trimEnd(u8, lower_pattern, "*");
        if (prefix.len == 0) {
            try collectAllLower(gpa, index, out);
            return;
        }
        var node = index.lower.lowerBound(.{ .text = @constCast(prefix) });
        while (node) |n| {
            if (!std.mem.startsWith(u8, n.key.text, prefix)) break;
            try n.ids.appendTo(gpa, out);
            node = index.lower.next(n);
        }
        return;
    }
    if (starts_star) {
        // `*abc` —— 后缀
        const suffix = std.mem.trimStart(u8, lower_pattern, "*");
        var node = index.lower.first();
        while (node) |n| {
            if (std.mem.endsWith(u8, n.key.text, suffix)) try n.ids.appendTo(gpa, out);
            node = index.lower.next(n);
        }
        return;
    }
    // 复杂通配（如 `a*b*c`）：逐键通配匹配（已统一小写，`?` 单字符）
    var node = index.lower.first();
    while (node) |n| {
        if (wildcardMatch(lower_pattern, n.key.text)) try n.ids.appendTo(gpa, out);
        node = index.lower.next(n);
    }
}

fn collectAllLower(gpa: std.mem.Allocator, index: *TextIndex, out: *std.ArrayList(i64)) !void {
    var node = index.lower.first();
    while (node) |n| {
        try n.ids.appendTo(gpa, out);
        node = index.lower.next(n);
    }
}

/// 纯文本通配（`*` 任意长度、`?` 单字符）。
///
/// 为什么不直接用 `zzig.glob.matchPattern`：那是**路径**语义（含 `/` 会分段匹配、
/// 不含 `/` 时只比较末段），而字段值可能本身就含 `/`（URL、路径类字符串）。
pub fn wildcardMatch(pattern: []const u8, text: []const u8) bool {
    var p: usize = 0;
    var t: usize = 0;
    var star: ?usize = null;
    var mark: usize = 0;
    while (t < text.len) {
        if (p < pattern.len and (pattern[p] == '?' or pattern[p] == text[t])) {
            p += 1;
            t += 1;
        } else if (p < pattern.len and pattern[p] == '*') {
            star = p;
            p += 1;
            mark = t;
        } else if (star) |s| {
            p = s + 1;
            mark += 1;
            t = mark;
        } else {
            return false;
        }
    }
    while (p < pattern.len and pattern[p] == '*') p += 1;
    return p == pattern.len;
}

/// ASCII 小写复制（非 ASCII 字节原样保留；中文等 UTF-8 不受影响）。
pub fn asciiLowerAlloc(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    const out = try gpa.alloc(u8, text.len);
    for (text, 0..) |c, i| out[i] = std.ascii.toLower(c);
    return out;
}

// ----------------------------------------------------------------------
// 索引集合
// ----------------------------------------------------------------------

pub const IndexSlot = struct {
    field: []const u8,
    kind: FieldKind,
    index: TypedIndex,
    query_count: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    hit_count: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    id_count: usize = 0,

    pub fn init(gpa: std.mem.Allocator, field: []const u8, kind: FieldKind) IndexSlot {
        return .{ .field = field, .kind = kind, .index = TypedIndex.init(gpa, kind) };
    }

    pub fn deinit(self: *IndexSlot, gpa: std.mem.Allocator) void {
        self.index.deinit(gpa);
    }

    pub fn add(self: *IndexSlot, gpa: std.mem.Allocator, key: Key, id: i64) !void {
        if (try self.index.add(gpa, key, id)) self.id_count += 1;
    }

    pub fn remove(self: *IndexSlot, gpa: std.mem.Allocator, key: Key, id: i64) !void {
        if (try self.index.remove(gpa, key, id)) self.id_count = self.id_count -| 1;
    }

    pub fn find(self: *IndexSlot, gpa: std.mem.Allocator, key: Key, out: *std.ArrayList(i64)) !void {
        _ = self.query_count.fetchAdd(1, .monotonic);
        const before = out.items.len;
        try self.index.find(gpa, key, out);
        if (out.items.len > before) _ = self.hit_count.fetchAdd(1, .monotonic);
    }

    pub fn range(self: *IndexSlot, gpa: std.mem.Allocator, min: Key, max: Key, out: *std.ArrayList(i64)) !void {
        _ = self.query_count.fetchAdd(1, .monotonic);
        const before = out.items.len;
        try self.index.range(gpa, min, max, out);
        if (out.items.len > before) _ = self.hit_count.fetchAdd(1, .monotonic);
    }

    pub fn pattern(self: *IndexSlot, gpa: std.mem.Allocator, pattern_text: []const u8, out: *std.ArrayList(i64)) !void {
        _ = self.query_count.fetchAdd(1, .monotonic);
        const before = out.items.len;
        try self.index.pattern(gpa, pattern_text, out);
        if (out.items.len > before) _ = self.hit_count.fetchAdd(1, .monotonic);
    }

    pub fn statistics(self: *IndexSlot) model.IndexStatistics {
        return .{
            .property_name = self.field,
            .index_type = self.kind.indexTypeName(),
            .query_count = self.query_count.load(.monotonic),
            .hit_count = self.hit_count.load(.monotonic),
            .unique_value_count = self.index.uniqueValueCount(),
            .id_count = self.id_count,
        };
    }
};

/// 单表的全部索引槽（`Id` / `Name` 由框架自动建索引）。
pub const IndexSet = struct {
    slots: std.StringHashMap(IndexSlot),

    pub fn init(gpa: std.mem.Allocator) IndexSet {
        return .{ .slots = std.StringHashMap(IndexSlot).init(gpa) };
    }

    /// 按实体字段声明一次性建好索引槽（热路径不再做 `entry` 查找/插入）。
    pub fn initWithFields(gpa: std.mem.Allocator, fields: []const Field) !IndexSet {
        var set = IndexSet.init(gpa);
        errdefer set.deinit(gpa);
        try set.ensure(gpa, "Id", .int);
        try set.ensure(gpa, "Name", .text);
        for (fields) |field| {
            if (!field.indexed) continue;
            if (isIdOrName(field.name)) continue;
            try set.ensure(gpa, field.name, field.kind);
        }
        return set;
    }

    pub fn deinit(self: *IndexSet, gpa: std.mem.Allocator) void {
        var iterator = self.slots.iterator();
        while (iterator.next()) |entry| entry.value_ptr.deinit(gpa);
        self.slots.deinit();
    }

    pub fn ensure(self: *IndexSet, gpa: std.mem.Allocator, field: []const u8, kind: FieldKind) !void {
        if (self.slots.contains(field)) return;
        try self.slots.put(field, IndexSlot.init(gpa, field, kind));
    }

    /// 建索引（字段不存在时动态补槽，对应 `insertByIndex` 的兜底）。
    pub fn add(self: *IndexSet, gpa: std.mem.Allocator, field: []const u8, kind: FieldKind, key: Key, id: i64) !void {
        const slot = self.slots.getPtr(field) orelse blk: {
            try self.ensure(gpa, field, kind);
            break :blk self.slots.getPtr(field).?;
        };
        try slot.add(gpa, key, id);
    }

    pub fn remove(self: *IndexSet, gpa: std.mem.Allocator, field: []const u8, key: Key, id: i64) !void {
        if (self.slots.getPtr(field)) |slot| try slot.remove(gpa, key, id);
    }

    pub fn find(self: *IndexSet, gpa: std.mem.Allocator, field: []const u8, key: Key, out: *std.ArrayList(i64)) !void {
        if (self.slots.getPtr(field)) |slot| try slot.find(gpa, key, out);
    }

    pub fn range(self: *IndexSet, gpa: std.mem.Allocator, field: []const u8, min: Key, max: Key, out: *std.ArrayList(i64)) !void {
        if (self.slots.getPtr(field)) |slot| try slot.range(gpa, min, max, out);
    }

    pub fn pattern(self: *IndexSet, gpa: std.mem.Allocator, field: []const u8, pattern_text: []const u8, out: *std.ArrayList(i64)) !void {
        if (self.slots.getPtr(field)) |slot| try slot.pattern(gpa, pattern_text, out);
    }

    /// 该字段是时间类型时返回 true（`find_by_like` 的日期模式走区间查询）。
    pub fn kindOf(self: *IndexSet, field: []const u8) ?FieldKind {
        const slot = self.slots.getPtr(field) orelse return null;
        return slot.kind;
    }

    pub fn idCount(self: *IndexSet, field: []const u8) usize {
        const slot = self.slots.getPtr(field) orelse return 0;
        return slot.id_count;
    }

    pub fn takeOrdered(
        self: *IndexSet,
        gpa: std.mem.Allocator,
        field: []const u8,
        ascending: bool,
        limit: usize,
        out: *std.ArrayList(i64),
    ) !bool {
        const slot = self.slots.getPtr(field) orelse return false;
        return slot.index.takeOrdered(gpa, ascending, limit, out);
    }

    pub fn statistics(self: *IndexSet, gpa: std.mem.Allocator) ![]model.IndexStatistics {
        const stats = try gpa.alloc(model.IndexStatistics, self.slots.count());
        errdefer gpa.free(stats);
        var index: usize = 0;
        var iterator = self.slots.iterator();
        while (iterator.next()) |entry| : (index += 1) {
            stats[index] = entry.value_ptr.statistics();
        }
        std.mem.sortUnstable(model.IndexStatistics, stats, {}, struct {
            fn lessThan(_: void, a: model.IndexStatistics, b: model.IndexStatistics) bool {
                return std.mem.lessThan(u8, a.property_name, b.property_name);
            }
        }.lessThan);
        return stats;
    }
};

/// 是否为框架维护的 `Id` / `Name` 字段（大小写不敏感）。
pub fn isIdOrName(name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(name, "Id") or std.ascii.eqlIgnoreCase(name, "Name");
}

// ----------------------------------------------------------------------
// 测试
// ----------------------------------------------------------------------

const testing = std.testing;

test "通配匹配（`*` / `?`）" {
    try testing.expect(wildcardMatch("zhang*", "zhangsan"));
    try testing.expect(wildcardMatch("*hang*", "zhangsan"));
    try testing.expect(wildcardMatch("z*n", "zhangsan"));
    try testing.expect(wildcardMatch("*", "abc"));
    try testing.expect(wildcardMatch("a?c", "abc"));
    try testing.expect(!wildcardMatch("ab", "abc"));
    try testing.expect(!wildcardMatch("b*", "abc"));
}

test "索引集合：数值范围与分页顺序" {
    const gpa = testing.allocator;
    var set = IndexSet.init(gpa);
    defer set.deinit(gpa);

    try set.add(gpa, "Age", .int, .{ .int = 10 }, 1);
    try set.add(gpa, "Age", .int, .{ .int = 20 }, 2);
    try set.add(gpa, "Age", .int, .{ .int = 30 }, 3);

    var ids: std.ArrayList(i64) = .empty;
    defer ids.deinit(gpa);

    try set.range(gpa, "Age", .{ .int = 15 }, .{ .int = 30 }, &ids);
    try testing.expectEqualSlices(i64, &.{ 2, 3 }, ids.items);

    ids.clearRetainingCapacity();
    try testing.expect(try set.takeOrdered(gpa, "Age", false, 2, &ids));
    try testing.expectEqualSlices(i64, &.{ 3, 2 }, ids.items);

    try testing.expectEqual(@as(usize, 3), set.idCount("Age"));
    try set.remove(gpa, "Age", .{ .int = 20 }, 2);
    try testing.expectEqual(@as(usize, 2), set.idCount("Age"));

    ids.clearRetainingCapacity();
    try set.range(gpa, "Age", .{ .int = 15 }, .{ .int = 30 }, &ids);
    try testing.expectEqualSlices(i64, &.{3}, ids.items);
}

test "文本索引：精确区分大小写、模式不区分" {
    const gpa = testing.allocator;
    var set = IndexSet.init(gpa);
    defer set.deinit(gpa);

    try set.add(gpa, "Status", .text, .{ .text = try gpa.dupe(u8, "Active") }, 1);
    try set.add(gpa, "Status", .text, .{ .text = try gpa.dupe(u8, "Active") }, 2);
    try set.add(gpa, "Status", .text, .{ .text = try gpa.dupe(u8, "Disabled") }, 3);

    var ids: std.ArrayList(i64) = .empty;
    defer ids.deinit(gpa);

    try set.find(gpa, "Status", .{ .text = @constCast("Active") }, &ids);
    try testing.expectEqualSlices(i64, &.{ 1, 2 }, ids.items);

    ids.clearRetainingCapacity();
    try set.find(gpa, "Status", .{ .text = @constCast("active") }, &ids);
    try testing.expectEqual(@as(usize, 0), ids.items.len);

    ids.clearRetainingCapacity();
    try set.pattern(gpa, "Status", "act*", &ids);
    try testing.expectEqualSlices(i64, &.{ 1, 2 }, ids.items);

    ids.clearRetainingCapacity();
    try set.pattern(gpa, "Status", "*tive", &ids);
    try testing.expectEqualSlices(i64, &.{ 1, 2 }, ids.items);

    ids.clearRetainingCapacity();
    try set.pattern(gpa, "Status", "A*e", &ids);
    try testing.expectEqualSlices(i64, &.{ 1, 2 }, ids.items);

    // 前缀有序范围
    ids.clearRetainingCapacity();
    try set.range(gpa, "Status", .{ .text = @constCast("A") }, .{ .text = @constCast("B") }, &ids);
    try testing.expectEqualSlices(i64, &.{ 1, 2 }, ids.items);
}

test "布尔双桶与智能值" {
    const gpa = testing.allocator;
    var set = IndexSet.init(gpa);
    defer set.deinit(gpa);

    try set.add(gpa, "Enabled", .boolean, .{ .boolean = true }, 1);
    try set.add(gpa, "Enabled", .boolean, .{ .boolean = true }, 2);
    try set.add(gpa, "Enabled", .boolean, .{ .boolean = false }, 3);

    var ids: std.ArrayList(i64) = .empty;
    defer ids.deinit(gpa);

    try set.find(gpa, "Enabled", .{ .boolean = true }, &ids);
    try testing.expectEqualSlices(i64, &.{ 1, 2 }, ids.items);

    ids.clearRetainingCapacity();
    try set.pattern(gpa, "Enabled", "否", &ids);
    try testing.expectEqualSlices(i64, &.{3}, ids.items);

    ids.clearRetainingCapacity();
    try set.pattern(gpa, "Enabled", "maybe", &ids);
    try testing.expectEqual(@as(usize, 0), ids.items.len);
}
