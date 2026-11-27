# Pek.ZMDB · 高性能内存数据库（Zig 版）

> C# [`Pek.MDB`](https://github.com/RemoteAll/Pek.MDB) 与 Rust [`Pek.RMDB`](../../Rust/Pek.RMDB) 的 Zig 实现（Zig **0.17.1**）：
> 面向 **「读多写少、内存为主、JSON 异步持久化」** 场景的轻量级内存数据库。
> crate/module 名：`pek_zmdb`（库，无面板/无服务），供生态内 Zig 项目以 path 依赖复用。

## 特性

| 能力 | 说明 |
|---|---|
| 类型化实体 | comptime 契约（`type_name` / `fields` / `getField` / `setField`），**无反射、无装箱** |
| 类型感知索引 | 文本（精确 + 大小写不敏感模糊 `*`/`?`）、整数/浮点/时间（有序 Treap 范围）、布尔（双桶 + 智能值）、JSON（文本键） |
| 唯一约束 | 单字段与复合约束，支持 `allow_null`、更新排除自身、批量校验、冲突细节出参 |
| 查询 | 按 ID / 字段 / 范围 / 通配 / 多条件交集 / 唯一值 / 复合键 / 分页 |
| 异步持久化 | 后台线程合并写盘（默认 500ms 窗口）、原子替换、`flush()` 同步落盘、变化的表才写 |
| C# 互通 | 读写 `Data/{type_name}.json`，格式与 C# `SimpleJsonString` 双向兼容（裸键 + `//` 注释 + 斜杠日期均可解析） |
| 安全句柄 | 读操作返回 `Ref(T)` 原子引用计数句柄，删除后延迟释放；`List`/`Page` 自动批量释放 |
| 多实例/全局 | `MemoryDb.init(gpa, io, options)` 多实例隔离；`configureGlobal` + `global()` 提供 `cdb` 风格静态入口 |
| 零第三方依赖 | 仅依赖生态公共库 **zzig**（不另造公共能力） |

## 复用 zzig（不重复实现）

| 能力 | 来源 | 说明 |
|---|---|---|
| 通用字段值 | `zzig.db.Value` | null/boolean/int/float/decimal/text/blob/datetime + `asI64/asF64/asBool/asDatetime/toTextAlloc` |
| 日期时间 | `zzig.DateTime` | 宽容解析（ISO / `yyyy/M/d` / 带小数秒）、Unix 换算 |
| 字符串缓冲 | `zzig.Buf` | 序列化（`std.Io.Writer.Allocating` 封装，含 0.17 补零坑的规避） |
| 文件读写 | `zzig.fsio` | `readFileAlloc` / `writeFileAtomic`（含 `ensureParent` 修正，见下） |
| ASCII 折叠 | `zzig.ascii` + `std.ascii` | 大小写不敏感包含/前缀判断 |
| JSON 值树 | `zzig.web.Value` | 对象/数组/标量 + `get` + `jsonAlloc` |

**为什么还留了少量本项目代码**（检索证据见 `docs/与C#对照.md`）：

- `zzig.json.Jsmn` 要求键带引号，而 C# `SimpleJsonString` 写的是**裸键**（`{ Id:1, Name:"x" }`）→
  本项目只补一层「宽容词法」，产出仍是 `zzig.web.Value` 树；
- `zzig.glob.matchPattern` 是**路径**语义（含 `/` 分段、无 `/` 只比末段），字段值可能含 `/` →
  本项目用纯文本通配（`*` / `?`）；
- `zzig.fsio.writeFileAtomic` **不在写临时文件前建父目录**（`ensureParent` 在 replace 阶段）→
  本项目先 `ensureParent` 再调用（已写进封装与注释）；
- Zig 0.17 标准库没有 `BTreeMap` / `Treap` → 本项目自带一个小型随机化 Treap（约 200 行）。

## 快速开始

```zig
const std = @import("std");
const zmdb = @import("pek_zmdb");

pub const User = struct {
    gpa: std.mem.Allocator,
    id: i64 = 0,
    name: []const u8 = "",
    username: []const u8 = "",
    email: []const u8 = "",
    age: i64 = 0,

    pub const type_name = "Demo.User"; // 数据文件 Data/Demo.User.json

    pub const fields = [_]zmdb.Field{
        zmdb.Field.text("Username").withUnique("用户名已存在"),
        zmdb.Field.text("Email").withUniqueRequired("邮箱已被注册"),
        zmdb.Field.int("Age"),
    };

    pub fn initEmpty(gpa: std.mem.Allocator) User { return .{ .gpa = gpa }; }
    pub fn deinit(self: *User) void {
        self.gpa.free(self.name);
        self.gpa.free(self.username);
        self.gpa.free(self.email);
        self.* = .{ .gpa = self.gpa };
    }
    pub fn getId(self: *const User) i64 { return self.id; }
    pub fn setId(self: *User, id: i64) void { self.id = id; }
    pub fn getName(self: *const User) []const u8 { return self.name; }
    pub fn setName(self: *User, name: []const u8) !void { /* 复制进自身内存 */ }
    pub fn getField(self: *const User, name: []const u8) ?zmdb.Value { /* 借用值 */ }
    pub fn setField(self: *User, name: []const u8, value: zmdb.Value) !bool { /* 复制进自身内存 */ }
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

    const id = try db.insert(User, user, null);          // 分配并回写 ID
    const found = (try db.findById(User, id)).?;         // 返回 Ref，需要 release
    defer found.release();
    std.debug.print("用户名：{s}\n", .{found.get().username});

    var list = try db.findByRange(User, "Age", .{ .int = 18 }, .{ .int = 60 });
    defer list.deinit();                                  // 一次释放全部句柄
    std.debug.print("成年人 {d} 个\n", .{list.len()});
}
```

