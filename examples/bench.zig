//! Pek.ZMDB 性能基准（ReleaseFast 下运行才有意义）。
//!
//! 运行：`zig build bench -Doptimize=ReleaseFast`
//!
//! 覆盖：批量插入 / 精确 / 模式 / 范围 / 多条件 / 主键 / 分页 / 更新 / 删除 / 落盘 / 加载。
//! 输出为「总耗时（ms）」与「单次耗时（µs，按次数折算）」，便于改动前后对比。

const std = @import("std");
const zmdb = @import("pek_zmdb");

const Row = struct {
    gpa: std.mem.Allocator,
    id: i64 = 0,
    name: []const u8 = "",
    code: []const u8 = "",
    category: []const u8 = "",
    score: i64 = 0,
    active: bool = false,
    memo: []const u8 = "",

    pub const type_name = "Bench.Row";

    pub const fields = [_]zmdb.Field{
        zmdb.Field.text("Code").withUnique("编号已存在"),
        zmdb.Field.text("Category"),
        zmdb.Field.int("Score"),
        zmdb.Field.boolean("Active"),
        zmdb.Field.text("Memo").notIndexed(),
    };

    pub fn initEmpty(gpa: std.mem.Allocator) Row {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Row) void {
        const gpa = self.gpa;
        gpa.free(self.name);
        gpa.free(self.code);
        gpa.free(self.category);
        gpa.free(self.memo);
        self.* = .{ .gpa = gpa };
    }

    pub fn getId(self: *const Row) i64 {
        return self.id;
    }

    pub fn clone(self: *const Row, gpa: std.mem.Allocator) !Row {
        return .{
            .gpa = gpa,
            .id = self.id,
            .name = try gpa.dupe(u8, self.name),
            .code = try gpa.dupe(u8, self.code),
            .category = try gpa.dupe(u8, self.category),
            .score = self.score,
            .active = self.active,
            .memo = try gpa.dupe(u8, self.memo),
        };
    }

    pub fn setId(self: *Row, id: i64) void {
        self.id = id;
    }

    pub fn getName(self: *const Row) []const u8 {
        return self.name;
    }

    pub fn setName(self: *Row, name: []const u8) !void {
        const copy = try self.gpa.dupe(u8, name);
        self.gpa.free(self.name);
        self.name = copy;
    }

    pub fn getField(self: *const Row, name: []const u8) ?zmdb.Value {
        if (std.mem.eql(u8, name, "Code")) return .{ .text = self.code };
        if (std.mem.eql(u8, name, "Category")) return .{ .text = self.category };
        if (std.mem.eql(u8, name, "Score")) return .{ .int = self.score };
        if (std.mem.eql(u8, name, "Active")) return .{ .boolean = self.active };
        if (std.mem.eql(u8, name, "Memo")) return .{ .text = self.memo };
        return null;
    }

    pub fn setField(self: *Row, name: []const u8, value: zmdb.Value) !bool {
        if (std.mem.eql(u8, name, "Code")) {
            try replaceText(self.gpa, &self.code, value);
            return true;
        }
        if (std.mem.eql(u8, name, "Category")) {
            try replaceText(self.gpa, &self.category, value);
            return true;
        }
        if (std.mem.eql(u8, name, "Score")) {
            self.score = zmdb.value.toI64(value) orelse 0;
            return true;
        }
        if (std.mem.eql(u8, name, "Active")) {
            self.active = zmdb.value.toBool(value) orelse false;
            return true;
        }
        if (std.mem.eql(u8, name, "Memo")) {
            try replaceText(self.gpa, &self.memo, value);
            return true;
        }
        return false;
    }

    fn replaceText(gpa: std.mem.Allocator, target: *[]const u8, value: zmdb.Value) !void {
        const text = switch (value) {
            .null => "",
            .text => |t| t,
            .blob => |b| b,
            else => (try zmdb.value.toTextAlloc(value, gpa)) orelse "",
        };
        const copy = try gpa.dupe(u8, text);
        gpa.free(target.*);
        target.* = copy;
    }
};

fn makeRow(gpa: std.mem.Allocator, index: usize) !Row {
    var row = Row.initEmpty(gpa);
    errdefer row.deinit();
    row.name = try std.fmt.allocPrint(gpa, "行{d}", .{index});
    row.code = try std.fmt.allocPrint(gpa, "code-{d:0>7}", .{index});
    row.category = try std.fmt.allocPrint(gpa, "cat-{d}", .{index % 8});
    row.score = @intCast(index % 10_000);
    row.active = (index % 3) == 0;
    row.memo = try std.fmt.allocPrint(gpa, "备注-{d}-abcdefghijklmnopqrstuvwxyz", .{index});
    return row;
}

const Report = struct {
    io: std.Io,

    fn start(self: Report) std.Io.Timestamp {
        return std.Io.Timestamp.now(self.io, .awake);
    }

    fn done(self: Report, label: []const u8, began: std.Io.Timestamp, times: usize) void {
        const elapsed = std.Io.Timestamp.durationTo(began, std.Io.Timestamp.now(self.io, .awake)).toMilliseconds();
        const elapsed_us = @as(u64, @intCast(@max(elapsed, 0))) * 1000;
        const per_us = if (times == 0) elapsed_us else elapsed_us / @as(u64, @intCast(times));
        std.debug.print("{s:<34} {d:>8} ms   ({d} 次, {d} µs/次)\n", .{ label, elapsed, times, per_us });
    }
};

