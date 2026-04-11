const std = @import("std");
const zevy_reflect = @import("zevy_reflect");
const types = @import("src/types.zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const loggable_entity = comptime zevy_reflect.codegen.mixin.generate(
        .{ .base = types.Entity, .extension = types.Loggable },
        .{
            .type_name = "LoggableEntity",
            .file_name = "loggable_entity.zig",
            .base_import_name = "loggable_base_types",
            .base_type_name = "Entity",
            .base_type_ref = "loggable_base_types.Entity",
            .extension_import_name = "loggable_extension_types",
            .extension_type_name = "Loggable",
            .extension_type_ref = "loggable_extension_types.Loggable",
            .base_import_path = "types",
            .extension_import_path = "types",
        },
    );
    const named_entity = comptime zevy_reflect.codegen.mixin.generate(
        .{ .base = types.Entity, .extension = types.Named },
        .{
            .type_name = "NamedEntity",
            .file_name = "named_entity.zig",
            .base_import_name = "named_base_types",
            .base_type_name = "Entity",
            .base_type_ref = "named_base_types.Entity",
            .extension_import_name = "named_extension_types",
            .extension_type_name = "Named",
            .extension_type_ref = "named_extension_types.Named",
            .base_import_path = "types",
            .extension_import_path = "types",
        },
    );
    const generated_root = comptime zevy_reflect.codegen.mixin.generateModule(
        &.{ loggable_entity, named_entity },
        .{},
    );

    // Create a build step that generates mixin code
    const gen_step = b.addWriteFiles();
    gen_step.step.name = "generate mixins";

    const loggable_entity_file = gen_step.add(
        loggable_entity.file_name,
        loggable_entity.source,
    );
    const named_entity_file = gen_step.add(
        named_entity.file_name,
        named_entity.source,
    );
    _ = loggable_entity_file;
    _ = named_entity_file;
    const generated_root_file = gen_step.add(
        generated_root.file_name,
        generated_root.source,
    );

    const types_module = b.createModule(.{
        .root_source_file = b.path("src/types.zig"),
        .target = target,
        .optimize = optimize,
    });

    const generated_module = b.createModule(.{
        .root_source_file = generated_root_file,
        .target = target,
        .optimize = optimize,
    });
    generated_module.addImport("types", types_module);

    const mod = b.addModule("example_mixin", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "types", .module = types_module },
            .{ .name = "generated_mixin", .module = generated_module },
        },
    });

    const exe = b.addExecutable(.{
        .name = "example_mixin",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "example_mixin", .module = mod },
            },
        }),
    });

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    run_cmd.step.dependOn(b.getInstallStep());

    const mod_tests = b.addTest(.{
        .root_module = mod,
    });

    const run_mod_tests = b.addRunArtifact(mod_tests);

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });

    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
}
