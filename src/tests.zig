//! 集成测试（CRUD / 索引 / 唯一约束 / 持久化 / 并发）。
//!
//! 注意所有权：查询返回的 `List`/`Ref` 必须 `deinit`/`release`，
//! 与 `std.testing.allocator` 的泄漏检测配合可发现漏释放。

const std = @import("std");
const zzig = @import("zzig");
const zmdb = @import("zmdb.zig");
const fixtures = @import("fixtures.zig");

const User = fixtures.User;
const Employee = fixtures.Employee;
const Setting = fixtures.Setting;

const testing = std.testing;
const gpa = testing.allocator;
const io = testing.io;

// ----------------------------------------------------------------------
// 辅助
// ----------------------------------------------------------------------

fn memoryDb() !zmdb.MemoryDb {
    return zmdb.MemoryDb.inMemory(gpa, io);
}

fn insertUser(db: *zmdb.MemoryDb, index: i64) !i64 {
    return db.insert(User, try fixtures.user(gpa, index), null);
}

/// 取列表长度并释放（列表所有权在这里消费）。
fn listLen(list: anytype) usize {
    var owned = list;
    defer owned.deinit();
    return owned.len();
}

const TempDb = struct {
    tmp: std.testing.TmpDir,
    dir_path: []u8,
    db: zmdb.MemoryDb,
    db_open: bool = true,

    fn init(options: zmdb.DbOptions) !TempDb {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();

        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const length = try tmp.dir.realPath(io, &buf);
        const dir_path = try gpa.dupe(u8, buf[0..length]);
        errdefer gpa.free(dir_path);

        var effective = options;
        effective.base_dir = dir_path;
        const db = try zmdb.MemoryDb.init(gpa, io, effective);
        return .{ .tmp = tmp, .dir_path = dir_path, .db = db };
    }

    /// 手工关闭数据库（之后 `deinit` 不会再重复关闭）。
    fn closeDb(self: *TempDb) void {
        if (self.db_open) {
            self.db.deinit();
            self.db_open = false;
        }
    }

    fn deinit(self: *TempDb) void {
        self.closeDb();
        gpa.free(self.dir_path);
        self.tmp.cleanup();
    }

    fn dataFile(self: *TempDb, comptime T: type) ![]u8 {
        return (try self.db.dataFile(T)) orelse return error.NoDataFile;
    }
};

fn fileExists(path: []const u8) bool {
    const bytes = zzig.fsio.readFileAlloc(io, gpa, path, 16 * 1024 * 1024) catch return false;
    gpa.free(bytes);
    return true;
}

fn readText(path: []const u8) ![]u8 {
    return zzig.fsio.readFileAlloc(io, gpa, path, 16 * 1024 * 1024) catch |err| switch (err) {
        error.FileNotFound => &.{},
        else => return err,
    };
}

fn waitForFile(path: []const u8, timeout_ms: u64) bool {
    var waited: u64 = 0;
    while (waited < timeout_ms) : (waited += 10) {
        if (fileExists(path)) return true;
        io.sleep(.{ .nanoseconds = 10 * std.time.ns_per_ms }, .awake) catch {};
    }
    return false;
}

// ----------------------------------------------------------------------
// CRUD
// ----------------------------------------------------------------------

test "插入分配自增 ID、可按主键查找" {
    var db = try memoryDb();
    defer db.deinit();

    const id1 = try insertUser(&db, 1);
    const id2 = try insertUser(&db, 2);
    try testing.expectEqual(@as(i64, 1), id1);
    try testing.expectEqual(@as(i64, 2), id2);

    const found = (try db.findById(User, id1)).?;
    defer found.release();
    try testing.expectEqual(id1, found.get().getId());
    try testing.expectEqualStrings("user1", found.get().username);
    try testing.expectEqualStrings("用户1", found.get().name);
    try testing.expect((try db.findById(User, 999)) == null);
}

test "插入覆盖传入的主键（与 C# 一致）" {
    var db = try memoryDb();
    defer db.deinit();

    var entity = try fixtures.user(gpa, 1);
    entity.id = 500;
    const id = try db.insert(User, entity, null);
    try testing.expectEqual(@as(i64, 1), id);
    try testing.expect((try db.findById(User, 500)) == null);
}

