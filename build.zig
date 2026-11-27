const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // 公共基础库：DateTime / db.Value / Buf / fsio / ascii / glob 一律复用，不在本项目重写
    const zzig_dep = b.dependency("zzig", .{ .target = target, .optimize = optimize });
    const imports = [_]std.Build.Module.Import{
        .{ .name = "zzig", .module = zzig_dep.module("zzig") },
    };

    // 库模块：其它 Zig 项目通过 `b.dependency("pek_zmdb", .{}).module("pek_zmdb")` 引用
    const lib_module = b.addModule("pek_zmdb", .{
        .root_source_file = b.path("src/zmdb.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &imports,
    });

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/zmdb.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &imports,
        }),
    });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "运行单元测试（CRUD / 索引 / 唯一约束 / 持久化 / 并发）");
    test_step.dependOn(&run_tests.step);

    // 示例：C# 格式读写 + 常用查询
    const example = b.addExecutable(.{
        .name = "zmdb-example",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/basic.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &imports,
        }),
    });
    example.root_module.addImport("pek_zmdb", lib_module);
    b.installArtifact(example);

    const run_example = b.addRunArtifact(example);
    const example_step = b.step("example", "运行示例（examples/basic.zig）");
    example_step.dependOn(&run_example.step);

    // 性能基准（ReleaseFast 下才有意义）
    const bench_rows = b.option(usize, "rows", "基准行数（默认 100000）") orelse 100_000;
    const bench_options = b.addOptions();
    bench_options.addOption(usize, "bench_rows", bench_rows);

    const bench = b.addExecutable(.{
        .name = "zmdb-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/bench.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &imports,
        }),
    });
    bench.root_module.addImport("pek_zmdb", lib_module);
    bench.root_module.addOptions("build_options", bench_options);
    b.installArtifact(bench);

    const run_bench = b.addRunArtifact(bench);
    const bench_step = b.step("bench", "运行性能基准（建议 -Doptimize=ReleaseFast）");
    bench_step.dependOn(&run_bench.step);
}
