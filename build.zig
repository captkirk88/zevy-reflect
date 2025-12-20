const std = @import("std");

/// Code generation utilities.
pub const codegen = @import("src/codegen/root.zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const branch_quota_option = b.option(i32, "branch_quota", "Eval branch quota for reflection (default 10000)") orelse 10000;

    const config_content = std.fmt.allocPrint(b.allocator, "pub const branch_quota = {};\n", .{branch_quota_option}) catch unreachable;
    const config = b.addWriteFile("config.zig", config_content);

    const mod = b.addModule("zevy_reflect", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const config_module = b.createModule(.{
        .root_source_file = config.getDirectory().path(b, "config.zig"),
        .target = target,
        .optimize = optimize,
    });

    mod.addImport("config", config_module);

    const mod_tests = b.addTest(.{
        .root_module = mod,
    });

    const run_mod_tests = b.addRunArtifact(mod_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
}