test "更新替换对象与索引" {
    var db = try memoryDb();
    defer db.deinit();

    const id = try insertUser(&db, 1);

    const ref = (try db.findById(User, id)).?;
    var entity = try ref.get().clone(gpa);
    ref.release();
    defer entity.deinit();

    gpa.free(entity.username);
    entity.username = try gpa.dupe(u8, "renamed");
    entity.age = 99;
    try db.update(User, try entity.clone(gpa), null);

    try testing.expect((try db.findByUnique(User, "Username", .{ .text = "user1" })) == null);

    const renamed = (try db.findByUnique(User, "Username", .{ .text = "renamed" })).?;
    defer renamed.release();
    try testing.expectEqual(id, renamed.get().getId());
    try testing.expectEqual(@as(usize, 1), listLen(try db.findBy(User, "Age", .{ .int = 99 })));
    try testing.expectEqual(@as(usize, 0), listLen(try db.findBy(User, "Age", .{ .int = 19 })));

    const reloaded = (try db.findById(User, id)).?;
    defer reloaded.release();
    try testing.expectEqualStrings("renamed", reloaded.get().username);
}

test "更新不存在的对象返回 NotFound" {
    var db = try memoryDb();
    defer db.deinit();

    var entity = try fixtures.user(gpa, 1);
    entity.id = 42;
    try testing.expectError(error.NotFound, db.update(User, entity, null));
}

test "删除清理全部索引，唯一值可复用" {
    var db = try memoryDb();
    defer db.deinit();

    const id = try insertUser(&db, 1);
    try testing.expect(try db.delete(User, id));
    try testing.expect(!try db.delete(User, id));

    try testing.expect((try db.findById(User, id)) == null);
    try testing.expectEqual(@as(usize, 0), listLen(try db.findBy(User, "Age", .{ .int = 19 })));
    try testing.expect((try db.findByUnique(User, "Username", .{ .text = "user1" })) == null);
    try testing.expectEqual(@as(usize, 0), listLen(try db.findAll(User)));

    const again = try insertUser(&db, 1);
    try testing.expectEqual(@as(i64, 2), again);
    const found = (try db.findByUnique(User, "Username", .{ .text = "user1" })).?;
    defer found.release();
    try testing.expectEqual(again, found.get().getId());
}

test "findAll 按 ID 升序" {
    var db = try memoryDb();
    defer db.deinit();
    var index: i64 = 1;
    while (index <= 5) : (index += 1) _ = try insertUser(&db, index);

    var all = try db.findAll(User);
    defer all.deinit();
    try testing.expectEqual(@as(usize, 5), all.len());
    for (0..all.len()) |i| {
        try testing.expectEqual(@as(i64, @intCast(i + 1)), all.at(i).getId());
    }
}

test "Name / Id 无需声明即可查询" {
    var db = try memoryDb();
    defer db.deinit();
    const id = try insertUser(&db, 1);

    try testing.expectEqual(@as(usize, 1), listLen(try db.findBy(User, "Name", .{ .text = "用户1" })));
    try testing.expectEqual(@as(usize, 1), listLen(try db.findBy(User, "Id", .{ .int = id })));
}

test "分页：按索引顺序取页" {
    var db = try memoryDb();
    defer db.deinit();
    var index: i64 = 1;
    while (index <= 25) : (index += 1) _ = try insertUser(&db, index);

    var page = try db.findByPage(User, "Age", 0, 10, true);
    defer page.deinit();
    try testing.expectEqual(@as(usize, 25), page.total_count);
    try testing.expectEqual(@as(usize, 3), page.total_pages);
    try testing.expectEqual(@as(usize, 10), page.len());
    var i: usize = 1;
    while (i < page.len()) : (i += 1) {
        try testing.expect(page.at(i - 1).age <= page.at(i).age);
    }

    var last = try db.findByPage(User, "Age", 2, 10, true);
    defer last.deinit();
    try testing.expectEqual(@as(usize, 5), last.len());

    var desc = try db.findByPage(User, "Age", 0, 5, false);
    defer desc.deinit();
    try testing.expectEqual(@as(usize, 5), desc.len());
    i = 1;
    while (i < desc.len()) : (i += 1) {
        try testing.expect(desc.at(i - 1).age >= desc.at(i).age);
    }

    // 无排序字段：按 ID 升序
    var plain = try db.findByPage(User, null, 0, 3, true);
    defer plain.deinit();
    try testing.expectEqual(@as(usize, 3), plain.len());
    try testing.expectEqual(@as(i64, 1), plain.at(0).getId());
    try testing.expectEqual(@as(i64, 3), plain.at(2).getId());
}

test "分页：索引不完整时退回全量排序（空值排最前）" {
    var db = try memoryDb();
    defer db.deinit();

    var missing = try fixtures.user(gpa, 1);
    missing.create_time = null;
    _ = try db.insert(User, missing, null);
    var index: i64 = 2;
    while (index <= 5) : (index += 1) _ = try insertUser(&db, index);

    var page = try db.findByPage(User, "CreateTime", 0, 10, true);
    defer page.deinit();
    try testing.expectEqual(@as(usize, 5), page.len());
    try testing.expectEqual(@as(i64, 1), page.at(0).getId());

    // 索引完整时按值顺序（Active 在 Disabled 之前，同值按 ID）
    var status_page = try db.findByPage(User, "Status", 0, 10, true);
    defer status_page.deinit();
    const expected = [_]i64{ 2, 4, 1, 3, 5 };
    for (expected, 0..) |expected_id, position| {
        try testing.expectEqual(expected_id, status_page.at(position).getId());
    }
}