完整可运行示例见 `examples/basic.zig`（`zig build example`）。

## 实体契约

实体必须提供（缺一即编译期报错，见 `src/entity.zig`）：

| 声明 | 说明 |
|---|---|
| `pub const type_name: []const u8` | 持久化文件名 `Data/{type_name}.json`（不含路径分隔符） |
| `pub const fields` | `[_]Field` 或 `[]const Field`；`Id`/`Name` 由框架维护，无需声明 |
| `pub const composite_uniques`（可选） | `[_]CompositeUniqueRule` |
| `pub const not_save`（可选） | 整类不落盘（对应 C# 类级 `[NotSave]`） |
| `initEmpty(gpa) T` / `deinit(*T)` | 构造空实体 / 释放自身内存 |
| `getId(*const T) i64` / `setId(*T, i64)` | 主键 |
| `getName(*const T) []const u8` / `setName(*T, []const u8) !void`（可选，成对） | 名称 |
| `getField(*const T, name) ?Value` | 按字段名读值（**借用**，文本指向实体内存） |
| `setField(*T, name, Value) !bool` | 按字段名写值（实体自行复制并持有） |

**所有权约定**：

- `insert` / `insertBatch` / `update` 成功时，传入实体归库所有；
- 失败时**由库调用 `deinit` 释放**（与 Rust 版 `Drop` 语义一致）；
- 查询返回 `Ref(T)` / `List(T)` / `Page(T)`，必须 `release()` / `deinit()`。

## 字段与索引

| 构造器 | 类型 | 索引能力 |
|---|---|---|
| `Field.text(name)` | 文本 | 精确（区分大小写）、`findByLike`（大小写不敏感：`*`/`?` 通配、前缀、包含、后缀）、范围（小写字典序） |
| `Field.int(name)` / `Field.float(name)` | 数值 | 精确、范围 `O(log n + k)` |
| `Field.boolean(name)` | 布尔 | 精确、智能模式（`true/1/yes/on/是`、`false/0/no/off/否`） |
| `Field.time(name)` | 时间 | 精确、范围、年/年月/年月日（`findByLike("2024-01")`） |
| `Field.json(name)` | 列表/映射 | 按 JSON 文本精确索引 |

修饰器：`.withUnique(msg)`（允许空）、`.withUniqueRequired(msg)`（不允许空）、`.notIndexed()`、`.notSave()`。
`Id` 与 `Name` 由框架自动索引，不需要写进 `fields`。

## 常用 API

| 操作 | 实例方法 |
|---|---|
| 插入 | `insert(T, obj, ?*Violation)` / `insertBatch(T, objs, ?*Violation)` / `insertByIndex(T, obj, &fields, ?*Violation)` |
| 更新/删除 | `update(T, obj, ?*Violation)` / `delete(T, id)` |
| 主键/全表 | `findById(T, id)` / `findAll(T)` |
| 字段/范围/模糊 | `findBy(T, field, value)` / `findByRange(T, field, min, max)` / `findByLike(T, field, pattern)` |
| 多条件/分页 | `findByMultiple(T, conditions)` / `findByPage(T, sort_field, page_index, page_size, ascending)` |
| 唯一键 | `findByUnique(T, field, value)` / `findByCompositeUnique(T, group, conditions)` / `isUniqueValueExists(T, field, value, exclude)` |
| 维护 | `clear(T)` / `clearAll()` / `flush()` / `statistics(gpa)` / `loadedTables(gpa)` |

全局（`cdb` 风格）：`configureGlobal` 后可用同名自由函数（`zmdb.insert`、`zmdb.findById` …）。

写操作返回 `zmdb.Error`（`UniqueViolation` / `NotFound` / `InvalidField` / `PersistError` / `OutOfMemory`）；
唯一冲突细节通过可选出参 `Violation` 回填（字段名、约束类型、冲突 ID、业务消息、`duplicate` / `null_not_allowed`）。

## 持久化

- 路径：`{base_dir}/Data/{type_name}.json`；纯内存库用 `MemoryDb.inMemory(gpa, io)`。
- 格式：与 C# 版一致（裸键、`\r\n` + `\t`、`Id`/`Name` 在前、字符串去掉换行/制表符）；
  **Zig 写出的文件可被 C# 版直接读取，C# 写出的文件也可被 Zig 读取**（含 `//` 注释与 `2024/1/5 14:30:00` 日期）。
