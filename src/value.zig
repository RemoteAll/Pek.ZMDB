//! 字段值归一化：`zzig.db.Value`（跨类型取值）→ 类型感知索引键 [`Key`]。
//!
//! # 复用口径（写码前已检索）
//! - 通用值模型直接用 `zzig.db.Value`（null/boolean/int/float/decimal/text/blob/datetime +
//!   `asI64`/`asF64`/`asBool`/`asDatetime`/`toTextAlloc`），本项目**不再自定义 FieldValue**；
//! - 时间用 `zzig.DateTime`（解析/格式化/Unix 换算），本项目只补「C# 落库口径」的
//!   `yyyy-MM-dd HH:mm:ss` 与「年/年月/年月日」区间；
//! - 布尔与文本比较用 `std.ascii` / `zzig.ascii`，不另写大小写折叠。
//!
//! # 与 `zzig.db.Value` 的差异（本项目补的边界）
//! - `zzig` 的 `asI64` 对浮点走 `@intFromFloat`（NaN/溢出会 panic），这里先做有限性检查；
//! - 布尔智能值扩充 `on/off/是/否`（对齐 C# `BooleanIndex` 与 Rust 版）；
//! - 整数时间戳按秒/毫秒自适应（> 1e11 视为毫秒），十进制/日期时间统一收敛到 Unix 秒。

const std = @import("std");
const zzig = @import("zzig");

/// 通用字段值（直接复用 zzig 的数据库值模型）。
pub const Value = zzig.db.Value;
/// 日期时间（复用 zzig 的 DateTime：无时区、宽容解析）。
pub const DateTime = zzig.DateTime;

/// 字段类型（决定索引策略与持久化转换）。
pub const FieldKind = enum {
    text,
    int,
    float,
    boolean,
    time,
    json,

    /// 索引类型名（与 C# `IndexStatistics.IndexType` / Rust 版口径一致）。
    pub fn indexTypeName(self: FieldKind) []const u8 {
        return switch (self) {
            .text => "StringIndex",
            .int, .float => "NumericIndex",
            .boolean => "BooleanIndex",
            .time => "DateTimeIndex",
            .json => "GenericIndex",
        };
    }
};

/// 归一化后的索引键（字符串类键 **拥有内存**，由索引负责释放）。
pub const Key = union(enum) {
    boolean: bool,
    int: i64,
    float: f64,
    /// Unix 秒（本地无时区语义，与 `DateTime.toUnixSeconds` 一致）。
    time: i64,
    /// 文本（拥有；文本索引里存的是小写形态）。
    text: []u8,

    /// 释放拥有内存（非文本键为空操作）。
    pub fn deinit(self: Key, gpa: std.mem.Allocator) void {
        switch (self) {
            .text => |t| gpa.free(t),
            else => {},
        }
    }

    /// 深拷贝（文本键重新分配）。
    pub fn clone(self: Key, gpa: std.mem.Allocator) !Key {
        return switch (self) {
            .text => |t| .{ .text = try gpa.dupe(u8, t) },
            else => self,
        };
    }

    /// 相等（浮点按位比较并把 NaN 视为相等，与 Rust 版 `total_cmp` 口径对齐）。
    pub fn eql(a: Key, b: Key) bool {
        return switch (a) {
            .boolean => |v| switch (b) {
                .boolean => |w| v == w,
                else => false,
            },
            .int => |v| switch (b) {
                .int => |w| v == w,
                else => false,
            },
            .float => |v| switch (b) {
                .float => |w| floatEql(v, w),
                else => false,
            },
            .time => |v| switch (b) {
                .time => |w| v == w,
                else => false,
            },
            .text => |v| switch (b) {
                .text => |w| std.mem.eql(u8, v, w),
                else => false,
            },
        };
    }

    /// 全序（同一索引内键类型一致；跨类型按标签顺序兜底，保证不 panic）。
    pub fn order(a: Key, b: Key) std.math.Order {
        return switch (a) {
            .boolean => |v| switch (b) {
                .boolean => |w| std.math.order(@intFromBool(v), @intFromBool(w)),
                else => .lt,
            },
            .int => |v| switch (b) {
                .int => |w| std.math.order(v, w),
                else => .lt,
            },
            .float => |v| switch (b) {
                .float => |w| floatOrder(v, w),
                else => .lt,
            },
            .time => |v| switch (b) {
                .time => |w| std.math.order(v, w),
                else => .lt,
            },
            .text => |v| switch (b) {
                .text => |w| std.mem.order(u8, v, w),
                else => .gt,
            },
        };
    }

    /// 哈希（标签参与，浮点按位并把 NaN 归一化）。
    pub fn hash(self: Key) u64 {
        var h = std.hash.Wyhash.init(0x9E37_79B9_7F4A_7C15);
        const tag: u8 = @backingInt(std.meta.activeTag(self));
        h.update(&.{tag});
        switch (self) {
            .boolean => |v| h.update(&.{@intFromBool(v)}),
            .int => |v| h.update(std.mem.asBytes(&v)),
            .float => |v| {
                const bits: u64 = if (std.math.isNan(v)) nan_bits else @bitCast(v);
                h.update(std.mem.asBytes(&bits));
            },
            .time => |v| h.update(std.mem.asBytes(&v)),
            .text => |v| h.update(v),
        }
        return h.final();
    }

    /// 规范化文本（用于错误消息/展示；调用方释放）。
    pub fn toTextAlloc(self: Key, gpa: std.mem.Allocator) ![]u8 {
        return switch (self) {
            .boolean => |v| gpa.dupe(u8, if (v) "true" else "false"),
            .int => |v| std.fmt.allocPrint(gpa, "{d}", .{v}),
            .float => |v| std.fmt.allocPrint(gpa, "{d}", .{v}),
            .time => |v| formatDateTimeAlloc(DateTime.fromUnixSeconds(v), gpa),
            .text => |v| gpa.dupe(u8, v),
        };
    }
};