test "多条件交集" {
    var db = try memoryDb();
    defer db.deinit();
    var index: i64 = 1;
    while (index <= 6) : (index += 1) _ = try insertUser(&db, index);

    var result = try db.findByMultiple(User, &.{
        .{ .field = "Status", .value = .{ .text = "Active" } },
        .{ .field = "Age", .value = .{ .int = 20 } },
    });
    defer result.deinit();
    try testing.expectEqual(@as(usize, 1), result.len());
    try testing.expectEqual(@as(i64, 2), result.at(0).getId());

    try testing.expectEqual(@as(usize, 0), listLen(try db.findByMultiple(User, &.{
        .{ .field = "Status", .value = .{ .text = "Nope" } },
    })));
    try testing.expectEqual(@as(usize, 0), listLen(try db.findByMultiple(User, &.{})));
}

test "InsertByIndex 只建指定索引" {
    var db = try memoryDb();
    defer db.deinit();

    const id = try db.insertByIndex(User, try fixtures.user(gpa, 1), &.{"Status"}, null);
    try testing.expectEqual(@as(i64, 1), id);
    try testing.expectEqual(@as(usize, 1), listLen(try db.findBy(User, "Status", .{ .text = "Disabled" })));
    try testing.expectEqual(@as(usize, 0), listLen(try db.findBy(User, "Age", .{ .int = 19 })));

    const ref = (try db.findById(User, id)).?;
    ref.release();
}

test "批量插入分配 ID 并建索引" {
    var db = try memoryDb();
    defer db.deinit();

    var objects: std.ArrayList(User) = .empty;
    defer objects.deinit(gpa);
    var index: i64 = 1;
    while (index <= 10) : (index += 1) try objects.append(gpa, try fixtures.user(gpa, index));

    const ids = try db.insertBatch(User, objects.items, null);
    defer gpa.free(ids);
    try testing.expectEqual(@as(usize, 10), ids.len);
    try testing.expectEqual(@as(i64, 1), ids[0]);
    try testing.expectEqual(@as(i64, 10), ids[9]);
    try testing.expectEqual(@as(usize, 10), listLen(try db.findAll(User)));
    try testing.expectEqual(@as(usize, 5), listLen(try db.findBy(User, "Status", .{ .text = "Active" })));

    const empty_ids = try db.insertBatch(User, &.{}, null);
    try testing.expectEqual(@as(usize, 0), empty_ids.len);
}

test "清空重置数据与 ID" {
    var db = try memoryDb();
    defer db.deinit();
    _ = try insertUser(&db, 1);
    _ = try insertUser(&db, 2);
    try db.clear(User);
    try testing.expectEqual(@as(usize, 0), listLen(try db.findAll(User)));
    try testing.expectEqual(@as(i64, 1), try insertUser(&db, 3));
}

test "统计报告行数/索引/唯一约束" {
    var db = try memoryDb();
    defer db.deinit();
    _ = try insertUser(&db, 1);
    _ = try insertUser(&db, 2);

    var stats = try db.statistics(gpa);
    defer stats.deinit(gpa);
    try testing.expectEqual(@as(usize, 1), stats.table_count);
    try testing.expectEqual(@as(usize, 2), stats.total_rows);

    const table = stats.tables[0];
    try testing.expectEqualStrings("Test.User", table.type_name);
    try testing.expectEqual(@as(usize, 2), table.rows);
    try testing.expectEqual(@as(usize, 3), table.unique_fields);
    try testing.expectEqual(@as(usize, 0), table.unique_composites);
    try testing.expect(!table.in_memory);
    try testing.expect(table.indexes.len >= 6);

    var found_username_index = false;
    for (table.indexes) |index_stats| {
        if (std.mem.eql(u8, index_stats.property_name, "Username")) {
            found_username_index = true;
            try testing.expectEqualStrings("StringIndex", index_stats.index_type);
            try testing.expectEqual(@as(usize, 2), index_stats.id_count);
        }
    }
    try testing.expect(found_username_index);
}

// ----------------------------------------------------------------------
// 索引
// ----------------------------------------------------------------------

fn seed(db: *zmdb.MemoryDb, count: i64) !void {
    var index: i64 = 1;
    while (index <= count) : (index += 1) _ = try insertUser(db, index);
}