- 后台线程：写操作只置脏并唤醒线程；默认 500ms 内的多次修改合并为一次序列化 + 一次原子写；
  无脏数据时线程在条件变量上无限等待（零轮询）。
- `flush()` 可随时同步落盘；`MemoryDb.deinit` 默认也会 flush（`flush_on_drop`）。
- 加载时修正 ID 计数器为 `max(id)+1`（C# 版未修正，加载后新增会从 1 开始覆盖旧数据）；
  唯一冲突/无效 ID/重复 ID 的对象**跳过并记警告**（C# 版会留下「对象在、唯一索引缺」的不一致）。
- 整体类型不落盘：声明 `pub const not_save = true;`。

## 双向热更新（文件 ⇄ 内存）

| 方向 | 机制 |
|---|---|
| 内存 → 文件 | 写操作置脏 → 后台线程 500ms 合并写盘；`flush()` 手动；`deinit` 默认补写 |
| 文件 → 内存 | `db.reload(T)` / `db.reloadAll()`；可选 `reload_on_read_interval_ms` 让读入口按节流自动检查 |

热加载是**变化驱动 + 三方合并**，不是整表覆盖：

- 签名 = `mtime + 大小`：未变化时只做一次 `stat`，不读盘、不解析；
- 每行保留「上次与文件一致时的内容哈希」作为基准，逐行对比内存 / 文件 / 基准：
  - 只有内存改 → **保留内存**，并把表标记为脏（合并结果随后写回文件）；
  - 只有文件改 → **采用文件**；
  - 两边都改（冲突）→ **以文件为准**，记 warn；
  - 内存删除、文件未改 → 保持删除，并**回写文件**（否则下次加载会复活）；
  - 内存删除、文件也删/改 → 以文件为准（需要时恢复该行）；
- 文件缺失或解析失败 → **保留内存数据**并返回 `error.PersistError`，不影响后续读写；
- 合并后 `next_id = max(id)+1`，索引 / 唯一约束全部重建；唯一冲突的文件行跳过并记 warn。

```zig
// 显式触发（按需）
_ = try db.reload(User);

// 或开启读入口自动检查（每 1s 最多一次 stat）
var db2 = try MemoryDb.init(gpa, io, .{ .base_dir = "AppData", .reload_on_read_interval_ms = 1000 });
```


## 并发与所有权

- 每张表一把 `std.Io.RwLock`：读并发、写独占；
- 实体以 `Ref(T)`（堆上 Box + 原子引用计数）持有，删除后延迟到最后一次 `release` 才释放；
- `MemoryDb` 的 `io` 必须是线程安全实现（`std.Io.Threaded`），后台持久化线程与调用线程共用。

## 构建与测试

```powershell
zig build test                    # Debug 下全部单测（含泄漏检测）
zig build test -Doptimize=ReleaseFast
zig build example                 # 运行示例（写 AppData/Data/Demo.User.json）
zig build bench -Doptimize=ReleaseFast   # 性能基准（可用 -Drows=N 调整行数）
```

## 性能（实测）

基准：`zig build bench -Doptimize=ReleaseFast`，10 万行 / 6 个索引字段（文本唯一、文本、整数、布尔、非索引大文本），
Windows 11 + Zig 0.17.1，同机连续多次取值：

| 场景 | 耗时 | 说明 |
|---|---|---|
| 批量插入 10 万行 | ≈ 245 ms | 2.4 µs/行（含 6 个索引 + 唯一约束） |
| 主键查找 ×10 万 | ≈ 8 ms | 80 ns/次（哈希表） |
| 文本精确查询 ×2 万 | ≈ 14 ms | 0.7 µs/次（哈希索引） |
| 文本前缀/包含 / 整数范围 / 多条件 | 200 µs ~ 3.8 ms/次 | 前缀走有序范围；包含与复杂通配逐键扫描 |
| 分页（按 ID）×20 | ≈ 0 ms | 升序 ID 表直接切片（不排序） |
| 分页（按索引字段）×20 | ≈ 15 ms | 索引顺序取页（`takeOrdered`） |
| 更新单字段 ×2 万 | ≈ 31 ms | 1.5 µs/次（只重建变化字段的索引键） |
| 删除 ×2 万 | ≈ 46 ms | 2.3 µs/次（负数墓碑 + 摊还压缩，无 O(n) 搬移） |
| 落盘 8 万行 | ≈ 35 ms | 序列化 + 原子替换 |
| 加载 8 万行 + 全表读取 | ≈ 280 ms | 解析 + 建索引 ≈ 3.5 µs/行 |

关键设计：**单调 ID 尾部追加** + **负数墓碑删除**（删除只做二分 + 取负，墓碑 ≥ 64 且不少于存活数时原地压缩）+
**表级升序 ID 表**（分页/快照零排序）+ **更新按字段 diff**（未变化字段不做 normalize 分配）。

## 文档

- `docs/与C#对照.md`：API/语义映射、有意差异、复用检索证据；
- `docs/决策记录.md`：每轮决策、实测数据与用户原话；
- `README.md`：本文件。

## License

MIT
