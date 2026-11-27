//! 有序索引容器：按 [`Key`] 排序的映射 + 每个键的升序 ID 集合。
//!
//! # 为什么自己写有序映射
//! Zig 0.17 标准库没有 `BTreeMap`（也没有 `Treap`），而范围查询/分页必须按值有序：
//! - 键用**随机化 Treap**（插入/删除/下界 `O(log n)` 期望，带父指针支持中序迭代）；
//! - 每个键的 ID 用**升序数组**：本库 ID 单调递增，首次插入天然是尾部追加 `O(1)`，
//!   删除/更新走二分 + 搬移；迭代天然按 ID 升序，结果稳定便于对拍。

const std = @import("std");
const value = @import("value.zig");

pub const Key = value.Key;

/// 每个索引值对应的 ID 集合（升序、去重）。
///
/// # 为什么用「负数墓碑」而不是立即搬移
/// 单调递增的 ID 天然尾部追加（`O(1)`）；删除若直接 `orderedRemove`，一个含有
/// 10 万 ID 的桶每删一行都要搬移约 400 KB（实测布尔双桶 / 低频文本值删除是删除操作
/// 的主要开销）。这里改为**把 ID 取负作为墓碑**：不额外占内存、不破坏排序
/// （比较按绝对值），删除只做二分 + 取负；墓碑超过半数时原地压缩（`O(n)`，摊还 `O(1)`）。
pub const IdSet = struct {
    /// 升序 ID（负数表示已删除的墓碑；ID 本身恒为正）。
    ids: std.ArrayList(i64) = .empty,
    /// 存活数量（`O(1)` 读取；`ids.len - live` = 墓碑数）。
    live: usize = 0,

    pub fn deinit(self: *IdSet, gpa: std.mem.Allocator) void {
        self.ids.deinit(gpa);
        self.live = 0;
    }

    /// 存活数量。
    pub fn count(self: IdSet) usize {
        return self.live;
    }

    /// 插入（返回是否新增；已存在返回 `false`；已删除的 ID 重新插入视为新增）。
    pub fn insert(self: *IdSet, gpa: std.mem.Allocator, id: i64) !bool {
        const items = self.ids.items;
        // 常见路径：ID 单调递增 → 尾部追加（无二分、无搬移）
        if (items.len == 0 or magnitude(items[items.len - 1]) < id) {
            try self.ids.append(gpa, id);
            self.live += 1;
            return true;
        }
        const index = std.sort.lowerBound(i64, items, id, compareId);
        if (index < items.len and magnitude(items[index]) == id) {
            if (items[index] > 0) return false;
            items[index] = id; // 复活墓碑
            self.live += 1;
            return true;
        }
        try self.ids.insert(gpa, index, id);
        self.live += 1;
        return true;
    }

    /// 删除（返回是否存在并已删除）。
    pub fn remove(self: *IdSet, id: i64) bool {
        const items = self.ids.items;
        const index = std.sort.lowerBound(i64, items, id, compareId);
        if (index >= items.len or magnitude(items[index]) != id) return false;
        if (items[index] < 0) return false;
        items[index] = -id;
        self.live -= 1;
        self.compact();
        return true;
    }

    pub fn contains(self: IdSet, id: i64) bool {
        const items = self.ids.items;
        const index = std.sort.lowerBound(i64, items, id, compareId);
        return index < items.len and items[index] == id;
    }

    /// 追加全部存活 ID（升序）。
    pub fn appendTo(self: IdSet, gpa: std.mem.Allocator, out: *std.ArrayList(i64)) !void {
        try out.ensureUnusedCapacity(gpa, self.ids.items.len);
        for (self.ids.items) |id| {
            if (id < 0) continue;
            out.appendAssumeCapacity(id);
        }
    }

    /// 追加存活 ID，满了 `limit` 即停（升序）。
    pub fn appendToLimit(self: IdSet, gpa: std.mem.Allocator, out: *std.ArrayList(i64), limit: usize) !void {
        for (self.ids.items) |id| {
            if (id < 0) continue;
            try out.append(gpa, id);
            if (out.items.len >= limit) return;
        }
    }

    /// 墓碑过多时原地压缩（**只能在持有写锁时调用**）。
    ///
    /// 触发条件：墓碑 ≥ 64 且墓碑数不少于存活数（摊还 `O(1)`）。
    pub fn compact(self: *IdSet) void {
        if (self.ids.items.len < 64) return;
        const dead = self.ids.items.len - self.live;
        if (dead < 64 or dead < self.live) return;
        var write: usize = 0;
        for (self.ids.items) |id| {
            if (id < 0) continue;
            self.ids.items[write] = id;
            write += 1;
        }
        self.ids.shrinkRetainingCapacity(write);
        self.live = write;
    }

    fn magnitude(id: i64) i64 {
        return if (id < 0) -id else id;
    }

    fn compareId(target: i64, item: i64) std.math.Order {
        return std.math.order(target, magnitude(item));
    }
};

