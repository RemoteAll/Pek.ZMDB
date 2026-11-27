//! # Pek.ZMDB —— 高性能内存数据库（Zig 版，Zig 0.17）
//!
//! C# [`Pek.MDB`] 与 Rust [`Pek.RMDB`] 的 Zig 实现：面向 **「读多写少、内存为主、
//! JSON 异步持久化」** 场景，提供唯一约束（单字段/复合）、类型感知索引、分页/范围/模糊查询
//! 与批量操作，持久化格式与 C# `SimpleJsonString` **双向兼容**。
//!
//! ## 快速开始
//!
//! ```zig
//! const std = @import("std");
//! const zmdb = @import("pek_zmdb");
//!
//! const User = struct {
//!     gpa: std.mem.Allocator,
//!     id: i64 = 0,
//!     name: []const u8 = &.{},
//!     username: []const u8 = &.{},
//!     age: i64 = 0,
//!
//!     pub const type_name = "Demo.User"; // Data/Demo.User.json
//!     pub const fields = [_]zmdb.Field{
//!         zmdb.Field.text("Username").withUnique("用户名已存在"),
//!         zmdb.Field.int("Age"),
//!     };
//!
//!     pub fn initEmpty(gpa: std.mem.Allocator) User { return .{ .gpa = gpa }; }
//!     pub fn deinit(self: *User) void { self.username = &.{}; }
//!     pub fn getId(self: *const User) i64 { return self.id; }
//!     pub fn setId(self: *User, id: i64) void { self.id = id; }
//!     pub fn getField(self: *const User, name: []const u8) ?zmdb.Value {
//!         if (std.mem.eql(u8, name, "Username")) return .{ .text = self.username };
//!         if (std.mem.eql(u8, name, "Age")) return .{ .int = self.age };
//!         return null;
//!     }
//!     pub fn setField(self: *User, name: []const u8, value: zmdb.Value) !bool { ... }
//! };
//! ```
//!
//! ## 复用 zzig（不重复实现公共能力）
//!
//! | 能力 | 来源 |
//! |---|---|
//! | 通用字段值（`null/boolean/int/float/decimal/text/blob/datetime` + 跨类型取值） | `zzig.db.Value` |
//! | 日期时间解析/格式化/Unix 换算 | `zzig.DateTime` |
//! | 字符串缓冲（序列化） | `zzig.Buf` |
//! | 原子写文件 / 读文件 / 建目录 | `zzig.fsio` |
//! | ASCII 大小写不敏感判断 | `zzig.ascii` + `std.ascii` |
//! | JSON 值树（对象/数组/标量 + 序列化） | `zzig.web.Value` |
//!
//! 本项目只补 zzig 没有的领域能力：**C# 裸键 JSON 宽容词法**、类型感知索引、
//! 唯一约束、Treap 有序映射、后台写合并。
//!
//! ## 设计文档
//!
//! - `README.md`：特性、API、与 C#/Rust 对照；
//! - `docs/与C#对照.md`：语义映射与有意差异。

const std = @import("std");

pub const value = @import("value.zig");
pub const model = @import("model.zig");
pub const entity = @import("entity.zig");
pub const json = @import("json.zig");
pub const ordered = @import("ordered.zig");
pub const index = @import("index.zig");
pub const unique = @import("unique.zig");
pub const table = @import("table.zig");
pub const persist = @import("persist.zig");
pub const db = @import("db.zig");
pub const errors = @import("error.zig");

// —— 常用类型直出 ——

pub const Value = value.Value;
pub const DateTime = value.DateTime;
pub const FieldKind = value.FieldKind;
pub const Key = value.Key;

pub const Field = model.Field;
pub const UniqueRule = model.UniqueRule;
pub const CompositeUniqueRule = model.CompositeUniqueRule;
pub const ConstraintType = model.ConstraintType;
pub const Violation = model.Violation;
pub const Condition = model.Condition;
pub const IndexStatistics = model.IndexStatistics;
pub const TableStatistics = model.TableStatistics;
pub const DbStatistics = model.DbStatistics;

pub const Ref = entity.Ref;
pub const List = entity.List;
pub const Page = entity.Page;

pub const Error = errors.Error;

pub const MemoryDb = db.MemoryDb;
pub const DbOptions = db.DbOptions;
pub const Options = db.Options;

pub const configureGlobal = db.configureGlobal;
pub const global = db.global;
pub const deinitGlobal = db.deinitGlobal;

pub const insert = db.insert;
pub const insertByIndex = db.insertByIndex;
pub const insertBatch = db.insertBatch;
pub const update = db.update;
pub const delete = db.delete;
pub const clear = db.clear;
pub const clearAll = db.clearAll;
pub const flush = db.flush;
pub const findById = db.findById;
pub const findAll = db.findAll;
pub const findBy = db.findBy;
pub const findByRange = db.findByRange;
pub const findByLike = db.findByLike;
pub const findByMultiple = db.findByMultiple;
pub const findByPage = db.findByPage;
pub const findByUnique = db.findByUnique;
pub const findByCompositeUnique = db.findByCompositeUnique;
pub const isUniqueValueExists = db.isUniqueValueExists;
pub const statistics = db.statistics;

test {
    // 收集各模块单测（Zig 只会跑根文件可达的 test 块）
    std.testing.refAllDecls(@This());
    _ = value;
    _ = model;
    _ = entity;
    _ = json;
    _ = ordered;
    _ = index;
    _ = unique;
    _ = table;
    _ = persist;
    _ = db;
    _ = @import("tests.zig");
}