/// `std.HashMap` 的键上下文（唯一索引/复合唯一索引使用）。
pub const KeyContext = struct {
    pub fn hash(_: KeyContext, key: Key) u64 {
        return key.hash();
    }
    pub fn eql(_: KeyContext, a: Key, b: Key) bool {
        return a.eql(b);
    }
};

const nan_bits: u64 = 0x7ff8_0000_0000_0000;

fn floatEql(a: f64, b: f64) bool {
    if (std.math.isNan(a) and std.math.isNan(b)) return true;
    return @as(u64, @bitCast(a)) == @as(u64, @bitCast(b));
}

fn floatOrder(a: f64, b: f64) std.math.Order {
    if (std.math.isNan(a)) return if (std.math.isNan(b)) .eq else .gt;
    if (std.math.isNan(b)) return .lt;
    if (a < b) return .lt;
    if (a > b) return .gt;
    // -0.0 < 0.0（与 Rust `total_cmp` 一致；其余相等值按位相同）
    if (a == 0 and b == 0) {
        const a_neg = std.math.signbit(a);
        const b_neg = std.math.signbit(b);
        if (a_neg == b_neg) return .eq;
        return if (a_neg) .lt else .gt;
    }
    return .eq;
}

// ----------------------------------------------------------------------
// Value → 基础类型（跨类型宽松转换）
// ----------------------------------------------------------------------

/// 是否空值。
pub fn isNull(value: Value) bool {
    return value == .null;
}

/// 转整数：浮点先做有限性/范围检查（zzig 的 `asI64` 对 NaN 会 panic）。
pub fn toI64(value: Value) ?i64 {
    return switch (value) {
        .float => |v| floatToI64(v),
        .datetime => |dt| dt.toUnixSeconds(),
        .decimal => |d| d.toI64(),
        else => value.asI64(),
    };
}

fn floatToI64(v: f64) ?i64 {
    if (!std.math.isFinite(v)) return null;
    if (v < -9.223_372_036_854_775e18 or v > 9.223_372_036_854_775e18) return null;
    return @intFromFloat(v);
}

/// 转浮点。
pub fn toF64(value: Value) ?f64 {
    return switch (value) {
        .datetime => |dt| @floatFromInt(dt.toUnixSeconds()),
        else => value.asF64(),
    };
}