test "文本：精确区分大小写，模式不区分" {
    var db = try memoryDb();
    defer db.deinit();
    try seed(&db, 4);

    try testing.expectEqual(@as(usize, 2), listLen(try db.findBy(User, "Status", .{ .text = "Active" })));
    try testing.expectEqual(@as(usize, 0), listLen(try db.findBy(User, "Status", .{ .text = "active" })));
    try testing.expectEqual(@as(usize, 2), listLen(try db.findByLike(User, "Status", "active")));
    try testing.expectEqual(@as(usize, 2), listLen(try db.findByLike(User, "Status", "Act*")));
    try testing.expectEqual(@as(usize, 2), listLen(try db.findByLike(User, "Status", "*tive")));
    try testing.expectEqual(@as(usize, 2), listLen(try db.findByLike(User, "Status", "*cti*")));
    try testing.expectEqual(@as(usize, 2), listLen(try db.findByLike(User, "Status", "A*e")));
    try testing.expectEqual(@as(usize, 2), listLen(try db.findByLike(User, "Status", "D*")));
    try testing.expectEqual(@as(usize, 0), listLen(try db.findByLike(User, "Status", "Nope*")));
}

test "文本：范围按小写字典序" {
    var db = try memoryDb();
    defer db.deinit();
    try seed(&db, 5);

    var names = try db.findByRange(User, "Username", .{ .text = "user2" }, .{ .text = "user4" });
    defer names.deinit();
    try testing.expectEqual(@as(usize, 3), names.len());

    try testing.expectEqual(@as(usize, 3), listLen(try db.findByRange(
        User,
        "Username",
        .{ .text = "USER2" },
        .{ .text = "USER4" },
    )));
}

test "数值：范围与跨类型查询" {
    var db = try memoryDb();
    defer db.deinit();
    try seed(&db, 10);

    var found = try db.findByRange(User, "Age", .{ .int = 20 }, .{ .int = 22 });
    defer found.deinit();
    try testing.expectEqual(@as(usize, 3), found.len());

    try testing.expectEqual(@as(usize, 3), listLen(try db.findByRange(
        User,
        "Age",
        .{ .text = "20" },
        .{ .text = "22" },
    )));
    try testing.expectEqual(@as(usize, 1), listLen(try db.findBy(User, "Age", .{ .float = 20.0 })));
    try testing.expectEqual(@as(usize, 0), listLen(try db.findByRange(User, "Age", .{ .int = 100 }, .{ .int = 200 })));
    try testing.expectEqual(@as(usize, 0), listLen(try db.findByRange(User, "Age", .{ .int = 200 }, .{ .int = 100 })));
}

test "时间：范围与年/年月/年月日模式" {
    var db = try memoryDb();
    defer db.deinit();
    try seed(&db, 5);

    const start = zmdb.DateTime{ .year = 2024, .month = 1, .day = 3 };
    const end = zmdb.DateTime{ .year = 2024, .month = 1, .day = 4, .hour = 23, .minute = 59, .second = 59 };
    var found = try db.findByRange(User, "CreateTime", .{ .datetime = start }, .{ .datetime = end });
    defer found.deinit();
    try testing.expectEqual(@as(usize, 2), found.len());
    try testing.expectEqual(@as(i64, 2), found.at(0).getId());
    try testing.expectEqual(@as(i64, 3), found.at(1).getId());

    try testing.expectEqual(@as(usize, 5), listLen(try db.findByLike(User, "CreateTime", "2024")));
    try testing.expectEqual(@as(usize, 5), listLen(try db.findByLike(User, "CreateTime", "2024-01")));
    try testing.expectEqual(@as(usize, 1), listLen(try db.findByLike(User, "CreateTime", "2024-01-03")));
    try testing.expectEqual(@as(usize, 0), listLen(try db.findByLike(User, "CreateTime", "2023")));
    try testing.expectEqual(
        @as(usize, 1),
        listLen(try db.findBy(User, "CreateTime", .{ .text = "2024-01-03 08:30:00" })),
    );
}

test "布尔：智能模式值" {
    var db = try memoryDb();
    defer db.deinit();
    try seed(&db, 4);

    try testing.expectEqual(@as(usize, 2), listLen(try db.findBy(User, "Enabled", .{ .boolean = true })));
    try testing.expectEqual(@as(usize, 2), listLen(try db.findByLike(User, "Enabled", "true")));
    try testing.expectEqual(@as(usize, 2), listLen(try db.findByLike(User, "Enabled", "yes")));
    try testing.expectEqual(@as(usize, 2), listLen(try db.findByLike(User, "Enabled", "1")));
    try testing.expectEqual(@as(usize, 2), listLen(try db.findByLike(User, "Enabled", "false")));
    try testing.expectEqual(@as(usize, 2), listLen(try db.findByLike(User, "Enabled", "否")));
    try testing.expectEqual(@as(usize, 0), listLen(try db.findByLike(User, "Enabled", "maybe")));
}

