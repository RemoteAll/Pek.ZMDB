# Pek.ZMDB · 项目指令

> 全项目通用规则见用户级《跨项目接续协议》（本机 `%APPDATA%\Code\User\prompts\跨项目接续协议.instructions.md`；模板在 `tools/continuity/templates/`）。
> **开工先读（存在则读，按序）**：`.github/copilot-instructions.md` → `docs/项目接续指南.md` → `docs/用户档案.md` → `docs/项目记忆.md` → `docs/决策记录.md` 最新节。

## 项目速览

- **定位**：C# `Pek.MDB` 与 Rust `Pek.RMDB` 的 **Zig** 实现（Zig **0.17.1**）：读多写少、内存为主、JSON 异步持久化的内存数据库。
- **技术栈**：纯 `std` + 生态公共库 **zzig**（唯一 path 依赖 `../zzig`，不引其它第三方）。
- **产物**：库模块 `pek_zmdb`（`src/zmdb.zig`）+ 示例 `examples/basic.zig` + 一键回归 `tools/regression.ps1`。

## 关键约定（改动前必读）

- **复用 zzig 是硬要求**：`db.Value` / `DateTime` / `Buf` / `fsio` / `ascii` / `web.Value` 一律直接用；
  本地只保留 zzig 没有的领域能力（裸键 JSON 词法、纯文本通配、Treap 有序映射），检索证据见 `docs/与C#对照.md` 第 6 节。
- **持久化格式是 C# 互通红线**：裸键 `{ Id:1, Name:"x", F:v }`、`\r\n` + `\t`、`Id`/`Name` 在前、
  时间 `yyyy-MM-dd HH:mm:ss`、字符串只转义 `\` 与 `"` 且去掉 `\r\n\t`。改格式必须同步 `docs/与C#对照.md` 并重跑回归。
- **所有权**：`insert`/`update`/`insertBatch` **失败时由库 `deinit` 传入实体**，成功后归库；
  查询返回 `Ref`/`List`/`Page`，调用方必须 `release`/`deinit`（测试用 `std.testing.allocator` 抓泄漏）。
- **并发**：每表一把 `std.Io.RwLock`；实体 `Ref` 原子引用计数（删后延迟释放）；`io` 必须是线程安全实现（`std.Io.Threaded`）。
- **zzig 已踩坑**：`fsio.writeFileAtomic` 不在写 `.tmp` 前建父目录 → 本项目 `persist.writeFileAtomic` 先 `ensureParent`；
  `zzig.json.Jsmn` 不支持裸键；`zzig.glob.matchPattern` 是路径语义（不能用于字段值通配）。
- **Zig 0.17 已踩坑**：std 无 `BTreeMap`/`Treap`、无 `std.Thread.Mutex`（锁/条件变量在 `std.Io`）；
  `std.fmt` 的 `{d:0>4}` 会输出 `+2024`（日期用手写补零）；`build.zig.zon` 必须有 `fingerprint`。
- 中文 `.ps1` 必须 **UTF-8 with BOM**；PS 5.1 下外部命令后用 `$LASTEXITCODE` 判定，不要写 `2>&1 |`。

## 构建与验证

```powershell
zig build test                              # Debug 全部单测（含泄漏检测）
zig build test -Doptimize=ReleaseFast       # 发布模式再跑一遍
zig build example                           # 示例端到端（写 AppData/Data/Demo.User.json，可重复运行）
zig fmt --check build.zig src examples      # 格式
powershell -NoProfile -ExecutionPolicy Bypass -File tools\regression.ps1   # 一键回归：fmt → Debug → ReleaseFast → 示例
```

当前基线：**60 个测试全部通过**。改持久化/索引/唯一约束后必须重跑 `tools/regression.ps1` 并如实汇报输出。

## 每轮收尾（务必）

① `docs/决策记录.md` 新增一节（**含用户原话**）；② 运行 `tools/continuity/sync-memory.ps1` 同步记忆
（项目根目录运行或传 `-ProjectPath`）；③ 跑回归验证并如实汇报。
