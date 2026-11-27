//! 测试实体（覆盖文本/整数/时间/JSON 字段、单字段唯一、复合唯一、非持久化字段）。

const std = @import("std");
const zmdb = @import("zmdb.zig");

pub const User = struct {
    gpa: std.mem.Allocator,
    id: i64 = 0,
    name: []const u8 = "",
    username: []const u8 = "",
    email: []const u8 = "",
    /// 空串视为 Null（配合 `allow_null` 语义）。
    phone: []const u8 = "",
    age: i64 = 0,
    status: []const u8 = "",
    enabled: bool = false,
    /// JSON 文本（`[ "a", "b" ]`），不建索引时也能落盘。
    tags: []const u8 = "",
    create_time: ?zmdb.DateTime = null,
    /// 未建索引的大文本字段。
    remark: []const u8 = "",
    /// 运行期缓存字段（不落盘）。
    cache: []const u8 = "",

    pub const type_name = "Test.User";

    pub const fields = [_]zmdb.Field{
        zmdb.Field.text("Username").withUnique("用户名已存在"),
        zmdb.Field.text("Email").withUniqueRequired("邮箱已被注册"),
        zmdb.Field.text("Phone").withUnique("手机号已被使用"),
        zmdb.Field.int("Age"),
        zmdb.Field.text("Status"),
        zmdb.Field.boolean("Enabled"),
        zmdb.Field.json("Tags"),
        zmdb.Field.time("CreateTime"),
        zmdb.Field.text("Remark").notIndexed(),
        zmdb.Field.text("Cache").notSave(),
    };

    pub fn initEmpty(gpa: std.mem.Allocator) User {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *User) void {
        const gpa = self.gpa;
        gpa.free(self.name);
        gpa.free(self.username);
        gpa.free(self.email);
        gpa.free(self.phone);
        gpa.free(self.status);
        gpa.free(self.tags);
        gpa.free(self.remark);
        gpa.free(self.cache);
        self.* = .{ .gpa = gpa };
    }

    pub fn clone(self: *const User, gpa: std.mem.Allocator) !User {
        return .{
            .gpa = gpa,
            .id = self.id,
            .name = try gpa.dupe(u8, self.name),
            .username = try gpa.dupe(u8, self.username),
            .email = try gpa.dupe(u8, self.email),
            .phone = try gpa.dupe(u8, self.phone),
            .age = self.age,
            .status = try gpa.dupe(u8, self.status),
            .enabled = self.enabled,
            .tags = try gpa.dupe(u8, self.tags),
            .create_time = self.create_time,
            .remark = try gpa.dupe(u8, self.remark),
            .cache = try gpa.dupe(u8, self.cache),
        };
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
        if (std.mem.eql(u8, name, "Phone")) {
            return if (self.phone.len == 0) .{ .null = {} } else .{ .text = self.phone };
        }
        if (std.mem.eql(u8, name, "Age")) return .{ .int = self.age };
        if (std.mem.eql(u8, name, "Status")) return .{ .text = self.status };
        if (std.mem.eql(u8, name, "Enabled")) return .{ .boolean = self.enabled };
        if (std.mem.eql(u8, name, "Tags")) return .{ .text = self.tags };
        if (std.mem.eql(u8, name, "CreateTime")) {
            return if (self.create_time) |dt| .{ .datetime = dt } else .{ .null = {} };
        }
        if (std.mem.eql(u8, name, "Remark")) return .{ .text = self.remark };
        if (std.mem.eql(u8, name, "Cache")) return .{ .text = self.cache };
        return null;
    }

    pub fn setField(self: *User, name: []const u8, value: zmdb.Value) !bool {
        if (std.mem.eql(u8, name, "Username")) {
            try replaceText(self.gpa, &self.username, value);
            return true;
        }
        if (std.mem.eql(u8, name, "Email")) {
            try replaceText(self.gpa, &self.email, value);
            return true;
        }
        if (std.mem.eql(u8, name, "Phone")) {
            try replaceText(self.gpa, &self.phone, value);
            return true;
        }
        if (std.mem.eql(u8, name, "Age")) {
            self.age = zmdb.value.toI64(value) orelse 0;
            return true;
        }
        if (std.mem.eql(u8, name, "Status")) {
            try replaceText(self.gpa, &self.status, value);
            return true;
        }
        if (std.mem.eql(u8, name, "Enabled")) {
            self.enabled = zmdb.value.toBool(value) orelse false;
            return true;
        }
        if (std.mem.eql(u8, name, "Tags")) {
            try replaceText(self.gpa, &self.tags, value);
            return true;
        }
        if (std.mem.eql(u8, name, "CreateTime")) {
            self.create_time = zmdb.value.toDateTime(value);
            return true;
        }
        if (std.mem.eql(u8, name, "Remark")) {
            try replaceText(self.gpa, &self.remark, value);
            return true;
        }
        if (std.mem.eql(u8, name, "Cache")) {
            try replaceText(self.gpa, &self.cache, value);
            return true;
        }
        return false;
    }
};

