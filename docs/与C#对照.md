# 与 C# `Pek.MDB` / Rust `Pek.RMDB` 对照

本文记录 Zig 版（`Pek.ZMDB`）与两个参考实现的**语义映射**、**有意差异**与**复用检索证据**，
便于三端互通与后续维护。

## 1. API 映射

| C#（`cdb`） | Rust（`pek_rmdb`） | Zig（`pek_zmdb`） |
|---|---|---|
| `cdb.Insert(obj)` | `db.insert(obj)?` | `db.insert(T, obj, ?*Violation) !i64` |
| `cdb.InsertBatch(list)` | `db.insert_batch(vec)?` | `db.insertBatch(T, objs, ?*Violation) ![]i64` |
| `cdb.InsertByIndex(obj, prop, val)` | `db.insert_by_index(obj, &["F"])?` | `db.insertByIndex(T, obj, &.{"F"}, ?*Violation)` |
| `cdb.Update(obj)` | `db.update(obj)?` | `db.update(T, obj, ?*Violation) !void` |
| `cdb.Delete(obj)` | `db.delete::<T>(id)` | `db.delete(T, id) !bool` |
| `cdb.FindById<T>(id)` | `db.find_by_id::<T>(id)` | `db.findById(T, id) !?Ref(T)` |
| `cdb.FindAll<T>()` | `db.find_all::<T>()` | `db.findAll(T) !List(T)` |
| `cdb.FindBy<T>(prop, val)` | `db.find_by::<T>(prop, val)` | `db.findBy(T, prop, Value)` |
| `cdb.FindByRange<T>(prop, min, max)` | `db.find_by_range::<T>(...)` | `db.findByRange(T, prop, min, max)` |
| `cdb.FindByLike<T>(prop, pattern)` | `db.find_by_like::<T>(...)` | `db.findByLike(T, prop, pattern)` |
| `cdb.FindByMultiple<T>(dict)` | `db.find_by_multiple::<T>(&[...])` | `db.findByMultiple(T, conditions)` |
| `cdb.FindByPage<T>(prop, i, size, asc)` | `db.find_by_page::<T>(...)` | `db.findByPage(T, prop, i, size, asc)` |
| `cdb.FindByUnique<T>(prop, val)` | `db.find_by_unique::<T>(...)` | `db.findByUnique(T, prop, Value)` |
| `cdb.FindByCompositeUnique<T>(group, dict)` | `db.find_by_composite_unique::<T>(...)` | `db.findByCompositeUnique(T, group, conditions)` |
| `cdb.IsUniqueValueExists<T>(prop, val, exclude)` | `db.is_unique_value_exists::<T>(...)` | `db.isUniqueValueExists(T, prop, Value, exclude)` |
| `MemoryDB` 静态全局 | `pek_rmdb::global()` | `configureGlobal(...)` + `global()` / 自由函数 |
| `[Unique(msg, AllowNull)]` | `Field::text("F").unique(msg)` | `Field.text("F").withUnique(msg)` / `.withUniqueRequired(msg)` |
| `[CompositeUnique(group, fields...)]` | `CompositeUniqueRule::new(group, &[...], msg)` | `CompositeUniqueRule.init(group, &.{...}, msg)` |
| `[NotIndexed]` / `[NotSave]` / 类级 `[NotSave]` | `.not_indexed()` / `.not_save()` / `fn not_save()` | `.notIndexed()` / `.notSave()` / `pub const not_save = true` |
| `UniqueConstraintViolationException` | `RmdbError::Unique(UniqueViolation)` | `error.UniqueViolation` + `Violation` 出参 |

属性/字段名保持 **PascalCase**，与 C# 属性名一致；`Id` / `Name` 由框架维护，
不需要写进 `fields`，但都可以直接查询（`findBy("Id", ..)` / `findBy("Name", ..)`）。

## 2. 数据文件格式（双向兼容）

C# `SimpleJsonString.ConvertList`：

```
[\r\n
\t{ Id:1, Name:"张三", Username:"zhangsan", Age:30, CreateTime:"2024-01-05 08:30:00" },\r\n
\t{ Id:2, ... }\r\n
]
```