/// 转布尔（智能值：true/1/yes/on/是、false/0/no/off/否）。
pub fn toBool(value: Value) ?bool {
    switch (value) {
        .text => |t| {
            const s = std.mem.trim(u8, t, " \t\r\n");
            if (std.ascii.eqlIgnoreCase(s, "on") or std.mem.eql(u8, s, "是")) return true;
            if (std.ascii.eqlIgnoreCase(s, "off") or std.mem.eql(u8, s, "否")) return false;
            return value.asBool();
        },
        else => return value.asBool(),
    }
}

/// 转日期时间（文本宽容解析；整数按秒/毫秒自适应）。
pub fn toDateTime(value: Value) ?DateTime {
    return switch (value) {
        .datetime => |dt| dt,
        .text => |t| DateTime.parse(t) catch null,
        .int => |v| datetimeFromTimestamp(v),
        .float => |v| if (std.math.isFinite(v)) datetimeFromTimestamp(@intFromFloat(v)) else null,
        .decimal => |d| if (d.toI64()) |number| datetimeFromTimestamp(number) else null,
        else => null,
    };
}

fn datetimeFromTimestamp(v: i64) DateTime {
    // 毫秒时间戳（> 1e11）自动降到秒，容忍 C# `DateTime.Ticks` 之外的常见写法
    if (v > 100_000_000_000 or v < -100_000_000_000) {
        return DateTime.fromUnixSeconds(@divFloor(v, 1000));
    }
    return DateTime.fromUnixSeconds(v);
}

/// 文本化（Text 原样；数值/布尔/时间按 C# 口径转字符串；null → null）。
///
/// 错误集归一为 `error{OutOfMemory}`：`zzig.db.Value.toTextAlloc` 的推断错误集里
/// 还含 Writer 相关错误（如 `NoSpaceLeft`），对内存分配失败而言语义等价。
pub fn toTextAlloc(value: Value, gpa: std.mem.Allocator) error{OutOfMemory}!?[]u8 {
    return switch (value) {
        .null => null,
        .text => |t| try gpa.dupe(u8, t),
        .blob => |b| try gpa.dupe(u8, b),
        .datetime => |dt| try formatDateTimeAlloc(dt, gpa),
        else => value.toTextAlloc(gpa) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.OutOfMemory,
        },
    };
}

// ----------------------------------------------------------------------
// 规范化（建索引/查询前调用）
// ----------------------------------------------------------------------

/// 按字段类型把值规范化为索引键。
///
/// 返回 `null` 表示该值无法作为该字段的索引键（空值、无法解析的文本），
/// 调用方应跳过建索引或返回空结果。返回的 [`Key`] **拥有内存**，由调用方释放。
pub fn normalize(value: Value, kind: FieldKind, gpa: std.mem.Allocator) error{OutOfMemory}!?Key {
    switch (kind) {
        .text => {
            if (try toTextAlloc(value, gpa)) |text| return Key{ .text = text };
            return null;
        },
        .int => {
            if (toI64(value)) |v| return Key{ .int = v };
            return null;
        },
        .float => {
            if (toF64(value)) |v| return Key{ .float = v };
            return null;
        },
        .boolean => {
            if (toBool(value)) |v| return Key{ .boolean = v };
            return null;
        },
        .time => {
            if (toDateTime(value)) |dt| return Key{ .time = dt.toUnixSeconds() };
            return null;
        },
        .json => {
            if (try toTextAlloc(value, gpa)) |text| return Key{ .text = text };
            return null;
        },
    }
}

/// 布尔模式（`find_by_like` 智能值；无法识别返回 null）。
pub fn parseBoolPattern(pattern: []const u8) ?bool {
    const s = std.mem.trim(u8, pattern, " \t\r\n");
    if (std.ascii.eqlIgnoreCase(s, "true") or std.mem.eql(u8, s, "1") or
        std.ascii.eqlIgnoreCase(s, "yes") or std.ascii.eqlIgnoreCase(s, "on") or
        std.mem.eql(u8, s, "是"))
    {
        return true;
    }
    if (std.ascii.eqlIgnoreCase(s, "false") or std.mem.eql(u8, s, "0") or
        std.ascii.eqlIgnoreCase(s, "no") or std.ascii.eqlIgnoreCase(s, "off") or
        std.mem.eql(u8, s, "否"))
    {
        return false;
    }
    return null;
}

