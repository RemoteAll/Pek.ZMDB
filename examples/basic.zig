//! Pek.ZMDB 示例：C# 兼容持久化 + 常用查询 + 唯一约束。
//!
//! 运行：`zig build example`（在项目根目录产出 `AppData/Data/Demo.User.json`）。

const std = @import("std");
const zmdb = @import("pek_zmdb");

const User = struct {
    gpa: std.mem.Allocator,
    id: i64 = 0,
    name: []const u8 = "",
    username: []const u8 = "",
    email: []const u8 = "",
    age: i64 = 0,
    create_time: ?zmdb.DateTime = null,

    pub const type_name = "Demo.User";

    pub const fields = [_]zmdb.Field{
        zmdb.Field.text("Username").withUnique("用户名已存在"),
        zmdb.Field.text("Email").withUniqueRequired("邮箱已被注册"),
        zmdb.Field.int("Age"),
        zmdb.Field.time("CreateTime"),
    };

    pub fn initEmpty(gpa: std.mem.Allocator) User {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *User) void {
        const gpa = self.gpa;
        gpa.free(self.name);
        gpa.free(self.username);
        gpa.free(self.email);
        self.* = .{ .gpa = gpa };
    }

    pub fn getId(self: *const User) i64 {
        return self.id;
    }

    pub fn setId(self: *User, id: i64) void {
        self.id = id;
    }

    pub fn getName(self: *const User) []const u8 {
        return self.name;
    }

    pub fn setName(self: *User, name: []const u8) !void {
        const copy = try self.gpa.dupe(u8, name);
        self.gpa.free(self.name);
        self.name = copy;
    }

    pub fn getField(self: *const User, name: []const u8) ?zmdb.Value {
        if (std.mem.eql(u8, name, "Username")) return .{ .text = self.username };
        if (std.mem.eql(u8, name, "Email")) {
            return if (self.email.len == 0) .{ .null = {} } else .{ .text = self.email };
        }
        if (std.mem.eql(u8, name, "Age")) return .{ .int = self.age };
        if (std.mem.eql(u8, name, "CreateTime")) {
            return if (self.create_time) |dt| .{ .datetime = dt } else .{ .null = {} };
        }
        return null;
    }

    pub fn setField(self: *User, name: []const u8, value: zmdb.Value) !bool {
        if (std.mem.eql(u8, name, "Username")) {
            try setText(self.gpa, &self.username, value);
            return true;
        }
        if (std.mem.eql(u8, name, "Email")) {
            try setText(self.gpa, &self.email, value);
            return true;
        }
        if (std.mem.eql(u8, name, "Age")) {
            self.age = zmdb.value.toI64(value) orelse 0;
            return true;
        }
        if (std.mem.eql(u8, name, "CreateTime")) {
            self.create_time = zmdb.value.toDateTime(value);
            return true;
        }
        return false;
    }

    fn setText(gpa: std.mem.Allocator, target: *[]const u8, value: zmdb.Value) !void {
        const text = (try zmdb.value.toTextAlloc(value, gpa)) orelse "";
        gpa.free(target.*);
        target.* = text;
    }
};

pub fn main() !void {
    var threaded: std.Io.Threaded = .init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var db = try zmdb.MemoryDb.init(gpa, io, .{ .base_dir = "AppData" });
    defer db.deinit();

    // 示例可重复运行：先清空上一次的示例数据（真实业务不要这样整表清空）
    try db.clear(User);

    const now = zmdb.DateTime.nowLocal();
    const user1 = User{
        .gpa = gpa,
        .name = try gpa.dupe(u8, "张三"),
        .username = try gpa.dupe(u8, "zhangsan"),
        .email = try gpa.dupe(u8, "zhangsan@example.com"),
        .age = 30,
        .create_time = now,
    };
    const id = try db.insert(User, user1, null);
    std.debug.print("插入成功，ID = {d}\n", .{id});

    // 唯一约束：用户名重复会失败，且细节通过 Violation 出参拿到
    var violation: zmdb.Violation = .{};
    const duplicate = User{
        .gpa = gpa,
        .name = try gpa.dupe(u8, "李四"),
        .username = try gpa.dupe(u8, "zhangsan"),
        .email = try gpa.dupe(u8, "lisi@example.com"),
        .age = 28,
    };
    if (db.insert(User, duplicate, &violation)) |_| {
        std.debug.print("不应插入成功\n", .{});
    } else |err| {
        std.debug.print("预期的失败：{s}（字段 {s}，原因 {s}）\n", .{
            @errorName(err),
            violation.property_name,
            violation.message,
        });
    }

    // 查询
    const found = (try db.findByUnique(User, "Username", .{ .text = "zhangsan" })).?;
    defer found.release();
    std.debug.print("按唯一键找到：{s}（{s}）\n", .{ found.get().name, found.get().username });

    var adults = try db.findByRange(User, "Age", .{ .int = 18 }, .{ .int = 60 });
    defer adults.deinit();
    std.debug.print("18~60 岁共 {d} 人\n", .{adults.len()});

    var page = try db.findByPage(User, "Age", 0, 10, true);
    defer page.deinit();
    std.debug.print("分页：共 {d} 页 / {d} 行\n", .{ page.total_pages, page.total_count });

    // 同步落盘（后台线程也会在 500ms 内合并写盘）
    try db.flush();
    const path = (try db.dataFile(User)).?;
    defer gpa.free(path);
    std.debug.print("数据文件：{s}\n", .{path});
}
