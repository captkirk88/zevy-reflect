const std = @import("std");
const reflect = @import("../reflect.zig");
const generator = @import("generator.zig");

/// Configuration for mixin generation
pub const MixinConfig = struct {
    /// Name for the generated mixin type
    type_name: []const u8,
    /// Output filename for this generated mixin source
    file_name: ?[]const u8 = null,
    /// Alias used for the generated base import binding
    base_import_name: ?[]const u8 = null,
    /// Name of the base type (for imports)
    base_type_name: []const u8,
    /// Expression used anywhere the base type is referenced in generated code
    base_type_ref: ?[]const u8 = null,
    /// Alias used for the generated extension import binding
    extension_import_name: ?[]const u8 = null,
    /// Name of the extension type (for imports)
    extension_type_name: []const u8,
    /// Expression used anywhere the extension type is referenced in generated code
    extension_type_ref: ?[]const u8 = null,
    /// Module path for base type (e.g., "player.Player")
    base_import_path: []const u8,
    /// Module path for extension type (e.g., "loggable.Loggable")
    extension_import_path: []const u8,
    /// Strategy for handling method name conflicts
    conflict_strategy: ConflictStrategy = .extension_wins,
    /// Emit field summaries as comments in the generated type
    emit_field_comments: bool = true,
    /// Emit comments when methods are skipped due to conflicts
    emit_conflict_comments: bool = true,
    /// Emit the convenience initializer that uses a default extension value
    emit_init_base: bool = true,

    pub fn validate(comptime self: MixinConfig) void {
        if (self.type_name.len == 0) @compileError("MixinConfig.type_name cannot be empty");
        if (self.base_type_name.len == 0) @compileError("MixinConfig.base_type_name cannot be empty");
        if (self.extension_type_name.len == 0) @compileError("MixinConfig.extension_type_name cannot be empty");
        if (self.base_import_path.len == 0) @compileError("MixinConfig.base_import_path cannot be empty");
        if (self.extension_import_path.len == 0) @compileError("MixinConfig.extension_import_path cannot be empty");
        if (self.file_name) |file_name| {
            if (file_name.len == 0) @compileError("MixinConfig.file_name cannot be empty");
        }
        if (resolvedBaseImportName(self).len == 0) @compileError("MixinConfig.base_import_name cannot resolve to an empty value");
        if (resolvedExtensionImportName(self).len == 0) @compileError("MixinConfig.extension_import_name cannot resolve to an empty value");
        if (resolvedBaseTypeRef(self).len == 0) @compileError("MixinConfig.base_type_ref cannot resolve to an empty value");
        if (resolvedExtensionTypeRef(self).len == 0) @compileError("MixinConfig.extension_type_ref cannot resolve to an empty value");
    }
};

pub const GeneratedMixin = struct {
    type_name: []const u8,
    file_name: []const u8,
    source: []const u8,
};

pub const GeneratedFile = struct {
    file_name: []const u8,
    source: []const u8,
};

pub const ModuleConfig = struct {
    file_name: []const u8 = "generated_mixin.zig",
    emit_header_comment: bool = true,
};

pub const MixinInput = struct {
    base: type,
    extension: type,
};

pub const Contract = generator.Generator(MixinInput, MixinConfig);

pub const ConflictStrategy = enum {
    /// Extension methods override base methods
    extension_wins,
    /// Base methods take precedence
    base_wins,
    /// Error on any conflict
    error_on_conflict,
};

const MethodBinding = struct {
    method_name: []const u8,
    func_info: reflect.FuncInfo,
    field_name: []const u8,
};

const SkippedMethod = struct {
    method_name: []const u8,
    preferred_field_name: []const u8,
};

const MixinPlan = struct {
    input: MixinInput,
    config: MixinConfig,
    base_info: reflect.TypeInfo,
    extension_info: reflect.TypeInfo,
    bindings: []const MethodBinding,
    skipped_conflicts: []const SkippedMethod,
};