Zig 版**逐字节对齐**：
- 裸键（不带引号）、`\r\n` + `\t` 缩进、`Id` / `Name` 排在最前；
- 字符串按 C# `JsonString.ClearNewLine` 口径（只转义 `\` 与 `"`，去掉 `\r`/`\n`/`\t`）；
- 时间写成 `yyyy-MM-dd HH:mm:ss`；布尔写 `true`/`false`；浮点整数值不带 `.0`，
  非有限值写成 `"NaN"` / `"Infinity"` / `"-Infinity"`；
- 读取侧**宽容**：裸键、带引号键、`//` 行注释、尾逗号、大小写关键字、`2024/1/5 14:30:00` 日期均可解析。

## 3. 文本大小写口径（与 C# 对照）

| 行为 | C# | Zig | 是否一致 |
|---|---|---|---|
| 文本精确 `FindBy` | 区分大小写（基础索引存原值） | 区分（exact 哈希） | ✅ |
| 文本 `FindByLike` | 不区分（小写索引） | 不区分（小写有序索引） | ✅（ASCII 范围内） |
| 文本 `FindByRange` | 不区分（小写索引 + OrdinalIgnoreCase） | 不区分（小写有序索引） | ✅（ASCII 范围内） |
| 单/复合唯一约束 | 区分（默认相等 / `ToString()` 拼接） | 区分（类型化键精确比较） | ✅ |
| 字段/属性名（含 `Id`/`Name`） | 严格（`GetProperty`） | 严格（索引/唯一表按声明名） | ✅ |
| 非 ASCII（如 `Ä`/`ä`） | `ToLowerInvariant()` 全量折叠 | 仅 ASCII 折叠 | ❌ 见 §8 |
| 空字符串文本 | 不建索引（`IsNullOrEmpty` 跳过） | 建索引（Rust 版口径） | ❌ 有意差异 |
| 加载 JSON 键名 | 严格（`Dictionary` 默认比较器） | 精确优先、忽略大小写兜底 | ❌ 更宽容 |
| `?` 通配 | 不支持（只处理 `*`） | 支持单字符 | 超集 |
| 布尔模式中文 | 模式只认 true/1/yes/on；归一化认 是/真/否/假 | 模式与归一化认 是/否 | 部分差异 |

> 结论：**查询语义在 ASCII/中文场景与 C# 一致**；非 ASCII 折叠、空串索引、JSON 键宽容是已知边界
> （详见 `docs/决策记录.md` 2026-11-27 审计节、本文 §8）。

## 4. 有意差异（沿用 Rust 版的修正，并在 Zig 版保持一致）

| 主题 | C# 版行为 | Zig 版（与 Rust 版一致） |
|---|---|---|
| 加载后 ID 计数器 | 不修正，新增从 1 开始**覆盖旧数据** | 修正为 `max(id)+1` |
| 加载时唯一冲突 | 只记警告，对象留在表中但唯一索引缺失 | **跳过该对象**并记警告（状态自洽） |
| 跨类型查询 | `object` 相等，`1`(int) 查不中 `1L`(long) | 按字段类型规范化，`1` / `1.0` / `"1"` 同值 |
| 范围查询 | 遍历 `ConcurrentDictionary`（`O(n)`） | 有序 Treap（`O(log n + k)`） |
| 空值唯一键 | 取决于字段类型 | `allow_null = true` 时空值不入索引；`false` 时空值即冲突 |
| 更新索引 | 全量删 + 建 | 按字段 diff，只重建变化的键 |
| 读返回 | 引用 | `Ref(T)` 引用计数句柄（可跨线程持有，删除后延迟释放） |
| 持久化失败回调 | `DbOptions.on_error` | 统一走 `std.log.scoped(.zmdb)`（含类型名/路径/错误名，便于运维定位） |

## 5. 时间精度

- 索引键与持久化统一 **秒精度**（`DateTime.toUnixSeconds`），与 C# `SimpleJsonString` 的
  `yyyy-MM-dd HH:mm:ss` 落库口径一致；`DateTime` 自带的纳秒在索引/比较时被截掉。
