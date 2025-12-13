const std = @import("std");
const reflect = @import("../reflect.zig");

/// Configuration for mixin generation
pub const MixinConfig = struct {
    /// Name for the generated mixin type
    type_name: []const u8,
    /// Name of the base type (for imports)
    base_type_name: []const u8,
    /// Name of the extension type (for imports)
    extension_type_name: []const u8,
    /// Module path for base type (e.g., "player.Player")
    base_import_path: []const u8,
    /// Module path for extension type (e.g., "loggable.Loggable")
    extension_import_path: []const u8,
    /// Strategy for handling method name conflicts
    conflict_strategy: ConflictStrategy = .extension_wins,
};

pub const ConflictStrategy = enum {
    /// Extension methods override base methods
    extension_wins,
    /// Base methods take precedence
    base_wins,
    /// Error on any conflict
    error_on_conflict,
};

/// Generate mixin code at comptime
///
/// *Experimental*
pub fn generateMixinCode(
    comptime Base: type,
    comptime Extension: type,
    comptime config: MixinConfig,
) []const u8 {
    const base_info = reflect.getTypeInfo(Base);
    const ext_info = reflect.getTypeInfo(Extension);

    var code: []const u8 = "";

    // Header comment
    code = code ++ "// Auto-generated mixin combining " ++
        reflect.getSimpleTypeName(Base) ++ " and " ++
        reflect.getSimpleTypeName(Extension) ++ "\n\n";

    // Imports
    code = code ++ "const std = @import(\"std\");\n";
    code = code ++ std.fmt.comptimePrint("const {s} = @import(\"{s}\");\n", .{ config.base_type_name, config.base_import_path });
    code = code ++ std.fmt.comptimePrint("const {s} = @import(\"{s}\");\n\n", .{ config.extension_type_name, config.extension_import_path });

    // Struct declaration
    code = code ++ std.fmt.comptimePrint("pub const {s} = struct {{\n", .{config.type_name});

    // Embedded fields
    code = code ++ std.fmt.comptimePrint("    base: {s},\n", .{config.base_type_name});
    code = code ++ std.fmt.comptimePrint("    extension: {s},\n\n", .{config.extension_type_name});

    // Collect base fields
    code = code ++ "    // Base fields\n";
    for (base_info.fields) |field| {
        code = code ++ std.fmt.comptimePrint("    // {s}: {s} (from base)\n", .{ field.name, field.type.name });
    }
    code = code ++ "\n";

    // Collect extension fields
    code = code ++ "    // Extension fields\n";
    for (ext_info.fields) |field| {
        code = code ++ std.fmt.comptimePrint("    // {s}: {s} (from extension)\n", .{ field.name, field.type.name });
    }
    code = code ++ "\n";

    // Init method
    code = code ++ generateInitMethod(config);

    // Generate method wrappers
    code = code ++ generateMethodWrappers(Base, Extension, config);

    // Close struct
    code = code ++ "};\n";

    return code;
}

fn generateInitMethod(comptime config: MixinConfig) []const u8 {
    var code: []const u8 = "";
    code = code ++ "    /// Initialize the mixin with base and extension values\n";
    code = code ++ std.fmt.comptimePrint("    pub fn init(base: {s}, extension: {s}) {s} {{\n", .{ config.base_type_name, config.extension_type_name, config.type_name });
    code = code ++ "        return .{\n";
    code = code ++ "            .base = base,\n";
    code = code ++ "            .extension = extension,\n";
    code = code ++ "        };\n";
    code = code ++ "    }\n\n";

    code = code ++ "    /// Initialize with default extension values\n";
    code = code ++ std.fmt.comptimePrint("    pub fn initBase(base: {s}) {s} {{\n", .{ config.base_type_name, config.type_name });
    code = code ++ "        return .{\n";
    code = code ++ "            .base = base,\n";
    code = code ++ std.fmt.comptimePrint("            .extension = {s}{{}},\n", .{config.extension_type_name});
    code = code ++ "        };\n";
    code = code ++ "    }\n\n";

    return code;
}