pub fn main() !void {
    var threaded: std.Io.Threaded = .init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = std.heap.smp_allocator;

    const rows: usize = @import("build_options").bench_rows;
    const report = Report{ .io = io };
    std.debug.print("== Pek.ZMDB 基准：{d} 行 ==\n", .{rows});

    // 临时目录（跑完删除）
    const base_dir = "artifacts/bench-data";
    std.Io.Dir.cwd().deleteTree(io, base_dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, base_dir) catch {};

    var db = try zmdb.MemoryDb.init(gpa, io, .{ .base_dir = base_dir, .auto_persist = false, .flush_on_drop = false });
    defer db.deinit();

    // 1. 批量插入
    var objects = try gpa.alloc(Row, rows);
    defer gpa.free(objects);
    for (0..rows) |i| objects[i] = try makeRow(gpa, i);
    var timer = report.start();
    const ids = try db.insertBatch(Row, objects, null);
    report.done("insertBatch", timer, rows);
    defer gpa.free(ids);

    // 2. 精确查询（唯一字段）
    timer = report.start();
    var hits: usize = 0;
    for (0..20_000) |i| {
        const index = (i * 7919) % rows;
        var list = try db.findBy(Row, "Code", .{ .text = objects[index].code });
        defer list.deinit();
        hits += list.len();
    }
    report.done("findBy 文本精确(唯一)", timer, 20_000);
    std.debug.print("{s:<34} 命中 {d}\n", .{ "", hits });

    // 3. 模式查询：前缀（走有序范围）
    timer = report.start();
    for (0..20) |_| {
        var list = try db.findByLike(Row, "Category", "cat-*");
        defer list.deinit();
        hits = list.len();
    }
    report.done("findByLike 前缀 cat-*", timer, 20);
    std.debug.print("{s:<34} 末次命中 {d}\n", .{ "", hits });

    // 4. 模式查询：包含（逐键扫描）
    timer = report.start();
    for (0..5) |_| {
        var list = try db.findByLike(Row, "Category", "*at-3*");
        defer list.deinit();
        hits = list.len();
    }
    report.done("findByLike 包含 *at-3*", timer, 5);
    std.debug.print("{s:<34} 末次命中 {d}\n", .{ "", hits });

    // 5. 范围查询
    timer = report.start();
    for (0..20) |_| {
        var list = try db.findByRange(Row, "Score", .{ .int = 1000 }, .{ .int = 2000 });
        defer list.deinit();
        hits = list.len();
    }
    report.done("findByRange 整数区间", timer, 20);
    std.debug.print("{s:<34} 末次命中 {d}\n", .{ "", hits });

    // 6. 多条件交集
    timer = report.start();
    for (0..20) |_| {
        var list = try db.findByMultiple(Row, &.{
            .{ .field = "Category", .value = .{ .text = "cat-3" } },
            .{ .field = "Active", .value = .{ .boolean = true } },
        });
        defer list.deinit();
        hits = list.len();
    }
    report.done("findByMultiple 文本+布尔", timer, 20);
    std.debug.print("{s:<34} 末次命中 {d}\n", .{ "", hits });

    // 7. 主键查询
    timer = report.start();
    for (0..rows) |i| {
        const id = ids[(i * 7919) % ids.len];
        const ref = try db.findById(Row, id);
        if (ref) |handle| handle.release();
    }
    report.done("findById", timer, rows);

    // 8. 分页（无排序字段：按 ID）
    timer = report.start();
    for (0..20) |page| {
        var result = try db.findByPage(Row, null, page * 100, 100, true);
        defer result.deinit();
        hits = result.len();
    }
    report.done("findByPage 按 ID", timer, 20);

    // 9. 分页（按索引字段）
    timer = report.start();
    for (0..20) |page| {
        var result = try db.findByPage(Row, "Score", page * 100, 100, true);
        defer result.deinit();
        hits = result.len();
    }
    report.done("findByPage 按 Score 索引", timer, 20);

    // 10. 更新（只改 1 个字段）
    const update_count = rows / 5;
    timer = report.start();
    for (0..update_count) |i| {
        const id = ids[(i * 7919) % ids.len];
        const ref = (try db.findById(Row, id)).?;
        var updated = try ref.get().clone(gpa);
        ref.release();
        updated.score += 1;
        try db.update(Row, updated, null);
    }
    report.done("update 单字段", timer, update_count);

    // 11. 删除
    const delete_count = rows / 5;
    timer = report.start();
    for (0..delete_count) |i| {
        _ = try db.delete(Row, ids[i]);
    }
    report.done("delete", timer, delete_count);

    // 12. 落盘
    timer = report.start();
    try db.flush();
    report.done("flush（序列化+原子写）", timer, 1);

    // 13. 加载（新实例读同一目录）
    var db2 = try zmdb.MemoryDb.init(gpa, io, .{ .base_dir = base_dir, .auto_persist = false, .flush_on_drop = false });
    defer db2.deinit();
    timer = report.start();
    var all = try db2.findAll(Row);
    defer all.deinit();
    report.done("load + findAll", timer, all.len());
    std.debug.print("{s:<34} 加载 {d} 行\n", .{ "", all.len() });
}
