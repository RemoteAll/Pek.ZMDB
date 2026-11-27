//! 实体契约、引用计数句柄与查询结果容器。
//!
//! # 实体契约（编译期检查，缺一即 `@compileError`）
//!
//! ```zig
//! pub const User = struct {
//!     gpa: std.mem.Allocator,
//!     id: i64 = 0,
//!     name: []const u8 = &.{},
//!     username: []const u8 = &.{},
//!
//!     pub const type_name = "Demo.User";                 // 持久化文件名 Data/Demo.User.json
//!     pub const fields = [_]Field{                       // 字段清单（Id/Name 由框架维护）
//!         Field.text("Username").withUnique("用户名已存在"),
//!         Field.int("Age"),
//!     };
//!     pub const composite_uniques = [_]CompositeUniqueRule{ ... };  // 可选
//!     pub const not_save = false;                        // 可选：整类不落盘
//!
//!     pub fn initEmpty(gpa: std.mem.Allocator) User
//!     pub fn deinit(self: *User) void
//!     pub fn getId(self: *const User) i64
//!     pub fn setId(self: *User, id: i64) void
//!     pub fn getName(self: *const User) []const u8        // 可选
//!     pub fn setName(self: *User, name: []const u8) !void // 可选（与 getName 成对）
//!     pub fn getField(self: *const User, name: []const u8) ?Value
//!     pub fn setField(self: *User, name: []const u8, value: Value) !bool
//! };
//! ```
//!
//! 内存所有权：`insert`/`update` 成功时实体归库所有；**失败时由库调用 `deinit` 释放**
//! （与 Rust 版 `Drop` 语义一致）。`getField` 返回**借用**值（文本指向实体内存），
//! 索引与持久化在需要时自行复制。
//!
//! # 引用计数句柄
//!
//! 读操作返回 [`Ref`]（堆上 `Box` + 原子引用计数），可跨线程持有；
//! 实体被删除后，内存延迟到最后一次 `release` 才释放——与 Rust 版 `Arc<T>` 一致。

const std = @import("std");
const model = @import("model.zig");

pub const Field = model.Field;
pub const CompositeUniqueRule = model.CompositeUniqueRule;
pub const Value = model.Value;

/// 实体契约的编译期检查（在 `Table(T)` 实例化时执行一次）。
pub fn assertContract(comptime T: type) void {
    comptime {
        if (@typeInfo(T) != .@"struct") {
            @compileError("Pek.ZMDB 实体必须是 struct：" ++ @typeName(T));
        }
        if (!@hasDecl(T, "type_name")) {
            @compileError("实体 " ++ @typeName(T) ++ " 缺少 `pub const type_name: []const u8`");
        }
        if (!@hasDecl(T, "fields")) {
            @compileError("实体 " ++ @typeName(T) ++ " 缺少 `pub const fields`（[_]Field 或 []const Field）");
        }
        const required = [_][]const u8{
            "initEmpty",
            "deinit",
            "getId",
            "setId",
            "getField",
            "setField",
        };
        for (required) |name| {
            if (!@hasDecl(T, name)) {
                @compileError("实体 " ++ @typeName(T) ++ " 缺少 `pub fn " ++ name ++ "`（见 entity.zig 契约说明）");
            }
        }
        if (@hasDecl(T, "getName") != @hasDecl(T, "setName")) {
            @compileError("实体 " ++ @typeName(T) ++ " 的 getName/setName 必须成对声明");
        }
        if (@TypeOf(T.type_name) != []const u8 and @TypeOf(T.type_name) != *const [T.type_name.len:0]u8) {
            @compileError("实体 " ++ @typeName(T) ++ " 的 type_name 应为字符串常量");
        }
    }
}

/// 类型名（持久化文件名与表标识）。
pub fn typeName(comptime T: type) []const u8 {
    return T.type_name;
}

/// 字段清单（数组或切片声明均可）。
pub fn fieldsOf(comptime T: type) []const Field {
    const raw = T.fields;
    return switch (@typeInfo(@TypeOf(raw))) {
        .array => &T.fields,
        .pointer => |ptr| switch (ptr.size) {
            .slice => raw,
            .one => raw[0..],
            else => @compileError("实体 " ++ @typeName(T) ++ " 的 fields 必须是数组或切片"),
        },
        else => @compileError("实体 " ++ @typeName(T) ++ " 的 fields 必须是数组或切片"),
    };
}

/// 复合唯一约束清单（未声明时为空）。
pub fn compositesOf(comptime T: type) []const CompositeUniqueRule {
    if (!@hasDecl(T, "composite_uniques")) return &.{};
    const raw = T.composite_uniques;
    return switch (@typeInfo(@TypeOf(raw))) {
        .array => &T.composite_uniques,
        .pointer => |ptr| switch (ptr.size) {
            .slice => raw,
            .one => raw[0..],
            else => @compileError("实体 " ++ @typeName(T) ++ " 的 composite_uniques 必须是数组或切片"),
        },
        else => @compileError("实体 " ++ @typeName(T) ++ " 的 composite_uniques 必须是数组或切片"),
    };
}

