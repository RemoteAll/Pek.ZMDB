//! 实体 JSON 序列化与反序列化（持久化格式，与 C# `SimpleJsonString` 双向兼容）。
//!
//! # 复用口径（写码前已检索）
//! - 值树用 `zzig.web.Value`（对象/数组/标量 + `get`/`jsonAlloc`），本项目不另造值模型；
//! - 不用 `zzig.json.Jsmn`：JSMN 要求键必须带引号，而 C# `SimpleJsonString` 写的是**裸键**
//!   （`{ Id:1, Name:"x" }`），且历史文件里可能有 `//` 注释 —— 这里只补一层**宽容词法**
//!   （裸键 / 行注释 / 尾逗号 / 大小写关键字），产出的仍是 `zzig.web.Value` 树；
//! - 字符串缓冲用 `zzig.Buf`（`std.Io.Writer.Allocating`）。
//!
//! # 写出口径（对齐 C# `JsonString.ClearNewLine`）
//! - 只转义 `\` 与 `"`，`\r`/`\n`/`\t` **直接去掉**（C# 行为，不是标准 JSON 转义）；
//! - 浮点整数值不带 `.0`；非有限值写成字符串 `"NaN"` / `"Infinity"` / `"-Infinity"`。

const std = @import("std");
const zzig = @import("zzig");

const value = @import("value.zig");

pub const Node = zzig.web.Value;
pub const Field = zzig.web.Field;
pub const Value = value.Value;
pub const FieldKind = value.FieldKind;

pub const ParseError = error{ InvalidJson, OutOfMemory };

const max_depth = 64;

/// 宽松 JSON 解析（C# `JsonParser` / `SimpleJsonString` 兼容）。
///
/// 支持：裸键与带引号键、`//` 行注释、尾逗号、大小写不敏感关键字、`\uXXXX` 与代理对。
/// 所有分配走 `arena`（字符串、数组、对象）。
pub fn parseLax(arena: std.mem.Allocator, text: []const u8) ParseError!Node {
    var parser = Parser{ .src = text, .arena = arena };
    parser.skipSpace();
    const node = try parser.parseValue(0);
    parser.skipSpace();
    if (parser.pos != text.len) return error.InvalidJson;
    return node;
}