test "JSON 字段按文本索引" {
    var db = try memoryDb();
    defer db.deinit();
    try seed(&db, 3);

    const tags = "[ \"tag\", \"tag2\" ]";
    var found = try db.findBy(User, "Tags", .{ .text = tags });
    defer found.deinit();
    try testing.expectEqual(@as(usize, 1), found.len());
    try testing.expectEqual(@as(i64, 2), found.at(0).getId());
}

test "未建索引/未知字段返回空" {
    var db = try memoryDb();
    defer db.deinit();
    try seed(&db, 2);

    try testing.expectEqual(@as(usize, 0), listLen(try db.findBy(User, "Remark", .{ .text = "备注1" })));
    const first = (try db.findById(User, 1)).?;
    defer first.release();
    try testing.expectEqualStrings("备注1", first.get().remark);

    try testing.expectEqual(@as(usize, 0), listLen(try db.findBy(User, "NotExists", .{ .int = 1 })));
    try testing.expectEqual(@as(usize, 0), listLen(try db.findByRange(User, "NotExists", .{ .int = 1 }, .{ .int = 2 })));
    try testing.expectEqual(@as(usize, 0), listLen(try db.findByLike(User, "NotExists", "*")));
    try testing.expect((try db.findByUnique(User, "NotExists", .{ .int = 1 })) == null);
    try testing.expect(!try db.isUniqueValueExists(User, "NotExists", .{ .int = 1 }, null));
}

// ----------------------------------------------------------------------
// 唯一约束
// ----------------------------------------------------------------------

test "单字段唯一拒绝重复（含冲突细节）" {
    var db = try memoryDb();
    defer db.deinit();
    _ = try insertUser(&db, 1);

    var duplicate = try fixtures.user(gpa, 2);
    gpa.free(duplicate.username);
    duplicate.username = try gpa.dupe(u8, "user1");

    var violation: zmdb.Violation = .{};
    try testing.expectError(error.UniqueViolation, db.insert(User, duplicate, &violation));
    try testing.expectEqual(zmdb.ConstraintType.single, violation.constraint_type);
    try testing.expectEqualStrings("Username", violation.property_name);
    try testing.expectEqual(@as(?i64, 1), violation.conflicting_id);
    try testing.expectEqualStrings("用户名已存在", violation.message);
    try testing.expectEqual(@as(usize, 1), listLen(try db.findAll(User)));
}

test "唯一约束允许空值：多行空值共存" {
    var db = try memoryDb();
    defer db.deinit();
    _ = try insertUser(&db, 1); // phone 空
    _ = try insertUser(&db, 2); // phone 空
    try testing.expectEqual(@as(usize, 2), listLen(try db.findAll(User)));
}

test "唯一约束不允许空值：空串视为空值" {
    var db = try memoryDb();
    defer db.deinit();

    var entity = try fixtures.user(gpa, 1);
    gpa.free(entity.email);
    entity.email = try gpa.dupe(u8, "");

    var violation: zmdb.Violation = .{};
    try testing.expectError(error.UniqueViolation, db.insert(User, entity, &violation));
    try testing.expectEqualStrings("Email", violation.property_name);
    try testing.expectEqual(zmdb.Violation.Detail.null_not_allowed, violation.detail);
    try testing.expect(violation.conflicting_id == null);
    try testing.expectEqual(@as(usize, 0), listLen(try db.findAll(User)));
}

test "按唯一值查找与存在性判断" {
    var db = try memoryDb();
    defer db.deinit();
    const id = try insertUser(&db, 1);

    const found = (try db.findByUnique(User, "Email", .{ .text = "user1@example.com" })).?;
    defer found.release();
    try testing.expectEqual(id, found.get().getId());
    try testing.expect((try db.findByUnique(User, "Email", .{ .text = "none@example.com" })) == null);

    try testing.expect(try db.isUniqueValueExists(User, "Username", .{ .text = "user1" }, null));
    try testing.expect(!try db.isUniqueValueExists(User, "Username", .{ .text = "user1" }, id));
    try testing.expect(try db.isUniqueValueExists(User, "Username", .{ .text = "user1" }, id + 1));
    try testing.expect(!try db.isUniqueValueExists(User, "Username", .{ .text = "other" }, null));
}

