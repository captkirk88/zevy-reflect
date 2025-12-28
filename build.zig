const std = @import("std");
const buildtools = @import("zevy_buildtools");

/// Code generation utilities.
pub const codegen = @import("src/codegen/root.zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const branch_quota_option = b.option(i32, "branch_quota", "Eval branch quota for reflection (default 100,000)") orelse 100_000;
    const hash_seed_option = b.option(u64, "seed", "Seed for type hashing (default 0)") orelse 0;

    const config_content = std.fmt.allocPrint(b.allocator, "pub const branch_quota = {};\npub const hash_seed: u64 = {};\n", .{ branch_quota_option, hash_seed_option }) catch unreachable;
    const config = b.addWriteFile("zevy_reflect_config.zig", config_content);

    const mod = b.addModule("zevy_reflect", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const config_module = b.createModule(.{
        .root_source_file = config.getDirectory().path(b, "zevy_reflect_config.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Use a unique import name to avoid collisions when this package is a dependency
    mod.addImport("zevy_reflect_config", config_module);

    const mod_tests = b.addTest(.{
        .root_module = mod,
    });

    const run_mod_tests = b.addRunArtifact(mod_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
}