/// 整类是否常驻内存、不落盘。
pub fn notSave(comptime T: type) bool {
    if (!@hasDecl(T, "not_save")) return false;
    return T.not_save;
}

/// 是否声明了 Name 语义。
pub fn hasName(comptime T: type) bool {
    return @hasDecl(T, "getName") and @hasDecl(T, "setName");
}

/// 读 Name（未声明时为空串）。
pub fn getName(obj: anytype) []const u8 {
    const T = Child(@TypeOf(obj));
    if (comptime hasName(T)) return obj.getName();
    return "";
}

/// 写 Name（未声明时忽略）。
pub fn setName(obj: anytype, name: []const u8) !void {
    const T = Child(@TypeOf(obj));
    if (comptime hasName(T)) try obj.setName(name);
}

fn Child(comptime P: type) type {
    return switch (@typeInfo(P)) {
        .pointer => |ptr| ptr.child,
        else => P,
    };
}

// ----------------------------------------------------------------------
// 引用计数句柄
// ----------------------------------------------------------------------

/// 实体句柄：`Box` 堆分配 + 原子引用计数（跨线程安全，删除后延迟释放）。
pub fn Ref(comptime T: type) type {
    return struct {
        const Self = @This();

        /// 堆上的实体容器（表持有一份引用，查询结果各持一份）。
        pub const Box = struct {
            refs: std.atomic.Value(u32),
            gpa: std.mem.Allocator,
            value: T,
        };

        box: *Box,

        /// 新建句柄（引用计数 = 1；所有权转移给调用方）。
        pub fn create(gpa: std.mem.Allocator, value: T) !Self {
            const box = try gpa.create(Box);
            box.* = .{
                .refs = std.atomic.Value(u32).init(1),
                .gpa = gpa,
                .value = value,
            };
            return .{ .box = box };
        }

        /// 借用实体（句柄存活期间有效）。
        pub fn get(self: Self) *const T {
            return &self.box.value;
        }

        /// 借用可变实体（仅库内部写路径使用）。
        pub fn getMut(self: Self) *T {
            return &self.box.value;
        }

        /// 增加引用（返回同一句柄，便于链式表达）。
        pub fn retain(self: Self) Self {
            _ = self.box.refs.fetchAdd(1, .monotonic);
            return self;
        }

        /// 释放引用；最后一个持有者负责 `deinit` 实体并释放 `Box`。
        pub fn release(self: Self) void {
            if (self.box.refs.fetchSub(1, .acq_rel) == 1) {
                const gpa = self.box.gpa;
                self.box.value.deinit();
                gpa.destroy(self.box);
            }
        }

        /// 引用计数（诊断/测试用）。
        pub fn refCount(self: Self) u32 {
            return self.box.refs.load(.monotonic);
        }
    };
}

/// 查询结果列表（持有若干 `Ref`；`deinit` 会释放全部引用）。
pub fn List(comptime T: type) type {
    return struct {
        const Self = @This();

        gpa: std.mem.Allocator,
        items: []Ref(T) = &.{},

        pub fn empty(gpa: std.mem.Allocator) Self {
            return .{ .gpa = gpa };
        }

        pub fn deinit(self: *Self) void {
            for (self.items) |item| item.release();
            if (self.items.len > 0) self.gpa.free(self.items);
            self.items = &.{};
        }

        pub fn len(self: Self) usize {
            return self.items.len;
        }

        pub fn isEmpty(self: Self) bool {
            return self.items.len == 0;
        }

        /// 借用第 `index` 个实体（列表存活期间有效）。
        pub fn at(self: Self, index: usize) *const T {
            return self.items[index].get();
        }

        /// 取第 `index` 个句柄（需自行 release）。
        pub fn ref(self: Self, index: usize) Ref(T) {
            return self.items[index];
        }

        /// 只读句柄切片。
        pub fn slice(self: Self) []const Ref(T) {
            return self.items;
        }
    };
}

/// 分页结果（字段口径与 C# `PagedResult<T>` / Rust 版一致）。
pub fn Page(comptime T: type) type {
    return struct {
        const Self = @This();

        items: List(T),
        page_index: usize = 0,
        page_size: usize = 0,
        total_count: usize = 0,
        total_pages: usize = 0,

        pub fn deinit(self: *Self) void {
            self.items.deinit();
        }

        pub fn len(self: Self) usize {
            return self.items.len();
        }

        pub fn at(self: Self, index: usize) *const T {
            return self.items.at(index);
        }
    };
}