test "复合唯一：同公司同工号冲突，跨公司允许" {
    var db = try memoryDb();
    defer db.deinit();

    _ = try db.insert(Employee, try fixtures.employee(gpa, 100, "E001", "ID-1"), null);

    var violation: zmdb.Violation = .{};
    try testing.expectError(
        error.UniqueViolation,
        db.insert(Employee, try fixtures.employee(gpa, 100, "E001", "ID-2"), &violation),
    );
    try testing.expectEqual(zmdb.ConstraintType.composite, violation.constraint_type);
    try testing.expectEqualStrings("CompanyUnique", violation.property_name);
    try testing.expectEqual(@as(usize, 2), violation.fields.len);
    try testing.expectEqualStrings("同一公司内工号必须唯一", violation.message);

    _ = try db.insert(Employee, try fixtures.employee(gpa, 100, "E002", "ID-3"), null);
    _ = try db.insert(Employee, try fixtures.employee(gpa, 200, "E001", "ID-4"), null);
    try testing.expectEqual(@as(usize, 3), listLen(try db.findAll(Employee)));

    const found = (try db.findByCompositeUnique(Employee, "CompanyUnique", &.{
        .{ .field = "EmployeeNumber", .value = .{ .text = "E001" } },
        .{ .field = "CompanyId", .value = .{ .int = 200 } },
    })).?;
    defer found.release();
    try testing.expectEqualStrings("ID-4", found.get().id_card_number);

    try testing.expect((try db.findByCompositeUnique(Employee, "UnknownGroup", &.{
        .{ .field = "CompanyId", .value = .{ .int = 200 } },
    })) == null);
}

test "更新：排除自身但能发现他人冲突" {
    var db = try memoryDb();
    defer db.deinit();
    const id1 = try insertUser(&db, 1);
    const id2 = try insertUser(&db, 2);

    const ref = (try db.findById(User, id1)).?;
    var first = try ref.get().clone(gpa);
    ref.release();
    defer first.deinit();

    // 非唯一字段更新 + 唯一字段不变 → 成功
    first.age = 50;
    try db.update(User, try first.clone(gpa), null);

    // 改成 user2 的邮箱 → 冲突；原对象与索引保持不变
    var conflict = try first.clone(gpa);
    gpa.free(conflict.email);
    conflict.email = try gpa.dupe(u8, "user2@example.com");

    var violation: zmdb.Violation = .{};
    try testing.expectError(error.UniqueViolation, db.update(User, conflict, &violation));
    try testing.expectEqual(@as(?i64, id2), violation.conflicting_id);

    const reloaded = (try db.findById(User, id1)).?;
    defer reloaded.release();
    try testing.expectEqualStrings("user1@example.com", reloaded.get().email);
    try testing.expectEqual(@as(usize, 1), listLen(try db.findBy(User, "Age", .{ .int = 50 })));
}

test "批量插入冲突：已插入的行保留" {
    var db = try memoryDb();
    defer db.deinit();

    var objects: std.ArrayList(User) = .empty;
    defer objects.deinit(gpa);
    try objects.append(gpa, try fixtures.user(gpa, 1));
    try objects.append(gpa, try fixtures.user(gpa, 2));
    var duplicate = try fixtures.user(gpa, 3);
    gpa.free(duplicate.username);
    duplicate.username = try gpa.dupe(u8, "user1");
    try objects.append(gpa, duplicate);

    var violation: zmdb.Violation = .{};
    try testing.expectError(error.UniqueViolation, db.insertBatch(User, objects.items, &violation));
    try testing.expectEqual(@as(usize, 2), listLen(try db.findAll(User)));
    try testing.expectEqualStrings("Username", violation.property_name);
}

// ----------------------------------------------------------------------
// 持久化
// ----------------------------------------------------------------------

test "持久化：后台线程写出 C# 兼容文件" {
    var temp = try TempDb.init(.{});
    defer temp.deinit();

    _ = try insertUser(&temp.db, 1);
    const path = try temp.dataFile(User);
    defer gpa.free(path);

    try testing.expect(waitForFile(path, 3000));
    io.sleep(.{ .nanoseconds = 50 * std.time.ns_per_ms }, .awake) catch {};

    const text = try readText(path);
    defer gpa.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "Id:1") != null);
    try testing.expect(std.mem.indexOf(u8, text, "Name:\"用户1\"") != null);
    try testing.expect(std.mem.indexOf(u8, text, "CreateTime:\"2024-01-02 08:30:00\"") != null);
    try testing.expect(std.mem.indexOf(u8, text, "\"Id\":") == null);
    try testing.expect(std.mem.indexOf(u8, text, "Cache") == null);
    try testing.expect(std.mem.startsWith(u8, text, "[\r\n"));
}