const Parser = struct {
    src: []const u8,
    pos: usize = 0,
    arena: std.mem.Allocator,

    fn peek(self: *Parser) ?u8 {
        return if (self.pos < self.src.len) self.src[self.pos] else null;
    }

    fn skipSpace(self: *Parser) void {
        while (self.pos < self.src.len) {
            switch (self.src[self.pos]) {
                ' ', '\t', '\r', '\n' => self.pos += 1,
                '/' => {
                    // `//` 行注释（对齐 C# `CharSource.clearComment`）
                    if (self.pos + 1 < self.src.len and self.src[self.pos + 1] == '/') {
                        while (self.pos < self.src.len and self.src[self.pos] != '\n') self.pos += 1;
                    } else return;
                },
                else => return,
            }
        }
    }

    fn parseValue(self: *Parser, depth: usize) ParseError!Node {
        if (depth > max_depth) return error.InvalidJson;
        self.skipSpace();
        const c = self.peek() orelse return error.InvalidJson;
        return switch (c) {
            '{' => self.parseObject(depth),
            '[' => self.parseArray(depth),
            '"' => .{ .string = try self.parseString() },
            't', 'T' => self.parseKeyword("true", .{ .boolean = true }),
            'f', 'F' => self.parseKeyword("false", .{ .boolean = false }),
            'n', 'N' => self.parseKeyword("null", .{ .null = {} }),
            '-', '0'...'9' => self.parseNumber(),
            else => error.InvalidJson,
        };
    }

    fn parseKeyword(self: *Parser, keyword: []const u8, result: Node) ParseError!Node {
        if (self.src.len < self.pos + keyword.len) return error.InvalidJson;
        if (!std.ascii.eqlIgnoreCase(self.src[self.pos .. self.pos + keyword.len], keyword)) {
            return error.InvalidJson;
        }
        self.pos += keyword.len;
        return result;
    }

    fn parseObject(self: *Parser, depth: usize) ParseError!Node {
        self.pos += 1; // '{'
        var fields: std.ArrayList(Field) = .empty;
        errdefer fields.deinit(self.arena);

        self.skipSpace();
        if (self.peek() == '}') {
            self.pos += 1;
            return .{ .object = try fields.toOwnedSlice(self.arena) };
        }
        while (true) {
            self.skipSpace();
            const name = try self.parseKey();
            self.skipSpace();
            if (self.peek() != ':') return error.InvalidJson;
            self.pos += 1;
            const item = try self.parseValue(depth + 1);
            try fields.append(self.arena, .{ .name = name, .value = item });

            self.skipSpace();
            const c = self.peek() orelse return error.InvalidJson;
            if (c == ',') {
                self.pos += 1;
                self.skipSpace();
                // 容忍尾逗号
                if (self.peek() == '}') {
                    self.pos += 1;
                    return .{ .object = try fields.toOwnedSlice(self.arena) };
                }
                continue;
            }
            if (c == '}') {
                self.pos += 1;
                return .{ .object = try fields.toOwnedSlice(self.arena) };
            }
            return error.InvalidJson;
        }
    }

    /// 对象键：带引号（标准 JSON）或裸键（C# `SimpleJsonString`）。
    fn parseKey(self: *Parser) ParseError![]const u8 {
        if (self.peek() == '"') return self.parseString();
        const start = self.pos;
        while (self.pos < self.src.len) : (self.pos += 1) {
            switch (self.src[self.pos]) {
                ':', ',', '}', '{', ' ', '\t', '\r', '\n' => break,
                else => {},
            }
        }
        if (start == self.pos) return error.InvalidJson;
        return self.src[start..self.pos];
    }

    fn parseArray(self: *Parser, depth: usize) ParseError!Node {
        self.pos += 1; // '['
        var items: std.ArrayList(Node) = .empty;
        errdefer items.deinit(self.arena);

        self.skipSpace();
        if (self.peek() == ']') {
            self.pos += 1;
            return .{ .list = try items.toOwnedSlice(self.arena) };
        }
        while (true) {
            const item = try self.parseValue(depth + 1);
            try items.append(self.arena, item);

            self.skipSpace();
            const c = self.peek() orelse return error.InvalidJson;
            if (c == ',') {
                self.pos += 1;
                self.skipSpace();
                // 容忍尾逗号
                if (self.peek() == ']') {
                    self.pos += 1;
                    return .{ .list = try items.toOwnedSlice(self.arena) };
                }
                continue;
            }
            if (c == ']') {
                self.pos += 1;
                return .{ .list = try items.toOwnedSlice(self.arena) };
            }
            return error.InvalidJson;
        }
    }

    fn parseString(self: *Parser) ParseError![]const u8 {
        self.pos += 1; // '"'
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(self.arena);

        while (true) {
            const c = self.peek() orelse return error.InvalidJson;
            self.pos += 1;
            switch (c) {
                '"' => return out.toOwnedSlice(self.arena),
                '\\' => {
                    const esc = self.peek() orelse return error.InvalidJson;
                    self.pos += 1;
                    switch (esc) {
                        '"' => try out.append(self.arena, '"'),
                        '\\' => try out.append(self.arena, '\\'),
                        '/' => try out.append(self.arena, '/'),
                        'b' => try out.append(self.arena, 0x08),
                        'f' => try out.append(self.arena, 0x0C),
                        'n' => try out.append(self.arena, '\n'),
                        'r' => try out.append(self.arena, '\r'),
                        't' => try out.append(self.arena, '\t'),
                        'u' => {
                            var codepoint: u21 = try self.parseHex4();
                            if (codepoint >= 0xD800 and codepoint <= 0xDBFF) {
                                if (self.src.len < self.pos + 6) return error.InvalidJson;
                                if (self.src[self.pos] != '\\' or self.src[self.pos + 1] != 'u') {
                                    return error.InvalidJson;
                                }
                                self.pos += 2;
                                const second = try self.parseHex4();
                                if (second < 0xDC00 or second > 0xDFFF) return error.InvalidJson;
                                codepoint = 0x10000 +
                                    (@as(u21, codepoint - 0xD800) << 10) + (second - 0xDC00);
                            }
                            var buf: [4]u8 = undefined;
                            const size = std.unicode.utf8Encode(codepoint, &buf) catch return error.InvalidJson;
                            try out.appendSlice(self.arena, buf[0..size]);
                        },
                        else => return error.InvalidJson,
                    }
                },
                else => try out.append(self.arena, c),
            }
        }
    }

    fn parseHex4(self: *Parser) ParseError!u16 {
        if (self.src.len < self.pos + 4) return error.InvalidJson;
        var result: u16 = 0;
        for (self.src[self.pos .. self.pos + 4]) |c| {
            const digit: u16 = switch (c) {
                '0'...'9' => c - '0',
                'a'...'f' => c - 'a' + 10,
                'A'...'F' => c - 'A' + 10,
                else => return error.InvalidJson,
            };
            result = result * 16 + digit;
        }
        self.pos += 4;
        return result;
    }

    fn parseNumber(self: *Parser) ParseError!Node {
        const start = self.pos;
        var is_float = false;
        if (self.peek() == '-' or self.peek() == '+') self.pos += 1;
        while (self.pos < self.src.len) : (self.pos += 1) {
            switch (self.src[self.pos]) {
                '0'...'9' => {},
                '.', 'e', 'E' => is_float = true,
                '+', '-' => {
                    // 指数符号
                },
                else => break,
            }
        }
        const text = self.src[start..self.pos];
        if (text.len == 0) return error.InvalidJson;
        if (!is_float) {
            if (std.fmt.parseInt(i64, text, 10)) |number| {
                return .{ .integer = number };
            } else |_| {}
        }
        const float = std.fmt.parseFloat(f64, text) catch return error.InvalidJson;
        return .{ .number = float };
    }
};

