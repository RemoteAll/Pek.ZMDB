//! 实体模型描述：字段元数据、唯一约束、统计结构与分页结构。
//!
//! Zig 没有运行时反射，实体通过**契约**显式描述（见 `entity.zig` 的说明）：
//! - `pub const fields`：字段清单（名称/类型/是否建索引/是否持久化/单字段唯一约束）；
//! - `pub const composite_uniques`：类级复合唯一约束（对应 C# `[CompositeUnique]`）；
//! - `getField` / `setField`：按字段名读写（通常一个 `switch` 即可）。
//!
//! 字段名建议 **PascalCase**，与 C# 属性名保持一致，便于直接读写 C# 版 `Data/*.json`。

const std = @import("std");
pub const value = @import("value.zig");

pub const FieldKind = value.FieldKind;
pub const Value = value.Value;

/// 单字段唯一约束（对应 C# `[Unique(ErrorMessage, AllowNull)]`）。
pub const UniqueRule = struct {
    /// 冲突时的业务错误消息（静态）。
    message: []const u8,
    /// 是否允许空值（默认允许；不允许时空值也视为冲突）。
    allow_null: bool = true,
};

/// 复合字段唯一约束（对应 C# `[CompositeUnique(group, fields...)]`）。
pub const CompositeUniqueRule = struct {
    /// 约束组名（同类型多个复合约束时用于区分索引）。
    group: []const u8,
    /// 参与约束的字段名（至少 2 个）。
    fields: []const []const u8,
    /// 冲突时的业务错误消息（静态）。
    message: []const u8,
    /// 组合中包含空值时是否允许（默认允许）。
    allow_null: bool = true,

    /// 创建复合唯一约束（允许空值，系统默认）。
    pub fn init(group: []const u8, fields: []const []const u8, message: []const u8) CompositeUniqueRule {
        return .{ .group = group, .fields = fields, .message = message };
    }

    /// 创建复合唯一约束（含空值即视为冲突）。
    pub fn required(group: []const u8, fields: []const []const u8, message: []const u8) CompositeUniqueRule {
        return .{ .group = group, .fields = fields, .message = message, .allow_null = false };
    }
};

/// 字段元数据（可直接放进 `pub const fields = [_]Field{ ... }`，零运行时初始化）。
pub const Field = struct {
    /// 字段名（建议 PascalCase，与 C# 属性名一致）。
    name: []const u8,
    /// 字段类型（决定索引策略）。
    kind: FieldKind,
    /// 是否建立普通索引（默认 `true`；对应 C# `[NotIndexed]` 时置 `false`）。
    indexed: bool = true,
    /// 是否持久化（默认 `true`；对应 C# `[NotSave]` 时置 `false`）。
    save: bool = true,
    /// 单字段唯一约束。
    unique: ?UniqueRule = null,

    pub fn init(name: []const u8, kind: FieldKind) Field {
        return .{ .name = name, .kind = kind };
    }

    pub fn text(name: []const u8) Field {
        return init(name, .text);
    }

    pub fn int(name: []const u8) Field {
        return init(name, .int);
    }

    pub fn float(name: []const u8) Field {
        return init(name, .float);
    }

    pub fn boolean(name: []const u8) Field {
        return init(name, .boolean);
    }

    pub fn time(name: []const u8) Field {
        return init(name, .time);
    }

    pub fn json(name: []const u8) Field {
        return init(name, .json);
    }

    /// 添加单字段唯一约束（允许空值）。
    pub fn withUnique(self: Field, message: []const u8) Field {
        var field = self;
        field.unique = .{ .message = message, .allow_null = true };
        return field;
    }

    /// 添加单字段唯一约束（不允许空值）。
    pub fn withUniqueRequired(self: Field, message: []const u8) Field {
        var field = self;
        field.unique = .{ .message = message, .allow_null = false };
        return field;
    }

    /// 不建立普通索引（大文本/低频查询字段）。
    pub fn notIndexed(self: Field) Field {
        var field = self;
        field.indexed = false;
        return field;
    }

    /// 不持久化（运行时缓存字段）。
    pub fn notSave(self: Field) Field {
        var field = self;
        field.save = false;
        return field;
    }
};

