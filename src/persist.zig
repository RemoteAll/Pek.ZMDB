//! 持久化调度与路径工具（**变化驱动 + 写合并 + 原子替换**）。
//!
//! 设计目标（对齐用户「资源与带宽」偏好）：
//! - **变化驱动**：只有标记为脏的表才会被写盘，空闲时后台线程在条件变量上无限等待（零轮询）；
//! - **写合并**：`min_write_interval_ms`（默认 500ms）内的多次修改合并为一次序列化 + 一次写盘；
//! - **原子替换**：复用 `zzig.fsio.writeFileAtomic`（临时文件 + 替换，已在生态里验证）；
//! - **不丢尾写**：写盘开始时「取走」脏标记，写入期间的新修改会重新置脏并在下一轮补写。

const std = @import("std");
const zzig = @import("zzig");

/// 后台写盘调度原语（互斥量 + 条件变量 + 最小写入间隔）。
pub const Hub = struct {
    mutex: std.Io.Mutex = .init,
    cond: std.Io.Condition = .init,
    pending: bool = false,
    stop: bool = false,
    last_write: ?std.Io.Timestamp = null,

    /// 有新脏表（幂等：已有 pending 时不重复唤醒）。
    pub fn notify(self: *Hub, io: std.Io) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (!self.pending and !self.stop) {
            self.pending = true;
            self.cond.signal(io);
        }
    }

    /// 停止后台线程并唤醒等待。
    pub fn stopAll(self: *Hub, io: std.Io) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.stop = true;
        self.pending = true;
        self.cond.broadcast(io);
    }

    /// 等待「有脏表 / 停止」信号（无脏表时无限等待，零轮询）。
    pub fn wait(self: *Hub, io: std.Io) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        while (!self.pending and !self.stop) {
            self.cond.waitUncancelable(io, &self.mutex);
        }
    }

    pub fn takePending(self: *Hub, io: std.Io) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.pending = false;
    }

    pub fn isStopped(self: *Hub, io: std.Io) bool {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        return self.stop;
    }

    /// 距上次写盘不足最小间隔时补等剩余时间（后台线程的 sleep，不忙等）。
    pub fn waitMinInterval(self: *Hub, io: std.Io, interval_ms: u64) void {
        if (interval_ms == 0) return;
        var remaining_ms: i64 = 0;
        self.mutex.lockUncancelable(io);
        if (self.last_write) |last| {
            const now = std.Io.Timestamp.now(io, .awake);
            const elapsed_ms = std.Io.Timestamp.durationTo(last, now).toMilliseconds();
            remaining_ms = @as(i64, @intCast(interval_ms)) - elapsed_ms;
        }
        self.mutex.unlock(io);
        if (remaining_ms > 0) {
            io.sleep(.{ .nanoseconds = remaining_ms * std.time.ns_per_ms }, .awake) catch {};
        }
    }

    pub fn markWritten(self: *Hub, io: std.Io) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.last_write = std.Io.Timestamp.now(io, .awake);
    }
};

/// 数据文件路径：`{base_dir}/Data/{清洗后的类型名}.json`。
pub fn tablePathAlloc(gpa: std.mem.Allocator, base_dir: []const u8, type_name: []const u8) ![]u8 {
    const file_name = try sanitizeFileNameAlloc(gpa, type_name);
    defer gpa.free(file_name);
    return std.fs.path.join(gpa, &.{ base_dir, "Data", file_name });
}

/// 清洗类型名成合法文件名（跨平台）。
///
/// 为什么不直接用 `zzig.glob.sanitizeRelPath`：那是**校验**（非法即报错），
/// 这里需要把 `Demo/User` 这类类型名**替换**成 `Demo_User`，语义不同。
pub fn sanitizeFileNameAlloc(gpa: std.mem.Allocator, name: []const u8) ![]u8 {
    const out = try gpa.alloc(u8, name.len + 5); // + ".json"
    errdefer gpa.free(out);

    var length: usize = 0;
    for (name) |c| {
        const safe = switch (c) {
            '/', '\\', ':', '*', '?', '"', '<', '>', '|' => '_',
            else => if (c < 0x20) '_' else c,
        };
        out[length] = safe;
        length += 1;
    }
    // 去掉末尾的空格与点（Windows 非法）
    while (length > 0 and (out[length - 1] == ' ' or out[length - 1] == '.')) length -= 1;
    if (length == 0) {
        out[0] = '_';
        length = 1;
    }
    @memcpy(out[length .. length + 5], ".json");
    return out[0 .. length + 5];
}

/// 原子写文件（复用 zzig.fsio；先建父目录）。
///
/// 注意：`zzig.fsio.writeFileAtomic` 先写 `*.tmp` 再替换，**不负责建父目录**
/// （`ensureParent` 在 `replaceFile` 内部，晚于写临时文件），所以这里必须先建目录。
pub fn writeFileAtomic(io: std.Io, gpa: std.mem.Allocator, path: []const u8, bytes: []const u8) !void {
    try zzig.fsio.ensureParent(io, path);
    try zzig.fsio.writeFileAtomic(io, gpa, path, bytes);
}

/// 读文本文件（不存在返回 `null`；过大返回 `error.FileTooBig`）。
pub fn readFileAlloc(
    io: std.Io,
    gpa: std.mem.Allocator,
    path: []const u8,
    max_bytes: usize,
) !?[]u8 {
    return zzig.fsio.readFileAlloc(io, gpa, path, max_bytes) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
}

/// 文件签名（mtime + 大小）：热加载的**变化驱动**判据。
///
/// 只做一次 `stat`（不读内容、不解析）；签名相同即认为文件未变。
pub const FileSignature = struct {
    mtime_ns: i96 = 0,
    size: u64 = 0,

    pub fn eql(a: FileSignature, b: FileSignature) bool {
        return a.mtime_ns == b.mtime_ns and a.size == b.size;
    }

    /// 读取文件签名（文件不存在返回 `null`；其它错误向上抛）。
    pub fn ofFile(io: std.Io, path: []const u8) !?FileSignature {
        const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };
        return .{ .mtime_ns = stat.mtime.nanoseconds, .size = stat.size };
    }
};

// ----------------------------------------------------------------------
// 测试
// ----------------------------------------------------------------------

const testing = std.testing;

test "文件名清洗与路径拼装" {
    const gpa = testing.allocator;
    const name = try sanitizeFileNameAlloc(gpa, "Demo/User");
    defer gpa.free(name);
    try testing.expectEqualStrings("Demo_User.json", name);

    const path = try tablePathAlloc(gpa, "C:/App", "Test.User");
    defer gpa.free(path);
    try testing.expect(std.mem.endsWith(u8, path, "Data/Test.User.json") or
        std.mem.endsWith(u8, path, "Data\\Test.User.json"));
}

test "写合并间隔：首次写盘不等待" {
    var hub: Hub = .{};
    // 没有 last_write 时剩余等待为 0（不应阻塞）
    hub.waitMinInterval(std.Io.Threaded.global_single_threaded.io(), 500);
}