// ----------------------------------------------------------------------
// 序列化（C# 口径）
// ----------------------------------------------------------------------

/// 写 JSON 字符串（C# `JsonString.ClearNewLine`：只转义 `\` 与 `"`，去掉 `\r\n\t`）。
pub fn writeQuoted(writer: *std.Io.Writer, text: []const u8) !void {
    try writer.writeByte('"');
    for (text) |c| switch (c) {
        '\\' => try writer.writeAll("\\\\"),
        '"' => try writer.writeAll("\\\""),
        '\r', '\n', '\t' => {},
        else => try writer.writeByte(c),
    };
    try writer.writeByte('"');
}

/// 写浮点（C# `double.ToString()` 口径：整数值不带 `.0`，非有限值写成字符串）。
fn writeNumber(writer: *std.Io.Writer, number: f64) !void {
    if (std.math.isNan(number)) return writeQuoted(writer, "NaN");
    if (std.math.isInf(number)) {
        return writeQuoted(writer, if (number > 0) "Infinity" else "-Infinity");
    }
    if (number == @trunc(number) and @abs(number) < 1e15) {
        return writer.print("{d}", .{@as(i64, @intFromFloat(number))});
    }
    return writer.print("{d}", .{number});
}

/// 写字段值（`kind == .json` 且文本形如对象/数组时按原始 JSON 写出，保持嵌套结构）。
pub fn writeValue(gpa: std.mem.Allocator, writer: *std.Io.Writer, field_value: Value, kind: FieldKind) !void {
    switch (field_value) {
        .null => try writer.writeAll("null"),
        .boolean => |flag| try writer.writeAll(if (flag) "true" else "false"),
        .int => |number| try writer.print("{d}", .{number}),
        .float => |number| try writeNumber(writer, number),
        .decimal => |decimal| {
            const text = try decimal.formatAlloc(gpa);
            defer gpa.free(text);
            try writer.writeAll(text);
        },
        .text => |text| {
            if (kind == .json and looksLikeJson(text)) {
                try writer.writeAll(text);
            } else {
                try writeQuoted(writer, text);
            }
        },
        .blob => |bytes| try writeQuoted(writer, bytes),
        .datetime => |dt| {
            var buf: [19]u8 = undefined;
            try writeQuoted(writer, value.formatDateTime(dt, &buf));
        },
    }
}