fn generateMethodWrappers(
    comptime Base: type,
    comptime Extension: type,
    comptime config: MixinConfig,
) []const u8 {
    const base_info = reflect.getTypeInfo(Base);
    const ext_info = reflect.getTypeInfo(Extension);

    const base_methods = base_info.getFuncNames();
    const ext_methods = ext_info.getFuncNames();

    var code: []const u8 = "";
    var generated_methods: []const []const u8 = &.{};

    // Generate extension methods first (or last based on strategy)
    const first_type = if (config.conflict_strategy == .base_wins) Base else Extension;
    const second_type = if (config.conflict_strategy == .base_wins) Extension else Base;
    const first_is_base = first_type == Base;

    // First pass
    const first_methods = if (first_is_base) base_methods else ext_methods;
    const first_name = if (first_is_base) "base" else "extension";
    const first_info = if (first_is_base) base_info else ext_info;

    code = code ++ std.fmt.comptimePrint("    // Methods from {s}\n", .{first_name});
    for (first_methods) |method_name| {
        const func_info = first_info.getFunc(method_name) orelse continue;

        // Skip if not a method (no self parameter)
        if (func_info.params.len == 0) continue;
        if (!isSelfParameter(func_info.params[0], first_type)) continue;

        code = code ++ generateMethodWrapper(method_name, func_info, first_name, first_type);
        generated_methods = generated_methods ++ &[_][]const u8{method_name};
    }
    code = code ++ "\n";

    // Second pass - skip conflicts
    const second_methods = if (first_is_base) ext_methods else base_methods;
    const second_name = if (first_is_base) "extension" else "base";
    const second_info = if (first_is_base) ext_info else base_info;

    code = code ++ std.fmt.comptimePrint("    // Methods from {s}\n", .{second_name});
    for (second_methods) |method_name| {
        // Check for conflict
        var has_conflict = false;
        for (generated_methods) |gen_method| {
            if (std.mem.eql(u8, method_name, gen_method)) {
                has_conflict = true;
                break;
            }
        }

        if (has_conflict) {
            if (config.conflict_strategy == .error_on_conflict) {
                @compileError("Method name conflict: " ++ method_name);
            }
            code = code ++ std.fmt.comptimePrint("    // Skipping {s} (conflicts with {s})\n", .{ method_name, first_name });
            continue;
        }

        const func_info = second_info.getFunc(method_name) orelse continue;

        if (func_info.params.len == 0) continue;
        if (!isSelfParameter(func_info.params[0], second_type)) continue;

        code = code ++ generateMethodWrapper(method_name, func_info, second_name, second_type);
    }

    return code;
}

fn isSelfParameter(param: reflect.ReflectInfo, comptime T: type) bool {
    if (param != .type) return false;
    const param_type = param.type.type;

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
    comptime FieldType: type,
) []const u8 {
    _ = FieldType;
    var code: []const u8 = "";

    // Method signature
    code = code ++ std.fmt.comptimePrint("    pub fn {s}(", .{method_name});

    // Generate parameters
    var first_param = true;
    for (func_info.params, 0..) |param, i| {
        if (i == 0) {
            // Self parameter - determine mutability
            const is_const = blk: {
                if (param == .type) {
                    const pt = param.type.type;
                    if (@typeInfo(pt) == .pointer) {
                        const ptr_info = @typeInfo(pt).pointer;
                        break :blk ptr_info.is_const;
                    }
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
        const param_type = switch (param) {
            .type => |ti| generateTypeName(ti.type),
            else => "anytype",
        };
        code = code ++ std.fmt.comptimePrint("{s}: {s}", .{ param_name, param_type });
        first_param = false;
    }

    code = code ++ ") ";

    // Return type
    if (func_info.return_type) |ret| {
        const ret_type = switch (ret) {
            .type => |ti| generateTypeName(ti.type),
            else => "void",
        };
        code = code ++ ret_type;
    } else {
        code = code ++ "void";
    }

    code = code ++ " {\n";

    // Method body - forward call
    code = code ++ "        ";
    if (func_info.return_type != null) {
        code = code ++ "return ";
    }
    code = code ++ std.fmt.comptimePrint("self.{s}.{s}(", .{ field_name, method_name });

    // Forward arguments (skip self)
    var first_arg = true;
    for (1..func_info.params.len) |i| {
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
    allocator: std.mem.Allocator,
    comptime Base: type,
    comptime Extension: type,
    comptime config: MixinConfig,
    output_path: []const u8,
) !void {
    _ = allocator;
    const generated_code = generateMixinCode(Base, Extension, config);

    const file = try std.fs.cwd().createFile(output_path, .{});
    defer file.close();

    try file.writeAll(generated_code);

    std.debug.print("Generated mixin: {s}\n", .{output_path});
}

test "generate mixin code" {
    const Base = struct {
        pub fn greet(self: *@This()) void {
            _ = self;
        }
    };

    const Extension = struct {
        pub fn farewell(self: *@This()) void {
            _ = self;
        }
    };

    const config = MixinConfig{
        .type_name = "GreeterFareweller",
        .base_type_name = "Base",
        .extension_type_name = "Extension",
        .base_import_path = "base.zig",
        .extension_import_path = "extension.zig",
        .conflict_strategy = .extension_wins,
    };

    const code = generateMixinCode(Base, Extension, config);
    std.debug.print("Generated Mixin Code:\n{s}\n", .{code});
}