/// 单个索引的统计信息（对应 C# `IndexStatistics`）。
pub const IndexStatistics = struct {
    /// 字段名（借用静态字段名，无需释放）。
    property_name: []const u8,
    /// 索引类型（`StringIndex` / `NumericIndex` / `BooleanIndex` / `DateTimeIndex` / `GenericIndex`）。
    index_type: []const u8,
    /// 查询次数。
    query_count: u64,
    /// 命中次数。
    hit_count: u64,
    /// 唯一值数量。
    unique_value_count: usize,
    /// 索引中的 ID 总数（含重复值对应的多行）。
    id_count: usize,

    /// 命中率（0~1）。
    pub fn hitRate(self: IndexStatistics) f64 {
        if (self.query_count == 0) return 0;
        return @as(f64, @floatFromInt(self.hit_count)) / @as(f64, @floatFromInt(self.query_count));
    }
};

/// 单表统计信息（`indexes` 为分配切片，用 [`TableStatistics.deinit`] 释放）。
pub const TableStatistics = struct {
    /// 类型名（借用静态 `T.type_name`）。
    type_name: []const u8,
    /// 当前行数。
    rows: usize,
    /// 索引统计。
    indexes: []IndexStatistics = &.{},
    /// 单字段唯一约束数量。
    unique_fields: usize = 0,
    /// 复合唯一约束数量。
    unique_composites: usize = 0,
    /// 持久化次数。
    persist_count: u64 = 0,
    /// 累计写盘字节数。
    persisted_bytes: u64 = 0,
    /// 最近一次持久化耗时（毫秒）。
    last_persist_ms: u64 = 0,
    /// 是否常驻内存（不落盘）。
    in_memory: bool = false,

    pub fn deinit(self: *TableStatistics, gpa: std.mem.Allocator) void {
        if (self.indexes.len > 0) gpa.free(self.indexes);
        self.indexes = &.{};
    }
};

/// 全库统计信息（`tables` 为分配切片，用 [`DbStatistics.deinit`] 释放）。
pub const DbStatistics = struct {
    /// 各表统计（按类型名排序）。
    tables: []TableStatistics = &.{},
    /// 表总数。
    table_count: usize = 0,
    /// 行数合计。
    total_rows: usize = 0,

    pub fn deinit(self: *DbStatistics, gpa: std.mem.Allocator) void {
        for (self.tables) |*table| table.deinit(gpa);
        if (self.tables.len > 0) gpa.free(self.tables);
        self.tables = &.{};
        self.table_count = 0;
        self.total_rows = 0;
    }
};

/// 多条件查询条件（`findByMultiple`）。
pub const Condition = struct {
    field: []const u8,
    value: Value,
};

/// 唯一约束冲突的类型（对齐 C# `UniqueConstraintViolationException.ConstraintType`）。
pub const ConstraintType = enum {
    single,
    composite,

    pub fn asStr(self: ConstraintType) []const u8 {
        return switch (self) {
            .single => "Single",
            .composite => "Composite",
        };
    }
};

/// 唯一约束冲突的细节（`insert`/`update` 的可选出参）。
///
/// 为什么不是错误负载：Zig 的错误码不能携带数据。调用方把 `Violation` 传进来，
/// 冲突时由库回填字段；不关心细节时传 `null` 即可。
pub const Violation = struct {
    /// 违反约束的字段名（单字段约束）或约束组名（复合约束）。
    property_name: []const u8 = "",
    /// 复合约束的参与字段（单字段约束为空）。
    fields: []const []const u8 = &.{},
    /// 约束类型。
    constraint_type: ConstraintType = .single,
    /// 冲突细节：重复值 / 不允许空值。
    detail: Detail = .duplicate,
    /// 冲突对象 ID（复合约束或"值为空"时可能未知）。
    conflicting_id: ?i64 = null,
    /// 业务错误消息（来自 `Field.withUnique` / `CompositeUniqueRule.message`，静态）。
    message: []const u8 = "",

    pub const Detail = enum {
        /// 值重复。
        duplicate,
        /// 值不允许为空。
        null_not_allowed,
    };
};

const testing = std.testing;

test "字段构造器链" {
    const field = Field.text("Username").withUnique("用户名已存在").notIndexed().notSave();
    try testing.expectEqualStrings("Username", field.name);
    try testing.expectEqual(FieldKind.text, field.kind);
    try testing.expect(!field.indexed);
    try testing.expect(!field.save);
    try testing.expectEqualStrings("用户名已存在", field.unique.?.message);
    try testing.expect(field.unique.?.allow_null);

    const required = Field.text("Email").withUniqueRequired("邮箱已被注册");
    try testing.expect(!required.unique.?.allow_null);
}