pub const MixinGenerator = Contract.wrap(struct {
    pub fn validateInput(comptime input: MixinInput) void {
        _ = resolveTypeInfo(input.base, "base");
        _ = resolveTypeInfo(input.extension, "extension");
    }

    pub fn validateConfig(comptime config: MixinConfig) void {
        config.validate();
    }

    pub fn generate(comptime input: MixinInput, comptime config: MixinConfig) GeneratedMixin {
        @setEvalBranchQuota(20_000);
        return .{
            .type_name = config.type_name,
            .file_name = resolvedFileName(config),
            .source = emitPlan(buildPlan(input, config)),
        };
    }
});

/// Generate mixin code at comptime
///
/// *Must be called at comptime.*
///
/// *Experimental*
pub fn generateMixinCode(
    comptime Base: type,
    comptime Extension: type,
    comptime config: MixinConfig,
) []const u8 {
    return MixinGenerator.generate(.{ .base = Base, .extension = Extension }, config).source;
}

pub fn generate(comptime input: MixinInput, comptime config: MixinConfig) GeneratedMixin {
    return MixinGenerator.generate(input, config);
}

pub fn generateModule(comptime mixins: []const GeneratedMixin, comptime config: ModuleConfig) GeneratedFile {
    var source: []const u8 = "";

    if (config.emit_header_comment) {
        source = source ++ "// Generated at build time by zevy_reflect mixin_generator\n";
        source = source ++ "// This file is auto-generated - do not edit manually\n\n";
    }

    for (mixins) |mixin| {
        source = source ++ std.fmt.comptimePrint(
            "pub const {s} = @import(\"{s}\").{s};\n",
            .{ mixin.type_name, mixin.file_name, mixin.type_name },
        );
    }

    return .{
        .file_name = config.file_name,
        .source = source,
    };
}

fn emitInitMethods(comptime config: MixinConfig) []const u8 {
    var code: []const u8 = "";
    code = code ++ "    /// Initialize the mixin with base and extension values\n";
    code = code ++ std.fmt.comptimePrint("    pub fn init(base: {s}, extension: {s}) {s} {{\n", .{ resolvedBaseTypeRef(config), resolvedExtensionTypeRef(config), config.type_name });
    code = code ++ "        return .{\n";
    code = code ++ "            .base = base,\n";
    code = code ++ "            .extension = extension,\n";
    code = code ++ "        };\n";
    code = code ++ "    }\n\n";

    if (config.emit_init_base) {
        code = code ++ "    /// Initialize with default extension values\n";
        code = code ++ std.fmt.comptimePrint("    pub fn initBase(base: {s}) {s} {{\n", .{ resolvedBaseTypeRef(config), config.type_name });
        code = code ++ "        return .{\n";
        code = code ++ "            .base = base,\n";
        code = code ++ std.fmt.comptimePrint("            .extension = {s}{{}},\n", .{resolvedExtensionTypeRef(config)});
        code = code ++ "        };\n";
        code = code ++ "    }\n\n";
    }

    return code;
}

fn buildPlan(comptime input: MixinInput, comptime config: MixinConfig) MixinPlan {
    const base_info = resolveTypeInfo(input.base, "base");
    const extension_info = resolveTypeInfo(input.extension, "extension");

    var bindings: []const MethodBinding = &.{};
    var skipped_conflicts: []const SkippedMethod = &.{};

    const first_is_base = config.conflict_strategy == .base_wins;
    const first_type = if (first_is_base) input.base else input.extension;
    const first_info = if (first_is_base) base_info else extension_info;
    const first_field_name = if (first_is_base) "base" else "extension";

    const second_type = if (first_is_base) input.extension else input.base;
    const second_info = if (first_is_base) extension_info else base_info;
    const second_field_name = if (first_is_base) "extension" else "base";

    for (first_info.getFuncNames()) |method_name| {
        const func_info = first_info.getFunc(method_name) orelse continue;
        if (!isMixinMethod(func_info, first_type)) continue;

        bindings = bindings ++ &[_]MethodBinding{.{
            .method_name = method_name,
            .func_info = func_info,
            .field_name = first_field_name,
        }};
    }

    for (second_info.getFuncNames()) |method_name| {
        const func_info = second_info.getFunc(method_name) orelse continue;
        if (!isMixinMethod(func_info, second_type)) continue;

        if (containsMethod(bindings, method_name)) {
            if (config.conflict_strategy == .error_on_conflict) {
                @compileError(std.fmt.comptimePrint(
                    "Method name conflict while generating mixin {s}: {s}",
                    .{ config.type_name, method_name },
                ));
            }

            skipped_conflicts = skipped_conflicts ++ &[_]SkippedMethod{.{
                .method_name = method_name,
                .preferred_field_name = first_field_name,
            }};
            continue;
        }

        bindings = bindings ++ &[_]MethodBinding{.{
            .method_name = method_name,
            .func_info = func_info,
            .field_name = second_field_name,
        }};
    }

    return .{
        .input = input,
        .config = config,
        .base_info = base_info,
        .extension_info = extension_info,
        .bindings = bindings,
        .skipped_conflicts = skipped_conflicts,
    };
}