// ----------------------------------------------------------------------
// 时间文本（C# 落库口径 `yyyy-MM-dd HH:mm:ss`）
// ----------------------------------------------------------------------

/// 时间区间（Unix 秒，闭区间）。
pub const TimeRange = struct {
    start: i64,
    end: i64,
};

/// 写入 `YYYY-MM-DD HH:MM:SS`（19 字节；手写补零，规避 0.17 `{d:0>4}` 输出 `+2024` 的坑）。
pub fn formatDateTime(dt: DateTime, buf: []u8) []const u8 {
    std.debug.assert(buf.len >= 19);
    putPadded(buf[0..4], yearValue(dt.year));
    buf[4] = '-';
    putPadded(buf[5..7], dt.month);
    buf[7] = '-';
    putPadded(buf[8..10], dt.day);
    buf[10] = ' ';
    putPadded(buf[11..13], dt.hour);
    buf[13] = ':';
    putPadded(buf[14..16], dt.minute);
    buf[16] = ':';
    putPadded(buf[17..19], dt.second);
    return buf[0..19];
}

fn yearValue(year: i32) u32 {
    if (year <= 0) return 0;
    return @intCast(@min(year, 9999));
}

fn putPadded(out: []u8, value: u32) void {
    var rest = value;
    var i: usize = out.len;
    while (i > 0) {
        i -= 1;
        out[i] = '0' + @as(u8, @intCast(rest % 10));
        rest /= 10;
    }
}

/// 分配 `YYYY-MM-DD HH:MM:SS`。
pub fn formatDateTimeAlloc(dt: DateTime, gpa: std.mem.Allocator) error{OutOfMemory}![]u8 {
    var buf: [19]u8 = undefined;
    return gpa.dupe(u8, formatDateTime(dt, &buf));
}

/// 时间模式（年 / 年月 / 年月日）→ 闭区间；不是日期模式返回 null。
///
/// 支持的写法：`2024`、`2024-01`、`2024/01`、`2024-01-05`、`2024/1/5`。
pub fn dateRangeOf(pattern: []const u8) ?TimeRange {
    const text = std.mem.trim(u8, pattern, " \t\r\n");
    const parts = splitDate(text) orelse return null;

    const year = parts.year;
    if (year < 1 or year > 9999) return null;

    const month: u8 = parts.month orelse 1;
    const day: u8 = parts.day orelse 1;
    if (month < 1 or month > 12) return null;
    if (day < 1 or day > daysInMonth(year, month)) return null;

    const start_dt = DateTime{ .year = year, .month = month, .day = day };
    const start = start_dt.toUnixSeconds();
    const end = if (parts.day != null)
        start + 86_399
    else if (parts.month != null) blk: {
        const next = if (month == 12)
            DateTime{ .year = year + 1, .month = 1, .day = 1 }
        else
            DateTime{ .year = year, .month = month + 1, .day = 1 };
        break :blk next.toUnixSeconds() - 1;
    } else blk: {
        const next = DateTime{ .year = year + 1, .month = 1, .day = 1 };
        break :blk next.toUnixSeconds() - 1;
    };
    return .{ .start = start, .end = end };
}

const DateParts = struct {
    year: i32,
    month: ?u8 = null,
    day: ?u8 = null,
};

fn splitDate(text: []const u8) ?DateParts {
    var parts: DateParts = .{ .year = 0 };
    var index: usize = 0;

    const year = readDigits(text, &index, 4) orelse return null;
    parts.year = @intCast(year);
    if (index == text.len) return parts;

    if (text[index] != '-' and text[index] != '/') return null;
    index += 1;
    const month = readDigits(text, &index, 2) orelse return null;
    parts.month = @intCast(month);
    if (index == text.len) return parts;

    if (text[index] != '-' and text[index] != '/') return null;
    index += 1;
    const day = readDigits(text, &index, 2) orelse return null;
    parts.day = @intCast(day);
    if (index != text.len) return null;
    return parts;
}

