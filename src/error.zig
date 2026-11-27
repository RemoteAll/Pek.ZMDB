//! 统一错误集（对齐 Rust 版 `RmdbError` 的可判别语义；细节走 `Violation` 出参）。

pub const Error = error{
    /// 内存分配失败。
    OutOfMemory,
    /// 唯一约束冲突（细节见 `Violation` 出参）。
    UniqueViolation,
    /// 对象不存在（按 ID 更新/删除时未找到）。
    NotFound,
    /// 字段不存在或不可写（如复合约束引用了未声明字段）。
    InvalidField,
    /// 持久化 IO 失败（路径与原因见 `std.log` 输出）。
    PersistError,
    /// 数据文件 JSON 解析失败（加载时降级为空表并记日志；显式解析接口返回此错误）。
    JsonError,
    /// 全局实例未配置（先调用 `configureGlobal`）。
    NotConfigured,
    /// 全局实例已配置（`configureGlobal` 只能调用一次）。
    AlreadyConfigured,
    /// 后台持久化线程创建失败。
    ThreadSpawnFailed,
};