fn resolveTypeInfo(comptime T: type, comptime role: []const u8) reflect.TypeInfo {
    const info = reflect.getInfo(T);
    return info.getTypeInfo() orelse @compileError(std.fmt.comptimePrint(
        "Mixin {s} must be a concrete type, found {s}",
        .{ role, @typeName(T) },
    ));
}

fn emitPlan(comptime plan: MixinPlan) []const u8 {
    var code: []const u8 = "";

    code = code ++ "// Auto-generated mixin combining ";
    code = code ++ reflect.getSimpleTypeName(plan.input.base);
    code = code ++ " and ";
    code = code ++ reflect.getSimpleTypeName(plan.input.extension);
    code = code ++ "\n\n";

    code = code ++ "const std = @import(\"std\");\n";
    code = code ++ std.fmt.comptimePrint("const {s} = @import(\"{s}\");\n", .{ resolvedBaseImportName(plan.config), plan.config.base_import_path });
    code = code ++ std.fmt.comptimePrint("const {s} = @import(\"{s}\");\n\n", .{ resolvedExtensionImportName(plan.config), plan.config.extension_import_path });

    code = code ++ std.fmt.comptimePrint("pub const {s} = struct {{\n", .{plan.config.type_name});
    code = code ++ std.fmt.comptimePrint("    base: {s},\n", .{resolvedBaseTypeRef(plan.config)});
    code = code ++ std.fmt.comptimePrint("    extension: {s},\n\n", .{resolvedExtensionTypeRef(plan.config)});

    if (plan.config.emit_field_comments) {
        code = code ++ emitFieldComments("Base", plan.base_info);
        code = code ++ emitFieldComments("Extension", plan.extension_info);
    }

    code = code ++ emitInitMethods(plan.config);
    code = code ++ emitMethodWrappers(plan);
    code = code ++ "};\n";

    return code;
}

fn emitFieldComments(comptime label: []const u8, comptime info: reflect.TypeInfo) []const u8 {
    var code: []const u8 = "";
    code = code ++ std.fmt.comptimePrint("    // {s} fields\n", .{label});
    for (info.fields) |field| {
        code = code ++ std.fmt.comptimePrint("    // {s}: {s}\n", .{ field.name, field.type.name });
    }
    code = code ++ "\n";
    return code;
}

fn emitMethodWrappers(comptime plan: MixinPlan) []const u8 {
    var code: []const u8 = "";

    for (plan.bindings) |binding| {
        code = code ++ std.fmt.comptimePrint("    // Method from {s}\n", .{binding.field_name});
        code = code ++ generateMethodWrapper(binding.method_name, binding.func_info, binding.field_name);
    }

    if (plan.config.emit_conflict_comments) {
        for (plan.skipped_conflicts) |skipped| {
            code = code ++ std.fmt.comptimePrint(
                "    // Skipping {s} because {s} wins the conflict\n",
                .{ skipped.method_name, skipped.preferred_field_name },
            );
        }
        if (plan.skipped_conflicts.len > 0) {
            code = code ++ "\n";
        }
    }

    return code;
}

fn containsMethod(comptime bindings: []const MethodBinding, comptime method_name: []const u8) bool {
    for (bindings) |binding| {
        if (std.mem.eql(u8, binding.method_name, method_name)) return true;
    }
    return false;
}