- 整数时间戳按**秒**解释；绝对值 > `1e11` 视为毫秒自动换算。

## 6. JSON 字段

- `Field.json` 的值以 **JSON 文本**参与索引（与 C# `GenericIndex` / Rust 版一致）；
- 实体 `getField` 返回 `.text`（如 `[ "a", "b" ]` 或 `{"k":1}`），`setField` 持有该文本；
- 落盘时：文本以 `[` / `{` 开头则**原样写出**（保持嵌套结构），否则按普通字符串转义；
- 从 C# 文件加载的嵌套值会被压缩为标准 JSON 文本（`["a","b"]`），C# 侧可直接再读。

## 7. 复用检索证据（写码前已检索）

按「公共库 → 兄弟项目 → 本仓库既有实现」顺序检索，命令与结论：

| 需求 | 检索 | 结论 |
|---|---|---|
| 通用字段值 / 跨类型取值 | `zzig/src/db/value.zig`（`pub fn asI64/asF64/asBool/asDatetime/toTextAlloc`） | **直接复用** `zzig.db.Value` |
| 日期时间解析/格式化/Unix 换算 | `zzig/src/time/datetime.zig`（`DateTime.parse/fromUnixSeconds/toUnixSeconds/daysSinceUnixEpoch`） | **直接复用** `zzig.DateTime`；只补 `yyyy-MM-dd HH:mm:ss` 与年/月/日区间 |
| 字符串缓冲 | `zzig/src/text/buf.zig`（`Buf.add/fmt/addZeroPadded/toOwnedSlice`） | **直接复用** `zzig.Buf`（含 0.17 `{d:0>4}` 会输出 `+2024` 的规避） |
| 原子写 / 读文件 / 建目录 | `zzig/src/file/fsio.zig`（`readFileAlloc` / `writeFileAtomic` / `ensureParent`） | **复用**（发现 `writeFileAtomic` 不建父目录，封装时先 `ensureParent`） |
| 大小写不敏感包含 | `zzig/src/text/ascii.zig`（`containsIgnoreCase` 等） | **复用** |
| JSON 词法 | `zzig/src/json/jsmn_zig.zig`（键必须是引号字符串）、`zzig/src/http/value.zig`（标准 JSON 解析 + 值树） | 词法**不适用**（C# 是裸键 + 注释）；值树**复用** `zzig.web.Value` |
| 通配匹配 | `zzig/src/file/glob.zig`（`matchPattern(pattern, path, ci)`：路径语义，含 `/` 分段） | **不适用**（字段值可能含 `/`），本项目用纯文本 `*`/`?` 匹配 |
| 有序映射 | 检索 `zig std`（无 `BTreeMap` / `Treap`）；`zzig` 无有序容器 | 本项目自带 Treap（约 200 行） |
| 后台写合并 | `zzig/src/threading/timer.zig` / `pool.zig`（定时器/线程池，不含「脏标记 + 条件变量 + 最小间隔」语义） | 本项目的 `persist.Hub`（与 Rust 版一致） |

## 8. 已知边界

- `insert` / `update` 中的 OOM 属于致命错误：极端情况下唯一索引与普通索引可能只更新了一部分
  （与大多数 Zig 库一致，不做事务回滚）；
- 文本索引的大小写折叠只按 **ASCII** 处理（`std.ascii.toLower`），中文等 UTF-8 多字节原样保留；
  C# 用 `ToLowerInvariant()` 全量折叠，故 `Ä`/`ä` 在 Zig 的模式/范围查询里不互相命中；
- 空字符串文本会进入文本索引（C# `StringIndex` 用 `IsNullOrEmpty` 跳过空串），
  因此 `findBy("Status", "")` 在 Zig 可能命中、C# 恒为空；
- 加载 JSON 时键名**精确优先、忽略大小写兜底**（C# `Dictionary` 键严格），只影响读取非规范文件；
- 布尔字段的「智能值」额外支持 `on/off/是/否`（对齐 C# `BooleanIndex` 的归一化，Rust 版同样支持）；
  但 `FindBy(field, true/false)` 的模式解析不认 `真/假`（C# 归一化支持）。