/// 有序映射：`Key → IdSet`。
pub const KeyMap = struct {
    pub const Node = struct {
        key: Key,
        ids: IdSet = .{},
        priority: u32,
        left: ?*Node = null,
        right: ?*Node = null,
        parent: ?*Node = null,
    };

    gpa: std.mem.Allocator,
    root: ?*Node = null,
    count: usize = 0,
    seed: u64 = 0x2545_F491_4F6C_DD1D,

    pub fn init(gpa: std.mem.Allocator) KeyMap {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *KeyMap) void {
        var stack: std.ArrayList(*Node) = .empty;
        defer stack.deinit(self.gpa);
        if (self.root) |root| stack.append(self.gpa, root) catch {};
        while (stack.pop()) |node| {
            if (node.left) |l| stack.append(self.gpa, l) catch {};
            if (node.right) |r| stack.append(self.gpa, r) catch {};
            node.key.deinit(self.gpa);
            node.ids.deinit(self.gpa);
            self.gpa.destroy(node);
        }
        self.* = .{ .gpa = self.gpa };
    }

    pub fn countOf(self: KeyMap) usize {
        return self.count;
    }

    /// 查找键节点（不转移所有权）。
    pub fn findNode(self: *KeyMap, key: Key) ?*Node {
        var current = self.root;
        while (current) |node| {
            current = switch (Key.order(key, node.key)) {
                .lt => node.left,
                .gt => node.right,
                .eq => return node,
            };
        }
        return null;
    }

    /// 取或建键节点（键不存在时**接管 `key` 的所有权**）。
    pub fn getOrPut(self: *KeyMap, key: Key) !struct { node: *Node, created: bool } {
        if (self.root == null) {
            const node = try self.newNode(key);
            self.root = node;
            self.count = 1;
            return .{ .node = node, .created = true };
        }

        var current = self.root.?;
        while (true) {
            switch (Key.order(key, current.key)) {
                .eq => return .{ .node = current, .created = false },
                .lt => {
                    if (current.left) |child| {
                        current = child;
                    } else {
                        const node = try self.newNode(key);
                        current.left = node;
                        node.parent = current;
                        self.count += 1;
                        self.rotateUp(node);
                        return .{ .node = node, .created = true };
                    }
                },
                .gt => {
                    if (current.right) |child| {
                        current = child;
                    } else {
                        const node = try self.newNode(key);
                        current.right = node;
                        node.parent = current;
                        self.count += 1;
                        self.rotateUp(node);
                        return .{ .node = node, .created = true };
                    }
                },
            }
        }
    }

    /// 删除键（连同其 ID 集合；键不存在返回 `false`）。
    pub fn remove(self: *KeyMap, key: Key) bool {
        const node = self.findNode(key) orelse return false;
        self.removeNode(node);
        return true;
    }

    fn removeNode(self: *KeyMap, node: *Node) void {
        // 旋转下沉到叶子再摘除（保持 Treap 堆序）
        while (node.left != null or node.right != null) {
            if (node.left) |l| {
                if (node.right) |r| {
                    if (l.priority >= r.priority) {
                        self.rotateRight(node);
                    } else {
                        self.rotateLeft(node);
                    }
                } else {
                    self.rotateRight(node);
                }
            } else {
                self.rotateLeft(node);
            }
        }
        if (node.parent) |parent| {
            if (parent.left == node) parent.left = null else parent.right = null;
        } else {
            self.root = null;
        }
        node.key.deinit(self.gpa);
        node.ids.deinit(self.gpa);
        self.gpa.destroy(node);
        self.count -= 1;
    }

    /// 第一个 `key >= target` 的节点。
    pub fn lowerBound(self: *KeyMap, target: Key) ?*Node {
        var best: ?*Node = null;
        var current = self.root;
        while (current) |node| {
            if (Key.order(node.key, target) != .lt) {
                best = node;
                current = node.left;
            } else {
                current = node.right;
            }
        }
        return best;
    }

    pub fn first(self: *KeyMap) ?*Node {
        var node = self.root orelse return null;
        while (node.left) |l| node = l;
        return node;
    }

    pub fn last(self: *KeyMap) ?*Node {
        var node = self.root orelse return null;
        while (node.right) |r| node = r;
        return node;
    }

    /// 中序后继。
    pub fn next(self: *KeyMap, node: *Node) ?*Node {
        _ = self;
        if (node.right) |r| {
            var n = r;
            while (n.left) |l| n = l;
            return n;
        }
        var current: *Node = node;
        var parent = node.parent;
        while (parent) |p| {
            if (p.left == current) return p;
            current = p;
            parent = p.parent;
        }
        return null;
    }

    /// 中序前驱。
    pub fn prev(self: *KeyMap, node: *Node) ?*Node {
        _ = self;
        if (node.left) |l| {
            var n = l;
            while (n.right) |r| n = r;
            return n;
        }
        var current: *Node = node;
        var parent = node.parent;
        while (parent) |p| {
            if (p.right == current) return p;
            current = p;
            parent = p.parent;
        }
        return null;
    }

    fn newNode(self: *KeyMap, key: Key) !*Node {
        const node = try self.gpa.create(Node);
        node.* = .{ .key = key, .priority = self.nextPriority() };
        return node;
    }

    fn nextPriority(self: *KeyMap) u32 {
        var x = self.seed;
        x ^= x << 13;
        x ^= x >> 7;
        x ^= x << 17;
        self.seed = x;
        return @truncate(x >> 16);
    }

    fn rotateUp(self: *KeyMap, node: *Node) void {
        while (node.parent) |parent| {
            if (parent.priority >= node.priority) return;
            if (parent.left == node) {
                self.rotateRight(parent);
            } else {
                self.rotateLeft(parent);
            }
        }
    }

    /// 右旋：`p` 的左子 `x` 上提。
    fn rotateRight(self: *KeyMap, p: *Node) void {
        const x = p.left orelse return;
        p.left = x.right;
        if (x.right) |r| r.parent = p;
        x.parent = p.parent;
        if (p.parent) |pp| {
            if (pp.left == p) pp.left = x else pp.right = x;
        } else {
            self.root = x;
        }
        x.right = p;
        p.parent = x;
    }

    /// 左旋：`p` 的右子 `x` 上提。
    fn rotateLeft(self: *KeyMap, p: *Node) void {
        const x = p.right orelse return;
        p.right = x.left;
        if (x.left) |l| l.parent = p;
        x.parent = p.parent;
        if (p.parent) |pp| {
            if (pp.left == p) pp.left = x else pp.right = x;
        } else {
            self.root = x;
        }
        x.left = p;
        p.parent = x;
    }
};