fn readDigits(text: []const u8, index: *usize, max: usize) ?u32 {
    var value: u32 = 0;
    var count: usize = 0;
    while (index.* < text.len and count < max) : (count += 1) {
        const c = text[index.*];
        if (c < '0' or c > '9') break;
        value = value * 10 + (c - '0');
        index.* += 1;
    }
    if (count == 0) return null;
    return value;
}

fn daysInMonth(year: i32, month: u8) u8 {
    return switch (month) {
        1, 3, 5, 7, 8, 10, 12 => 31,
        4, 6, 9, 11 => 30,
        2 => if (isLeapYear(year)) 29 else 28,
        else => 0,
    };
}

fn isLeapYear(year: i32) bool {
    return (@mod(year, 4) == 0 and @mod(year, 100) != 0) or @mod(year, 400) == 0;
}

// ----------------------------------------------------------------------
// 测试
// ----------------------------------------------------------------------

const testing = std.testing;

test "归一化：文本/整数/布尔/时间/JSON" {
    const gpa = testing.allocator;

    const text_key = (try normalize(.{ .text = "abc" }, .text, gpa)).?;
    defer text_key.deinit(gpa);
    try testing.expectEqualStrings("abc", text_key.text);

    const int_from_text = (try normalize(.{ .text = "42" }, .int, gpa)).?;
    try testing.expectEqual(@as(i64, 42), int_from_text.int);

    // NaN 不 panic（zzig 的 asI64 会 @intFromFloat panic，这里已兜住）
    try testing.expect((try normalize(.{ .float = std.math.nan(f64) }, .int, gpa)) == null);

    const bool_on = (try normalize(.{ .text = "ON" }, .boolean, gpa)).?;
    try testing.expectEqual(true, bool_on.boolean);
    const bool_no = (try normalize(.{ .text = "否" }, .boolean, gpa)).?;
    try testing.expectEqual(false, bool_no.boolean);

    const time_key = (try normalize(.{ .text = "2024/1/5 14:30:00" }, .time, gpa)).?;
    try testing.expectEqual(
        (DateTime{ .year = 2024, .month = 1, .day = 5, .hour = 14, .minute = 30 }).toUnixSeconds(),
        time_key.time,
    );

    const json_key = (try normalize(.{ .text = "[ \"a\", \"b\" ]" }, .json, gpa)).?;
    defer json_key.deinit(gpa);
    try testing.expectEqualStrings("[ \"a\", \"b\" ]", json_key.text);

    try testing.expect((try normalize(.{ .null = {} }, .text, gpa)) == null);
}

test "时间文本与日期区间" {
    var buf: [19]u8 = undefined;
    const dt = DateTime{ .year = 2024, .month = 1, .day = 5, .hour = 8, .minute = 30, .second = 2 };
    try testing.expectEqualStrings("2024-01-05 08:30:02", formatDateTime(dt, &buf));

    const year = dateRangeOf("2024").?;
    try testing.expectEqual((DateTime{ .year = 2024, .month = 1, .day = 1 }).toUnixSeconds(), year.start);
    try testing.expectEqual((DateTime{ .year = 2025, .month = 1, .day = 1 }).toUnixSeconds() - 1, year.end);

    const day = dateRangeOf("2024-01-05").?;
    try testing.expectEqual(dt.toUnixSeconds() - 8 * 3600 - 30 * 60 - 2, day.start);
    try testing.expectEqual(day.start + 86_399, day.end);

    try testing.expect(dateRangeOf("2024-13") == null);
    try testing.expect(dateRangeOf("abc") == null);
}

test "键排序与哈希" {
    const a = Key{ .int = 1 };
    const b = Key{ .int = 2 };
    try testing.expectEqual(std.math.Order.lt, a.order(b));
    try testing.expect(!a.eql(b));
    try testing.expectEqual(a.hash(), (Key{ .int = 1 }).hash());

    try testing.expect(floatEql(std.math.nan(f64), std.math.nan(f64)));
    try testing.expectEqual(std.math.Order.lt, floatOrder(-0.0, 0.0));
}