fn replaceText(gpa: std.mem.Allocator, target: *[]const u8, value: zmdb.Value) !void {
    const text = (try zmdb.value.toTextAlloc(value, gpa)) orelse "";
    gpa.free(target.*);
    target.* = text;
}

pub const Employee = struct {
    gpa: std.mem.Allocator,
    id: i64 = 0,
    name: []const u8 = "",
    company_id: i64 = 0,
    employee_number: []const u8 = "",
    id_card_number: []const u8 = "",
    full_name: []const u8 = "",

    pub const type_name = "Test.Employee";

    pub const fields = [_]zmdb.Field{
        zmdb.Field.int("CompanyId"),
        zmdb.Field.text("EmployeeNumber"),
        zmdb.Field.text("IdCardNumber").withUnique("身份证号已存在"),
    };

    pub const composite_uniques = [_]zmdb.CompositeUniqueRule{
        zmdb.CompositeUniqueRule.init("CompanyUnique", &.{ "CompanyId", "EmployeeNumber" }, "同一公司内工号必须唯一"),
    };

    pub fn initEmpty(gpa: std.mem.Allocator) Employee {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Employee) void {
        const gpa = self.gpa;
        gpa.free(self.name);
        gpa.free(self.employee_number);
        gpa.free(self.id_card_number);
        gpa.free(self.full_name);
        self.* = .{ .gpa = gpa };
    }

    pub fn getId(self: *const Employee) i64 {
        return self.id;
    }

    pub fn setId(self: *Employee, id: i64) void {
        self.id = id;
    }

    pub fn getName(self: *const Employee) []const u8 {
        return self.name;
    }

    pub fn setName(self: *Employee, name: []const u8) !void {
        const copy = try self.gpa.dupe(u8, name);
        self.gpa.free(self.name);
        self.name = copy;
    }

    pub fn getField(self: *const Employee, name: []const u8) ?zmdb.Value {
        if (std.mem.eql(u8, name, "CompanyId")) return .{ .int = self.company_id };
        if (std.mem.eql(u8, name, "EmployeeNumber")) return .{ .text = self.employee_number };
        if (std.mem.eql(u8, name, "IdCardNumber")) return .{ .text = self.id_card_number };
        if (std.mem.eql(u8, name, "FullName")) return .{ .text = self.full_name };
        return null;
    }

    pub fn setField(self: *Employee, name: []const u8, value: zmdb.Value) !bool {
        if (std.mem.eql(u8, name, "CompanyId")) {
            self.company_id = zmdb.value.toI64(value) orelse 0;
            return true;
        }
        if (std.mem.eql(u8, name, "EmployeeNumber")) {
            try replaceText(self.gpa, &self.employee_number, value);
            return true;
        }
        if (std.mem.eql(u8, name, "IdCardNumber")) {
            try replaceText(self.gpa, &self.id_card_number, value);
            return true;
        }
        if (std.mem.eql(u8, name, "FullName")) {
            try replaceText(self.gpa, &self.full_name, value);
            return true;
        }
        return false;
    }
};