// ----------------------------------------------------------------------
// 测试
// ----------------------------------------------------------------------

const testing = std.testing;

test "有序映射：插入/查找/范围/删除" {
    const gpa = testing.allocator;
    var map = KeyMap.init(gpa);
    defer map.deinit();

    var i: i64 = 1;
    while (i <= 100) : (i += 1) {
        const entry = try map.getOrPut(.{ .int = i * 10 });
        try testing.expect(entry.created);
        _ = try entry.node.ids.insert(gpa, i);
    }
    try testing.expectEqual(@as(usize, 100), map.countOf());

    // 重复插入不新建节点
    const again = try map.getOrPut(.{ .int = 500 });
    try testing.expect(!again.created);

    // 下界 + 区间迭代（260..500 → 26..50 共 25 个 ID）
    var ids: std.ArrayList(i64) = .empty;
    defer ids.deinit(gpa);
    var node = map.lowerBound(.{ .int = 260 });
    while (node) |n| {
        if (Key.order(n.key, .{ .int = 500 }) == .gt) break;
        try n.ids.appendTo(gpa, &ids);
        node = map.next(n);
    }
    try testing.expectEqual(@as(usize, 25), ids.items.len);
    try testing.expectEqual(@as(i64, 26), ids.items[0]);
    try testing.expectEqual(@as(i64, 50), ids.items[24]);

    // 删除中间键后顺序仍然正确
    try testing.expect(map.remove(.{ .int = 270 }));
    try testing.expect(!map.remove(.{ .int = 270 }));
    try testing.expectEqual(@as(usize, 99), map.countOf());

    ids.clearRetainingCapacity();
    node = map.lowerBound(.{ .int = 260 });
    while (node) |n| {
        if (Key.order(n.key, .{ .int = 290 }) == .gt) break;
        try n.ids.appendTo(gpa, &ids);
        node = map.next(n);
    }
    try testing.expectEqualSlices(i64, &.{ 26, 28, 29 }, ids.items);

    // 反向迭代
    var desc: std.ArrayList(i64) = .empty;
    defer desc.deinit(gpa);
    var back = map.last();
    while (back) |n| {
        if (n.ids.count() > 0) try desc.append(gpa, n.key.int);
        back = map.prev(n);
    }
    try testing.expectEqual(@as(i64, 1000), desc.items[0]);
    try testing.expectEqual(@as(i64, 10), desc.items[desc.items.len - 1]);
}