fn isMixinMethod(comptime func_info: reflect.FuncInfo, comptime T: type) bool {
    if (func_info.category == .Generic) return false;
    if (func_info.paramsCount() == 0) return false;
    return isSelfParameter(func_info.params()[0], T);
}

fn resolvedBaseImportName(comptime config: MixinConfig) []const u8 {
    return config.base_import_name orelse config.base_type_name;
}

fn resolvedFileName(comptime config: MixinConfig) []const u8 {
    return config.file_name orelse std.fmt.comptimePrint("{s}.zig", .{config.type_name});
}

fn resolvedBaseTypeRef(comptime config: MixinConfig) []const u8 {
    return config.base_type_ref orelse config.base_type_name;
}

fn resolvedExtensionImportName(comptime config: MixinConfig) []const u8 {
    return config.extension_import_name orelse config.extension_type_name;
}

fn resolvedExtensionTypeRef(comptime config: MixinConfig) []const u8 {
    return config.extension_type_ref orelse config.extension_type_name;
}

fn isSelfParameter(param: reflect.ParamInfo, comptime T: type) bool {
    const param_type = param.info.type;

    if (param_type == T) return true;

    if (@typeInfo(param_type) == .pointer) {
        const child = @typeInfo(param_type).pointer.child;
        if (child == T) return true;
    }

    return false;
}

/// Generate a valid Zig type name string from a type
pub fn generateTypeName(comptime T: type) []const u8 {
    const type_info = @typeInfo(T);

    return switch (type_info) {
        .pointer => |ptr| {
            const child_name = comptime generateTypeName(ptr.child);
            if (ptr.size == .slice) {
                if (ptr.is_const) {
                    return comptime "[]const " ++ child_name;
                } else {
                    return comptime "[]" ++ child_name;
                }
            } else {
                // Single/many/c pointer
                const const_prefix = if (ptr.is_const) "*const " else "*";
                return comptime const_prefix ++ child_name;
            }
        },
        .optional => |opt| {
            const child_name = comptime generateTypeName(opt.child);
            return comptime "?" ++ child_name;
        },
        .array => |arr| {
            const child_name = comptime generateTypeName(arr.child);
            return comptime std.fmt.comptimePrint("[{d}]{s}", .{ arr.len, child_name });
        },
        .int, .float, .bool, .void, .@"struct", .@"enum", .@"union" => @typeName(T),
        else => @typeName(T),
    };
}

fn generateMethodWrapper(
    comptime method_name: []const u8,
    comptime func_info: reflect.FuncInfo,
    comptime field_name: []const u8,
) []const u8 {
    var code: []const u8 = "";

    // Method signature
    code = code ++ std.fmt.comptimePrint("    pub fn {s}(", .{method_name});

    // Generate parameters
    var first_param = true;
    for (func_info.params(), 0..) |param, i| {
        if (i == 0) {
            // Self parameter - determine mutability
            const is_const = blk: {
                const pt = param.info.type;
                if (@typeInfo(pt) == .pointer) {
                    const ptr_info = @typeInfo(pt).pointer;
                    break :blk ptr_info.is_const;
                }
                break :blk false;
            };

            if (is_const) {
                code = code ++ "self: *const @This()";
            } else {
                code = code ++ "self: *@This()";
            }
            first_param = false;
            continue;
        }

        if (!first_param) code = code ++ ", ";

        // Generate parameter
        const param_name = std.fmt.comptimePrint("arg{d}", .{i});
        const param_type = generateTypeName(param.info.type);
        code = code ++ std.fmt.comptimePrint("{s}: {s}", .{ param_name, param_type });
        first_param = false;
    }

    code = code ++ ") ";

    // Return type
    code = code ++ generateTypeName(func_info.return_type.info.type);

    code = code ++ " {\n";

    // Method body - forward call
    code = code ++ "        ";
    if (func_info.return_type.info.type != void) {
        code = code ++ "return ";
    }
    code = code ++ std.fmt.comptimePrint("self.{s}.{s}(", .{ field_name, method_name });

    // Forward arguments (skip self)
    var first_arg = true;
    for (1..func_info.paramsCount()) |i| {
        if (!first_arg) code = code ++ ", ";
        code = code ++ std.fmt.comptimePrint("arg{d}", .{i});
        first_arg = false;
    }

    code = code ++ ");\n";
    code = code ++ "    }\n\n";

    return code;
}