test "持久化：重启恢复数据/索引/唯一约束" {
    var temp = try TempDb.init(.{});
    defer temp.deinit();

    const id = try insertUser(&temp.db, 1);
    _ = try insertUser(&temp.db, 2);
    try temp.db.flush();
    temp.closeDb();

    var db2 = try zmdb.MemoryDb.init(gpa, io, .{ .base_dir = temp.dir_path });
    defer db2.deinit();

    try testing.expectEqual(@as(usize, 2), listLen(try db2.findAll(User)));
    const found = (try db2.findById(User, id)).?;
    defer found.release();
    try testing.expectEqualStrings("user1", found.get().username);
    try testing.expectEqualStrings("", found.get().cache); // NotSave 字段不恢复

    try testing.expectEqual(@as(usize, 1), listLen(try db2.findBy(User, "Status", .{ .text = "Active" })));
    try testing.expectEqual(@as(usize, 2), listLen(try db2.findByRange(User, "Age", .{ .int = 18 }, .{ .int = 100 })));

    const unique = (try db2.findByUnique(User, "Username", .{ .text = "user1" })).?;
    defer unique.release();
    try testing.expectEqual(id, unique.get().getId());

    var duplicate = try fixtures.user(gpa, 9);
    gpa.free(duplicate.username);
    duplicate.username = try gpa.dupe(u8, "user1");
    try testing.expectError(error.UniqueViolation, db2.insert(User, duplicate, null));
}

test "持久化：加载后 ID 计数器修正为 max+1" {
    var temp = try TempDb.init(.{});
    defer temp.deinit();

    var index: i64 = 1;
    while (index <= 5) : (index += 1) _ = try insertUser(&temp.db, index);
    try temp.db.flush();
    temp.closeDb();

    var db2 = try zmdb.MemoryDb.init(gpa, io, .{ .base_dir = temp.dir_path });
    defer db2.deinit();

    try testing.expectEqual(@as(i64, 6), try insertUser(&db2, 6));
    try testing.expectEqual(@as(usize, 6), listLen(try db2.findAll(User)));
    const first = (try db2.findById(User, 1)).?;
    defer first.release();
    try testing.expectEqualStrings("user1", first.get().username);
}

test "持久化：读取 C# 历史文件（裸键 + 注释 + 斜杠日期）" {
    var temp = try TempDb.init(.{});
    defer temp.deinit();

    const path = try temp.dataFile(User);
    defer gpa.free(path);

    const content =
        "// C# SimpleJsonString 风格（裸键 + 注释 + 斜杠日期）\n" ++
        "[\n" ++
        "\t{ Id:7, Name:\"老数据\", Username:\"old\", Email:\"old@example.com\", Age:30, Status:\"Active\", Enabled:true, Tags:[ \"a\", \"b\" ], CreateTime:\"2024/1/5 14:30:00\" }\n" ++
        "]\n";
    try zmdb.persist.writeFileAtomic(io, gpa, path, content);

    const found = (try temp.db.findById(User, 7)).?;
    defer found.release();
    try testing.expectEqualStrings("老数据", found.get().name);
    try testing.expectEqual(@as(i64, 30), found.get().age);
    try testing.expect(found.get().enabled);
    try testing.expectEqualStrings("[\"a\",\"b\"]", found.get().tags);
    var time_buf: [19]u8 = undefined;
    try testing.expectEqualStrings(
        "2024-01-05 14:30:00",
        zmdb.value.formatDateTime(found.get().create_time.?, &time_buf),
    );

    const unique = (try temp.db.findByUnique(User, "Username", .{ .text = "old" })).?;
    defer unique.release();
    try testing.expectEqual(@as(i64, 7), unique.get().getId());

    try testing.expectEqual(@as(i64, 8), try insertUser(&temp.db, 8));
}

test "持久化：加载时唯一冲突的第二行被跳过" {
    var temp = try TempDb.init(.{});
    defer temp.deinit();

    const path = try temp.dataFile(User);
    defer gpa.free(path);
    const content =
        "[\n" ++
        "\t{ Id:1, Name:\"a\", Username:\"dup\", Email:\"a@example.com\", Age:20, Status:\"Active\", Enabled:true, CreateTime:\"2024-01-01 00:00:00\" },\n" ++
        "\t{ Id:2, Name:\"b\", Username:\"dup\", Email:\"b@example.com\", Age:20, Status:\"Active\", Enabled:true, CreateTime:\"2024-01-02 00:00:00\" }\n" ++
        "]\n";
    try zmdb.persist.writeFileAtomic(io, gpa, path, content);

    var all = try temp.db.findAll(User);
    defer all.deinit();
    try testing.expectEqual(@as(usize, 1), all.len());
    try testing.expectEqual(@as(i64, 1), all.at(0).getId());
    try testing.expect((try temp.db.findById(User, 2)) == null);
}

test "持久化：无后台线程时手动 flush 生效" {
    var temp = try TempDb.init(.{
        .auto_persist = false,
        .min_write_interval_ms = 0,
        .flush_on_drop = false,
    });
    defer temp.deinit();

    const path = try temp.dataFile(User);
    defer gpa.free(path);

    _ = try insertUser(&temp.db, 1);
    try testing.expect(!fileExists(path));
    try temp.db.flush();
    try testing.expect(fileExists(path));
}