test "ID 集合：负数墓碑与摊还压缩" {
    const gpa = testing.allocator;
    var set: IdSet = .{};
    defer set.deinit(gpa);

    var id: i64 = 1;
    while (id <= 200) : (id += 1) _ = try set.insert(gpa, id);
    try testing.expectEqual(@as(usize, 200), set.count());

    // 删掉 101..200：墓碑（负数）不少于存活，压缩到 100 个
    id = 101;
    while (id <= 200) : (id += 1) try testing.expect(set.remove(id));
    try testing.expectEqual(@as(usize, 100), set.count());
    try testing.expectEqual(@as(usize, 100), set.ids.items.len);
    try testing.expect(!set.remove(150));

    // 再删 1..51：墓碑达到 51，未达压缩阈值（≥64），保留负数墓碑
    id = 1;
    while (id <= 51) : (id += 1) try testing.expect(set.remove(id));
    try testing.expectEqual(@as(usize, 49), set.count());
    try testing.expect(set.ids.items.len > 49);
    try testing.expect(!set.contains(150));
    try testing.expect(!set.contains(10));

    // 墓碑未达压缩阈值（<64）时不搬移，读取时按负数跳过
    set.compact();
    try testing.expectEqual(@as(usize, 100), set.ids.items.len);
    try testing.expectEqual(@as(usize, 49), set.count());
    id = 201;
    while (id <= 210) : (id += 1) _ = try set.insert(gpa, id);
    try testing.expectEqual(@as(usize, 59), set.count());
    try testing.expect(set.contains(52));
    try testing.expect(set.contains(210));

    var out: std.ArrayList(i64) = .empty;
    defer out.deinit(gpa);
    try set.appendTo(gpa, &out);
    try testing.expectEqual(@as(usize, 59), out.items.len);
    for (out.items[1..], out.items[0 .. out.items.len - 1]) |current, previous| {
        try testing.expect(current > previous);
    }
}

test "ID 集合：去重与升序" {
    const gpa = testing.allocator;
    var set: IdSet = .{};
    defer set.deinit(gpa);

    _ = try set.insert(gpa, 5);
    _ = try set.insert(gpa, 1);
    _ = try set.insert(gpa, 3);
    try testing.expect(!(try set.insert(gpa, 3)));
    try testing.expectEqualSlices(i64, &.{ 1, 3, 5 }, set.ids.items);

    try testing.expect(set.remove(3));
    try testing.expect(!set.remove(3));
    try testing.expect(set.contains(5));
    try testing.expectEqual(@as(usize, 2), set.count());
}
