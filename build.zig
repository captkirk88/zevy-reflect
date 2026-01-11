const std = @import("std");
const buildtools = @import("zevy_buildtools");

/// Code generation utilities.
pub const codegen = @import("src/codegen/root.zig");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("zevy_reflect", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{},
    });

    const mod_tests = b.addTest(.{
        .root_module = mod,
    });

    const run_mod_tests = b.addRunArtifact(mod_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);

    buildtools.fetch.addFetchStep(b, b.path("build.zig.zon")) catch |err| {
        return err;
    };

    buildtools.fetch.addGetStep(b);

    buildtools.deps.addDepsStep(b) catch |err| {
        return err;
    };
}