/// 只读缓存实体（类级 `not_save`：不读写磁盘）。
pub const Setting = struct {
    gpa: std.mem.Allocator,
    id: i64 = 0,
    name: []const u8 = "",
    value: []const u8 = "",

    pub const type_name = "Test.Setting";
    pub const not_save = true;

    pub const fields = [_]zmdb.Field{zmdb.Field.text("Value")};

    pub fn initEmpty(gpa: std.mem.Allocator) Setting {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Setting) void {
        const gpa = self.gpa;
        gpa.free(self.name);
        gpa.free(self.value);
        self.* = .{ .gpa = gpa };
    }

    pub fn getId(self: *const Setting) i64 {
        return self.id;
    }

    pub fn setId(self: *Setting, id: i64) void {
        self.id = id;
    }

    pub fn getName(self: *const Setting) []const u8 {
        return self.name;
    }

    pub fn setName(self: *Setting, name: []const u8) !void {
        const copy = try self.gpa.dupe(u8, name);
        self.gpa.free(self.name);
        self.name = copy;
    }

    pub fn getField(self: *const Setting, name: []const u8) ?zmdb.Value {
        if (std.mem.eql(u8, name, "Value")) return .{ .text = self.value };
        return null;
    }

    pub fn setField(self: *Setting, name: []const u8, value: zmdb.Value) !bool {
        if (std.mem.eql(u8, name, "Value")) {
            try replaceText(self.gpa, &self.value, value);
            return true;
        }
        return false;
    }
};

/// 造一个用户。
pub fn user(gpa: std.mem.Allocator, index: i64) !User {
    var name_buf: [32]u8 = undefined;
    var username_buf: [32]u8 = undefined;
    var email_buf: [48]u8 = undefined;
    var tags_buf: [48]u8 = undefined;
    var remark_buf: [32]u8 = undefined;
    var cache_buf: [32]u8 = undefined;

    const name = try std.fmt.bufPrint(&name_buf, "用户{d}", .{index});
    const username = try std.fmt.bufPrint(&username_buf, "user{d}", .{index});
    const email = try std.fmt.bufPrint(&email_buf, "user{d}@example.com", .{index});
    const tags = try std.fmt.bufPrint(&tags_buf, "[ \"tag\", \"tag{d}\" ]", .{index});
    const remark = try std.fmt.bufPrint(&remark_buf, "备注{d}", .{index});
    const cache = try std.fmt.bufPrint(&cache_buf, "cache-{d}", .{index});

    return .{
        .gpa = gpa,
        .name = try gpa.dupe(u8, name),
        .username = try gpa.dupe(u8, username),
        .email = try gpa.dupe(u8, email),
        .phone = try gpa.dupe(u8, ""),
        .age = 18 + @mod(index, 30),
        .status = try gpa.dupe(u8, if (@mod(index, 2) == 0) "Active" else "Disabled"),
        .enabled = @mod(index, 2) == 0,
        .tags = try gpa.dupe(u8, tags),
        .create_time = .{
            .year = 2024,
            .month = 1,
            .day = @intCast(@mod(index, 28) + 1),
            .hour = 8,
            .minute = 30,
        },
        .remark = try gpa.dupe(u8, remark),
        .cache = try gpa.dupe(u8, cache),
    };
}

/// 造一个员工。
pub fn employee(gpa: std.mem.Allocator, company: i64, number: []const u8, id_card: []const u8) !Employee {
    var name_buf: [48]u8 = undefined;
    var full_buf: [48]u8 = undefined;
    const name = try std.fmt.bufPrint(&name_buf, "员工{s}", .{number});
    const full = try std.fmt.bufPrint(&full_buf, "姓名{s}", .{number});
    return .{
        .gpa = gpa,
        .name = try gpa.dupe(u8, name),
        .company_id = company,
        .employee_number = try gpa.dupe(u8, number),
        .id_card_number = try gpa.dupe(u8, id_card),
        .full_name = try gpa.dupe(u8, full),
    };
}