test "持久化：写合并显著减少写盘次数" {
    var temp = try TempDb.init(.{});
    defer temp.deinit();

    var index: i64 = 1;
    while (index <= 100) : (index += 1) _ = try insertUser(&temp.db, index);
    io.sleep(.{ .nanoseconds = 150 * std.time.ns_per_ms }, .awake) catch {};
    try temp.db.flush();

    var stats = try temp.db.statistics(gpa);
    defer stats.deinit(gpa);
    const count = stats.tables[0].persist_count;
    try testing.expect(count >= 1);
    try testing.expect(count < 100);

    const path = try temp.dataFile(User);
    defer gpa.free(path);
    const text = try readText(path);
    defer gpa.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "Id:100") != null);
}

test "持久化：deinit 时落盘未写修改" {
    var temp = try TempDb.init(.{ .auto_persist = false });
    _ = try insertUser(&temp.db, 1);
    temp.closeDb();

    var db2 = try zmdb.MemoryDb.init(gpa, io, .{ .base_dir = temp.dir_path });
    defer db2.deinit();
    try testing.expectEqual(@as(usize, 1), listLen(try db2.findAll(User)));

    gpa.free(temp.dir_path);
    temp.tmp.cleanup();
}

test "持久化：NotSave 实体不读写磁盘" {
    var temp = try TempDb.init(.{});
    defer temp.deinit();

    _ = try temp.db.insert(Setting, .{
        .gpa = gpa,
        .name = try gpa.dupe(u8, "site"),
        .value = try gpa.dupe(u8, "hello"),
    }, null);
    try testing.expectEqual(@as(usize, 1), listLen(try temp.db.findAll(Setting)));
    try temp.db.flush();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/Data/Test.Setting.json", .{temp.dir_path});
    try testing.expect(!fileExists(path));
}

test "快照格式：pretty=false 输出单行（便于网络/日志场景）" {
    var db = try memoryDb();
    defer db.deinit();
    _ = try insertUser(&db, 1);

    const table = try db.tableOf(User);
    const text = try table.snapshotText(gpa, false);
    defer gpa.free(text);
    try testing.expect(std.mem.startsWith(u8, text, "[ { Id:1"));
    try testing.expect(std.mem.indexOf(u8, text, "\r\n") == null);
}

// ----------------------------------------------------------------------
// 全局实例 / 辅助 API
// ----------------------------------------------------------------------

test "loadedTables 列出已加载表（按名称排序）" {
    var db = try memoryDb();
    defer db.deinit();
    _ = try insertUser(&db, 1);

    const names = try db.loadedTables(gpa);
    defer gpa.free(names);
    try testing.expectEqual(@as(usize, 1), names.len);
    try testing.expectEqualStrings("Test.User", names[0]);
}

test "clearAll 清空全部表并持久化为空表" {
    var temp = try TempDb.init(.{ .auto_persist = false });
    defer temp.deinit();

    _ = try insertUser(&temp.db, 1);
    try temp.db.flush();
    temp.db.clearAll();
    try temp.db.flush();

    const path = try temp.dataFile(User);
    defer gpa.free(path);
    const text = try readText(path);
    defer gpa.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "Id:1") == null);
    try testing.expectEqual(@as(usize, 0), listLen(try temp.db.findAll(User)));
}

test "全局实例：配置后可用，重复配置报错" {
    const options = zmdb.DbOptions{
        .base_dir = "",
        .auto_persist = false,
        .flush_on_drop = false,
    };
    try zmdb.configureGlobal(gpa, io, options);
    defer zmdb.deinitGlobal();

    const id = try zmdb.insert(User, try fixtures.user(gpa, 1), null);
    const ref = (try zmdb.findById(User, id)).?;
    defer ref.release();
    try testing.expectEqual(id, ref.get().getId());

    var stats = try zmdb.statistics(gpa);
    defer stats.deinit(gpa);
    try testing.expectEqual(@as(usize, 1), stats.table_count);

    try testing.expectError(error.AlreadyConfigured, zmdb.configureGlobal(gpa, io, options));
}

// ----------------------------------------------------------------------
// 并发
// ----------------------------------------------------------------------

test "并发：多线程按主键读取" {
    var db = try memoryDb();
    defer db.deinit();

    const id = try insertUser(&db, 1);

    const Worker = struct {
        fn run(database: *zmdb.MemoryDb, target: i64) void {
            var round: usize = 0;
            while (round < 2000) : (round += 1) {
                const ref = (database.findById(User, target) catch @panic("findById 失败")) orelse
                    @panic("并发读丢失数据");
                if (ref.get().getId() != target) @panic("读到错误对象");
                ref.release();
            }
        }
    };

    var threads: [4]std.Thread = undefined;
    for (&threads) |*thread| {
        thread.* = try std.Thread.spawn(.{}, Worker.run, .{ &db, id });
    }
    for (&threads) |thread| thread.join();
}