/// Runtime version that writes to a file
pub fn generateMixinToFile(
    io: std.Io,
    allocator: std.mem.Allocator,
    comptime Base: type,
    comptime Extension: type,
    comptime config: MixinConfig,
    output_path: []const u8,
) !void {
    _ = allocator;
    try MixinGenerator.generateToFile(io, .{ .base = Base, .extension = Extension }, config, output_path);
    std.debug.print("Generated mixin: {s}\n", .{output_path});
}

test "mixin generator emits wrapper methods and comments" {
    const Base = struct {
        health: i32 = 100,

        pub fn takeDamage(self: *@This(), amount: i32) void {
            self.health -= amount;
        }
    };

    const Extension = struct {
        log_count: usize = 0,

        pub fn log(self: *@This(), message: []const u8) void {
            _ = message;
            self.log_count += 1;
        }
    };

    const generated = comptime generate(
        .{ .base = Base, .extension = Extension },
        .{
            .type_name = "LoggableBase",
            .file_name = "loggable_base.zig",
            .base_type_name = "Base",
            .extension_type_name = "Extension",
            .base_import_path = "base.zig",
            .extension_import_path = "extension.zig",
        },
    );

    try std.testing.expect(std.mem.eql(u8, generated.file_name, "loggable_base.zig"));
    try std.testing.expect(std.mem.indexOf(u8, generated.source, "pub const LoggableBase = struct") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated.source, "pub fn takeDamage(self: *@This(), arg1: i32) void") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated.source, "self.base.takeDamage(arg1);") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated.source, "self.extension.log(arg1);") != null);
}

test "mixin generator honors base_wins conflicts" {
    const Base = struct {
        pub fn label(self: *const @This()) []const u8 {
            _ = self;
            return "base";
        }
    };

    const Extension = struct {
        pub fn label(self: *const @This()) []const u8 {
            _ = self;
            return "extension";
        }
    };

    const generated = comptime generate(
        .{ .base = Base, .extension = Extension },
        .{
            .type_name = "NamedBase",
            .file_name = "named_base.zig",
            .base_type_name = "Base",
            .extension_type_name = "Extension",
            .base_import_path = "base.zig",
            .extension_import_path = "extension.zig",
            .conflict_strategy = .base_wins,
        },
    );

    try std.testing.expect(std.mem.indexOf(u8, generated.source, "return self.base.label();") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated.source, "return self.extension.label();") == null);
    try std.testing.expect(std.mem.indexOf(u8, generated.source, "Skipping label because base wins the conflict") != null);
}

test "mixin generator can disable initBase emission" {
    const Base = struct {};
    const Extension = struct {};

    const generated = comptime generate(
        .{ .base = Base, .extension = Extension },
        .{
            .type_name = "PlainMixin",
            .file_name = "plain_mixin.zig",
            .base_type_name = "Base",
            .extension_type_name = "Extension",
            .base_import_path = "base.zig",
            .extension_import_path = "extension.zig",
            .emit_init_base = false,
        },
    );

    try std.testing.expect(std.mem.indexOf(u8, generated.source, "pub fn initBase") == null);
}

test "mixin module source is generated" {
    const mixin_a: GeneratedMixin = .{
        .type_name = "LoggableEntity",
        .file_name = "loggable_entity.zig",
        .source = "pub const LoggableEntity = struct {};\n",
    };
    const mixin_b: GeneratedMixin = .{
        .type_name = "NamedEntity",
        .file_name = "named_entity.zig",
        .source = "pub const NamedEntity = struct {};\n",
    };

    const generated = comptime generateModule(&.{ mixin_a, mixin_b }, .{});

    try std.testing.expect(std.mem.eql(u8, generated.file_name, "generated_mixin.zig"));
    try std.testing.expect(std.mem.indexOf(u8, generated.source, "pub const LoggableEntity = @import(\"loggable_entity.zig\").LoggableEntity;") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated.source, "pub const NamedEntity = @import(\"named_entity.zig\").NamedEntity;") != null);
}