fn looksLikeJson(text: []const u8) bool {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0) return false;
    return trimmed[0] == '[' or trimmed[0] == '{';
}

/// 解析树节点 → 通用值（列表/对象序列化为 JSON 文本，便于 `setField` 落库）。
///
/// 文本借用 `arena`，调用方实体按自身所有权复制。
pub fn nodeToValue(node: Node, arena: std.mem.Allocator) ParseError!Value {
    return switch (node) {
        .null => .{ .null = {} },
        .boolean => |flag| .{ .boolean = flag },
        .integer => |number| .{ .int = number },
        .number => |number| .{ .float = number },
        .string => |text| .{ .text = text },
        .list, .object => .{ .text = node.jsonAlloc(arena) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.OutOfMemory,
        } },
    };
}

// ----------------------------------------------------------------------
// 测试
// ----------------------------------------------------------------------

const testing = std.testing;

test "宽松解析：裸键 + 注释 + 尾逗号 + 斜杠日期" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    const text =
        "// 注释行\n" ++
        "[\n" ++
        "\t{ Id:7, Name:\"老数据\", Age:30, Enabled:true, Tags:[ \"a\", \"b\", ], CreateTime:\"2024/1/5 14:30:00\" },\n" ++
        "]\n";
    const node = try parseLax(gpa, text);
    try testing.expect(node == .list);
    const first = node.list[0];
    try testing.expectEqual(@as(i64, 7), first.get("Id").?.integer);
    try testing.expectEqualStrings("老数据", first.get("Name").?.string);
    try testing.expectEqual(true, first.get("Enabled").?.boolean);
    try testing.expectEqualStrings("2024/1/5 14:30:00", first.get("CreateTime").?.string);
    try testing.expectEqual(@as(usize, 2), first.get("Tags").?.list.len);
}

test "宽松解析：转义与代理对" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const node = try parseLax(arena.allocator(), "{\"a\":\"line\\nquote\\\" tab\\t\",\"b\":\"\\u4e2d\\u6587\"}");
    try testing.expectEqualStrings("line\nquote\" tab\t", node.get("a").?.string);
    try testing.expectEqualStrings("中文", node.get("b").?.string);
}

test "宽松解析：错误输入" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(error.InvalidJson, parseLax(arena.allocator(), "{ Id: }"));
    try testing.expectError(error.InvalidJson, parseLax(arena.allocator(), "[1,2"));
    try testing.expectError(error.InvalidJson, parseLax(arena.allocator(), "123abc"));
}

test "写出口径：转义与浮点" {
    var buf: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();

    try writeQuoted(&buf.writer, "a\"b\\c\r\n\t");
    try testing.expectEqualStrings("\"a\\\"b\\\\c\"", buf.written());
}

test "写值：JSON 字段原样、普通文本转义" {
    var buf: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();

    try writeValue(testing.allocator, &buf.writer, .{ .text = "[ \"a\", \"b\" ]" }, .json);
    try testing.expectEqualStrings("[ \"a\", \"b\" ]", buf.written());

    buf.clearRetainingCapacity();
    try writeValue(testing.allocator, &buf.writer, .{ .text = "plain" }, .json);
    try testing.expectEqualStrings("\"plain\"", buf.written());

    buf.clearRetainingCapacity();
    try writeValue(testing.allocator, &buf.writer, .{ .datetime = .{ .year = 2024, .month = 1, .day = 5, .hour = 8, .minute = 30 } }, .time);
    try testing.expectEqualStrings("\"2024-01-05 08:30:00\"", buf.written());
}
