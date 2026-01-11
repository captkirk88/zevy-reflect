const std = @import("std");
const util = @import("utils.zig");

pub inline fn typeHash(comptime T: type) u64 {
    const name = @typeName(T);
    return std.hash.Wyhash.hash(0, name);
}

pub inline fn typeHashWithSeed(comptime T: type, seed: u64) u64 {
    const name = @typeName(T);
    return std.hash.Wyhash.hash(seed, name);
}

pub inline fn hash(data: []const u8) u64 {
    return std.hash.Wyhash.hash(0, data);
}

pub inline fn hashWithSeed(data: []const u8, seed: u64) u64 {
    return std.hash.Wyhash.hash(seed, data);
}

/// Cache entry for visited types - stores the std.builtin.Type
const CacheEntry = struct {
    hash: u64,
    builtin: std.builtin.Type,
};

/// Internal shared storage for visited types (comptime-only).
fn visitedCache() *[]const CacheEntry {
    comptime var data: []const CacheEntry = &[_]CacheEntry{};
    return &data;
}

/// Look up a previously-visited type by hash.
/// Returns the cached builtin if found, null otherwise.
fn lookupVisitedByHash(comptime hash_val: u64) ?std.builtin.Type {
    const data = visitedCache().*;
    for (data) |entry| {
        if (entry.hash == hash_val) return entry.builtin;
    }
    return null;
}

/// Check if a type has been visited and return cached ReflectInfo if so.
fn isVisited(comptime T: type) ?std.builtin.Type {
    const h = typeHash(T);
    if (lookupVisitedByHash(h)) |info| return info;
    return null;
}

/// Mark a type as visited with its ReflectInfo.
fn markVisited(comptime T: type, comptime builtin: std.builtin.Type) void {
    const data_ptr = visitedCache();
    const h = typeHash(T);
    // Check if already visited
    for (data_ptr.*) |entry| {
        if (entry.hash == h) return;
    }
    data_ptr.* = data_ptr.* ++ [_]CacheEntry{.{ .hash = h, .builtin = builtin }};
}

/// Shallow type information for field types - doesn't recurse into nested types.
/// This avoids comptime explosion when reflecting complex types with many nested fields.
pub const ShallowTypeInfo = struct {
    type: type,
    name: []const u8,
    size: usize,
    category: TypeInfo.Category,

    pub fn from(comptime T: type) ShallowTypeInfo {
        return ShallowTypeInfo{
            .type = T,
            .name = @typeName(T),
            .size = safeSizeOf(T),
            .category = TypeInfo.Category.from(T),
        };
    }

    /// Get full TypeInfo for this type (computed lazily)
    pub fn getFullInfo(self: *const ShallowTypeInfo) TypeInfo {
        return comptime TypeInfo.from(self.type);
    }

    pub fn eql(self: *const ShallowTypeInfo, other: *const ShallowTypeInfo) bool {
        return self.type == other.type;
    }
};

pub const FieldInfo = struct {
    name: []const u8,
    offset: usize,
    type: ShallowTypeInfo,
    container_type: ShallowTypeInfo,

    pub fn from(comptime T: type, comptime field_name: []const u8) ?FieldInfo {
        const type_info = @typeInfo(T);
        const container_type = ShallowTypeInfo.from(T);
        const fields = blk: {
            if (type_info == .@"struct") break :blk type_info.@"struct".fields;
            if (type_info == .@"enum") break :blk type_info.@"enum".fields;
            if (type_info == .@"union") break :blk type_info.@"union".fields;
            return null;
        };
        for (fields) |field| {
            if (std.mem.eql(u8, field.name, field_name)) {
                return comptime FieldInfo{
                    .name = field.name,
                    .offset = @offsetOf(T, field.name),
                    .type = ShallowTypeInfo.from(field.type),
                    .container_type = container_type,
                };
            }
        }
        return null;
    }

    pub fn fromReflect(container_info: *const ReflectInfo, comptime field_name: []const u8) ?FieldInfo {
        switch (container_info.*) {
            .type => |ti| {
                if (ti.getField(field_name)) |f| {
                    f.container_type = ti;
                    return f;
                } else {
                    return null;
                }
            },
            else => return null,
        }
    }

    /// Get the value of this field from the given instance.
    pub fn get(self: *const FieldInfo, inst: *self.container_type.type) self.type.type {
        return @as(self.type.type, @field(inst, self.name));
    }

    /// Set the value of this field on the given instance.
    pub fn set(self: *const FieldInfo, inst: *self.container_type.type, value: self.type.type) void {
        @field(inst, self.name) = value;
    }

    /// Check if this FieldInfo is equal to another
    ///
    /// *Must be called at comptime.*
    pub fn eql(self: *const FieldInfo, other: *const FieldInfo) bool {
        return self.container_type.eql(&other.container_type) and std.mem.eql(u8, self.name, other.name);
    }
};

pub const ParamInfo = struct {
    info: ReflectInfo,
    /// Whether this parameter is marked `noalias`
    is_noalias: bool = false,
    is_comptime: bool = false,

    pub fn eql(self: *const ParamInfo, other: *const ParamInfo) bool {
        return self.is_noalias == other.is_noalias and self.is_comptime == other.is_comptime and self.info.eql(&other.info);
    }
};

pub const FuncInfo = struct {
    hash: u64,
    name: []const u8,
    params: []const ParamInfo,
    return_type: ReflectInfo,
    container_type: ?ShallowTypeInfo = null,
    type: ShallowTypeInfo,
    category: Category,

    pub const Category = enum {
        Func,
        Method,
        Generic,

        fn from(comptime T: type) Category {
            const ti = @typeInfo(T);
            // Check if this is a generic function (returns type)
            if (ti == .@"fn") {
                // Can't determine method vs func without full reflection
                // Just check if it's generic by looking at return type
                if (ti.@"fn".return_type) |ret| {
                    if (ret == type) return .Generic;
                }
                // Check first param to see if it's a method (pointer to struct/union/enum)
                if (ti.@"fn".params.len > 0) {
                    const first_param = ti.@"fn".params[0];
                    if (first_param.type) |pt| {
                        const pti = @typeInfo(pt);
                        if (pti == .pointer) {
                            const child_ti = @typeInfo(pti.pointer.child);
                            if (child_ti == .@"struct" or child_ti == .@"union" or child_ti == .@"enum") {
                                return .Method;
                            }
                        }
                    }
                }
                return .Func;
            }
            // Type that is a generic type constructor
            const name = @typeName(T);
            for (name) |c| {
                if (c == '(') return .Generic;
            }
            return .Func;
        }
    };

    /// Create FuncInfo from a function type
    pub inline fn from(comptime FuncType: type) ?FuncInfo {
        return comptime toFuncInfo(FuncType);
    }

    /// Create FuncInfo for a method of a struct given the struct's TypeInfo and method name
    fn fromMethod(comptime type_info: *const TypeInfo, comptime func_name: []const u8) ?FuncInfo {
        const ti = @typeInfo(type_info.type);
        // Only struct/union/enum containers support methods
        if (type_info.category != .Struct and type_info.category != .Union and type_info.category != .Enum and type_info.category != .Opaque) {
            return null;
        }

        inline for (_getDecls(ti)) |decl| {
            if (std.mem.eql(u8, decl.name, func_name)) {
                const DeclType: type = @TypeOf(@field(type_info.type, decl.name));
                const fn_type_info = @typeInfo(DeclType);
                if (fn_type_info != .@"fn") {
                    @compileError(std.fmt.comptimePrint(
                        "Declared member '{s}'' is not a function of type '{s}'",
                        .{ func_name, @typeName(type_info.type) },
                    ));
                }

                var param_infos: [fn_type_info.@"fn".params.len]ParamInfo = undefined;
                var pi_i: usize = 0;
                inline for (fn_type_info.@"fn".params) |param| {
                    const p_t = param.type orelse void;
                    param_infos[pi_i] = ParamInfo{ .info = ReflectInfo{ .raw = p_t }, .is_noalias = false, .is_comptime = false };
                    pi_i += 1;
                }

                const return_ref: ReflectInfo = if (fn_type_info.@"fn".return_type) |r| ReflectInfo{ .raw = r } else ReflectInfo.unknown;

                return FuncInfo{
                    .hash = typeHash(DeclType),
                    .name = decl.name,
                    .params = param_infos[0..pi_i],
                    .container_type = ShallowTypeInfo.from(type_info.type),
                    .return_type = return_ref,
                };
            }
        }
        return null;
    }

    pub fn getParam(self: *const FuncInfo, index: usize) ?TypeInfo {
        if (index >= self.params.len) return null;
        return switch (self.params[index].info) {
            .type => |ti| ti,
            else => null,
        };
    }

    pub fn paramsCount(self: *const FuncInfo) usize {
        return self.params.len;
    }

    /// Invoke the function with the given arguments.
    ///
    /// args: A tuple of arguments to pass to the function.
    pub inline fn invoke(comptime self: *const FuncInfo, args: anytype) InvokeReturnType(self) {
        const func = self.funcPointer();
        const FuncType = @TypeOf(func);
        const ArgsType = @TypeOf(args);
        const args_info = @typeInfo(ArgsType);

        // Support either a tuple of args (typical .{...}) or a single non-tuple value
        var arg_len: usize = 0;
        const args_is_tuple = switch (args_info) {
            .@"struct" => |s| s.is_tuple,
            else => false,
        };
        if (args_is_tuple) {
            const s = switch (args_info) {
                .@"struct" => |s| s,
                else => unreachable,
            };
            arg_len = s.fields.len;
        } else {
            // Non-struct args are treated as a single argument value
            arg_len = 1;
        }

        // Ensure argument count matches (will assert at runtime)
        std.debug.assert(arg_len == self.params.len);

        var typed_args: std.meta.ArgsTuple(FuncType) = undefined;

        inline for (self.params, 0..) |param, i| {
            const param_info = param.info;
            typed_args[i] = blk: switch (param_info) {
                .type => |ti| {
                    if (ti.category == .Pointer) {
                        if (args_is_tuple) {
                            break :blk @as(ti.type, args[i]);
                        } else {
                            // Single arg case
                            break :blk @as(ti.type, args);
                        }
                    } else {
                        if (args_is_tuple) {
                            break :blk @as(ti.type, args[i]);
                        } else {
                            // Single arg case
                            break :blk @as(ti.type, args);
                        }
                    }
                },
                .func => |fi| {
                    if (args_is_tuple) {
                        break :blk @as(fi.type.type, args[i]);
                    } else {
                        // Single arg case
                        break :blk @as(fi.type.type, args);
                    }
                },
                .raw => |ty| {
                    if (args_is_tuple) {
                        break :blk @as(ty, args[i]);
                    } else {
                        // Single arg case
                        break :blk @as(ty, args);
                    }
                },
            };
        }

        return @call(.auto, func, typed_args);
    }

    fn InvokeReturnType(comptime self: *const FuncInfo) type {
        const func = funcPointer(self);
        return @typeInfo(@TypeOf(func)).@"fn".return_type orelse void;
    }

    pub inline fn toPtr(comptime self: *const FuncInfo) FnPtrType(self) {
        if (self.container_type) |ct| {
            return &@field(ct.type, self.name);
        }
        return &@field(self.type.type, self.name);
    }

    fn FnPtrType(comptime self: *const FuncInfo) type {
        return *const @TypeOf(self.funcPointer());
    }

    fn funcPointer(comptime self: *const FuncInfo) (if (self.container_type != null)
        @TypeOf(@field(self.container_type.?.type, self.name))
    else
        self.type.type) {
        if (self.container_type) |ct| {
            return @field(ct.type, self.name);
        }

        return self.type.type;
    }
    /// Get a string representation of the function signature
    ///
    /// *Does not need to be called at comptime.*
    pub inline fn toString(self: *const FuncInfo) []const u8 {
        return comptime self.getStringRepresentation(false, true);
    }

    /// Get a string representation of the function signature
    ///
    /// `omit_self`: If true, omits the first parameter (commonly `self` in methods).
    ///
    /// `simple_names`: If true, uses simple type names without module paths.
    ///
    /// *Does not need to be called at comptime.*
    pub inline fn toStringEx(self: *const FuncInfo, omit_self: bool, simple_names: bool) []const u8 {
        return comptime self.getStringRepresentation(omit_self, simple_names);
    }

    /// Check if this FuncInfo is equal to another
    ///
    /// *Must be called at comptime.*
    pub fn eql(self: *const FuncInfo, other: *const FuncInfo) bool {
        if (!std.mem.eql(u8, self.name, other.name)) return false;
        if (self.params.len != other.params.len) return false;
        inline for (self.params, 0..) |param, i| {
            if (!param.eql(&other.params[i])) return false;
        }
        if (!self.return_type.eql(&other.return_type)) return false;
        return true;
    }

    fn formatReflectInfo(comptime info: ReflectInfo, comptime simple: bool) []const u8 {
        switch (info) {
            .type => |ti| return if (simple) simplifyTypeName(ti.name) else ti.name,
            .func => |fi| return formatFuncSignature(fi, simple),
            .raw => |ty| return if (simple) getSimpleTypeName(ty) else @typeName(ty),
        }
    }

    fn formatFuncSignature(comptime fi: FuncInfo, comptime simple: bool) []const u8 {
        var params_str: []const u8 = "";
        var first_param = true;
        inline for (fi.params) |p| {
            const p_str = formatReflectInfo(p.info, simple);
            params_str = if (first_param) p_str else std.fmt.comptimePrint("{s}, {s}", .{ params_str, p_str });
            first_param = false;
        }
        const ret_str = if (fi.return_type) |ret| formatReflectInfo(ret, simple) else "void";
        return std.fmt.comptimePrint("fn ({s}) -> {s}", .{ params_str, ret_str });
    }

    fn getStringRepresentation(self: *const FuncInfo, omit_self: bool, simple_names: bool) []const u8 {
        var prefix_str: []const u8 = "";
        var params_str: []const u8 = "";

        if (self.container_type) |ct| {
            // Prefix self container type
            prefix_str = std.fmt.comptimePrint("{s}.", .{if (simple_names) getSimpleTypeName(ct.type) else ct.name});
        }
        //
        prefix_str = prefix_str ++ self.name;

        var first: bool = true;
        inline for (self.params, 0..) |param, i| {
            // Skip first parameter if omit_self is true
            if (omit_self and i == 0) continue;
            switch (param.info) {
                .type => |ti| {
                    if (first) {
                        params_str = if (simple_names) simplifyTypeName(ti.name) else ti.name;
                    } else {
                        params_str = std.fmt.comptimePrint("{s}, {s}", .{ params_str, if (simple_names) simplifyTypeName(ti.name) else ti.name });
                    }
                },
                .func => |fi| {
                    const fn_sig = formatFuncSignature(fi, simple_names);
                    params_str = if (first) fn_sig else std.fmt.comptimePrint("{s}, {s}", .{ params_str, fn_sig });
                },
                .raw => |ty| {
                    const ty_name = if (simple_names) getSimpleTypeName(ty) else @typeName(ty);
                    params_str = if (first) ty_name else std.fmt.comptimePrint("{s}, {s}", .{ params_str, ty_name });
                },
            }
            first = false;
        }
        const return_str = formatReflectInfo(self.return_type, true);

        return std.fmt.comptimePrint("fn {s}({s}) -> {s}", .{ prefix_str, params_str, return_str });
    }

    // Helper for FuncInfo.from with cycle detection
    fn toFuncInfo(comptime FuncType: type) FuncInfo {
        // Check for cycles using hash-based lookup - return cached FuncInfo if available
        if (isVisited(FuncType)) |builtin| {
            const ri = buildReflectInfo(FuncType, builtin);
            return switch (ri) {
                .func => |fi| fi,
                .type => |ti| FuncInfo{
                    .hash = ti.hash,
                    .name = ti.name,
                    .params = &[_]ParamInfo{},
                    .return_type = ri,
                    .type = ShallowTypeInfo.from(FuncType),
                    .category = .Func,
                },
                else => @compileError("Unexpected"),
            };
        }

        var zig_type_info = @typeInfo(FuncType);
        const type_hash = typeHash(FuncType);
        switch (zig_type_info) {
            .pointer => zig_type_info = @typeInfo(zig_type_info.pointer.child),
            .optional => zig_type_info = @typeInfo(zig_type_info.optional.child),
            .@"fn" => {},
            else => {
                @compileError(std.fmt.comptimePrint(
                    "FuncInfo can only be created from function pointer types. {s} = {s}",
                    .{ @tagName(zig_type_info), @typeName(FuncType) },
                ));
            },
        }

        var param_infos: [zig_type_info.@"fn".params.len]ParamInfo = undefined;
        var valid_params: usize = 0;
        inline for (zig_type_info.@"fn".params, 0..) |param, i| {
            _ = i;
            // Handle null param.type
            const ti = @typeInfo(@TypeOf(param.type));
            const param_type = param.type orelse if (ti == .noreturn) noreturn else void;
            const info = comptime toReflectInfo(param_type);
            param_infos[valid_params] = ParamInfo{
                .info = info,
                .is_noalias = param.is_noalias,
            };
            valid_params += 1;
        }
        const return_type_info = if (zig_type_info.@"fn".return_type) |ret_type| comptime toReflectInfo(ret_type) else toReflectInfo(void);
        const result = FuncInfo{
            .type = ShallowTypeInfo.from(FuncType),
            .hash = type_hash,
            .name = @typeName(FuncType),
            .params = param_infos[0..valid_params],
            .return_type = return_type_info,
            .category = FuncInfo.Category.from(FuncType),
        };
        markVisited(FuncType, @typeInfo(FuncType));
        return result;
    }
};

fn safeSizeOf(comptime T: type) usize {
    return switch (@typeInfo(T)) {
        .@"opaque" => {
            if (T == anyopaque) return 0;
            if (comptime lazyGetDecl(T, "Type")) |type_decl| {
                return safeSizeOf(type_decl.type);
            } else if (comptime lazyGetDecl(T, "Child")) |child_decl| {
                return safeSizeOf(child_decl.type);
            } else {
                @compileError(std.fmt.comptimePrint("couldn't find opaque's type from any declarations called Type or Child for {s}", .{@typeName(T)}));
            }
        },
        .comptime_int => 0,
        .comptime_float => 0,
        .type => 0,
        .enum_literal => 0,
        .undefined => 0,
        .null => 0,
        .noreturn => 0,
        .@"fn" => 0,
        else => @sizeOf(T),
    };
}

/// Create a leaf TypeInfo for types without fields
fn leafTypeInfo(comptime T: type) TypeInfo {
    return TypeInfo{
        .hash = typeHash(T),
        .size = safeSizeOf(T),
        .type = T,
        .name = @typeName(T),
        .fields = &[_]FieldInfo{},
        .category = TypeInfo.Category.from(T),
        .is_optional = @typeInfo(T) == .optional,
    };
}

pub const TypeInfo = struct {
    hash: u64,
    size: usize,
    type: type,
    name: []const u8,
    fields: []const FieldInfo,
    category: Category,
    is_optional: bool,

    const Category = enum {
        Struct,
        Enum,
        Union,
        Slice,
        Vector,
        Pointer,
        Opaque,
        Optional,
        Func,
        Primitive,
        Void,
        Other,

        pub fn from(comptime T: type) Category {
            const ti = @typeInfo(T);
            return switch (ti) {
                .@"struct" => .Struct,
                .@"enum" => .Enum,
                .@"union" => .Union,
                .@"opaque" => .Opaque,
                .array, .vector => .Slice,
                .pointer => .Pointer,
                .optional => .Optional,
                .@"fn" => .Func,
                .bool, .int, .float => .Primitive,
                .void => .Void,
                else => .Other,
            };
        }
    };

    /// Create a new value of this type from a tuple literal (e.g. `new(.{})` or `new(.{ .a = 32 })`).
    /// For structs, tuple fields are matched by name; omitted fields use their defaults.
    /// For non-struct value types, pass a single element tuple with the target value.
    /// Opaque/unsized, pointer, and function types are not supported.
    pub inline fn new(comptime self: *const TypeInfo, args: anytype) self.type {
        const T = self.type;

        const zig_type_info = @typeInfo(T);
        switch (zig_type_info) {
            .@"opaque", .noreturn, .type, .enum_literal, .null, .undefined, .comptime_int, .comptime_float, .@"fn" => {
                @compileError("TypeInfo.new cannot instantiate unsupported type: " ++ self.name);
            },
            .pointer => {
                @compileError("TypeInfo.new cannot allocate pointer types; construct the pointee separately");
            },
            else => {},
        }

        if (self.size == 0) {
            return std.mem.zeroes(T);
        }

        const args_info = @typeInfo(@TypeOf(args));
        const tuple_fields = switch (args_info) {
            .@"struct" => |s| blk: {
                // Accept tuple literals and named anon structs when the target is a struct.
                if (s.is_tuple) break :blk s.fields;
                if (zig_type_info == .@"struct") break :blk s.fields;
                @compileError("TypeInfo.new expects a tuple literal, e.g. .{...}");
            },
            else => @compileError("TypeInfo.new expects a tuple literal, e.g. .{...}"),
        };

        if (zig_type_info == .@"struct") {
            const target_fields = if (self.fields.len != 0)
                self.fields
            else
                comptime TypeInfo.buildFields(T);

            if (target_fields.len == 0) {
                @compileError(std.fmt.comptimePrint(
                    "TypeInfo.new: no reflected fields available for type {s}",
                    .{self.name},
                ));
            }

            // Validate provided fields are known on the target type using reflected metadata.
            inline for (tuple_fields) |tf| {
                var known = false;
                inline for (target_fields) |field_info| {
                    if (std.mem.eql(u8, field_info.name, tf.name)) {
                        known = true;
                        break;
                    }
                }

                if (!known and @hasField(T, tf.name)) {
                    known = true;
                }

                if (!known) {
                    // Allow construction to proceed; unknown fields will simply be ignored.
                    // This favors permissiveness when reflected metadata is unavailable for some nested cases.
                }
            }

            var result: T = std.mem.zeroInit(T, .{});

            // Apply only the provided tuple fields to avoid referencing absent fields on args.
            inline for (tuple_fields) |tf| {
                inline for (target_fields) |field_info| {
                    if (std.mem.eql(u8, field_info.name, tf.name)) {
                        @field(result, field_info.name) = @as(field_info.type.type, @field(args, tf.name));
                        break;
                    }
                }
            }

            return result;
        }

        if (tuple_fields.len != 1) {
            @compileError("TypeInfo.new for non-struct types expects a single argument tuple");
        }

        const single_name = tuple_fields[0].name;
        return @as(T, @field(args, single_name));
    }

    /// Create `TypeInfo` from any type. Opaque/unsized types use a size of 0.
    ///
    /// *Does not need to be called at comptime.*
    pub inline fn from(comptime T: type) TypeInfo {
        return comptime toTypeInfo(T);
    }

    /// Helper for TypeInfo.from with cycle detection
    /// Uses hash-based cycle detection to avoid branch quota issues.
    fn toTypeInfo(comptime T: type) TypeInfo {
        // Check for cycles using hash-based lookup - return cached TypeInfo if available
        if (isVisited(T)) |builtin| {
            const ri = buildReflectInfo(T, builtin);
            return switch (ri) {
                .type => |ti| ti,
                .func => leafTypeInfo(T),
                else => @compileError("Unexpected"),
            };
        }

        const type_info = @typeInfo(T);
        const leaf_type_info = leafTypeInfo(T);

        const ti = TypeInfo{
            .hash = leaf_type_info.hash,
            .size = leaf_type_info.size,
            .type = T,
            .name = leaf_type_info.name,
            .fields = comptime TypeInfo.buildFields(T),
            .category = leaf_type_info.category,
            .is_optional = type_info == .optional,
        };
        markVisited(T, @typeInfo(T));
        return ti;
    }

    /// Get the names of all fields in this type
    pub inline fn getFieldNames(self: *const TypeInfo) ?[]const []const u8 {
        if (self.fields.len == 0) return null;
        var names: [self.fields.len][]const u8 = undefined;
        var i: usize = 0;
        inline for (self.fields) |field| {
            names[i] = field.name;
            i += 1;
        }
        return names[0..i];
    }

    /// Look up a field by name.
    pub inline fn getField(self: *const TypeInfo, field_name: []const u8) ?FieldInfo {
        inline for (self.fields) |field| {
            if (std.mem.eql(u8, field.type.name, field_name)) {
                return field;
            }
        }
        return null;
    }

    /// Lazily look up a decl (type constant) by name.
    ///
    /// *Does not need to be called at comptime.*
    pub inline fn getDecl(self: *const TypeInfo, comptime decl_name: []const u8) ?TypeInfo {
        return comptime lazyGetDecl(self.type, decl_name);
    }

    /// Get a function by name.
    ///
    /// *Does not need to be called at comptime.*
    pub inline fn getFunc(self: *const TypeInfo, comptime func_name: []const u8) ?FuncInfo {
        return comptime lazyGetFunc(self, func_name);
    }

    /// Get the names of all type decls (non-function declarations).
    ///
    /// *Must be called at comptime.*
    pub inline fn getDeclNames(self: *const TypeInfo) []const []const u8 {
        return comptime lazyGetDeclNames(self.type, .types_only);
    }

    /// Get the names of all function decls.
    ///
    /// *Must be called at comptime.*
    pub inline fn getFuncNames(self: *const TypeInfo) []const []const u8 {
        return comptime lazyGetDeclNames(self.type, .funcs_only);
    }

    /// Check if this type has a declaration with the given name.
    ///
    /// This works differently than `@hasDecl`, it does not look for funcs.
    /// Use `hasFunc` for that.
    ///
    /// *Must be called at comptime.*
    pub inline fn hasDecl(self: *const TypeInfo, comptime decl_name: []const u8) bool {
        return comptime lazyGetDecl(self.type, decl_name) != null;
    }

    /// Check if this type has a function with the given name.
    ///
    /// *Must be called at comptime.*
    pub inline fn hasFunc(self: *const TypeInfo, comptime func_name: []const u8) bool {
        return comptime lazyGetFunc(self, func_name) != null;
    }

    /// Check if this TypeInfo represents a composite type (struct, enum, or union)
    pub inline fn isComposite(self: *const TypeInfo) bool {
        return self.fields.len > 0;
    }

    /// Get a shallow version of this TypeInfo (no field details)
    pub inline fn toShallow(self: *const TypeInfo) ShallowTypeInfo {
        return ShallowTypeInfo{
            .type = self.type,
            .name = self.name,
            .size = self.size,
            .category = self.category,
        };
    }

    /// Get a string representation of the type info
    ///
    /// *Does not need to be called at comptime.*
    pub inline fn toString(self: *const TypeInfo) []const u8 {
        return comptime self.getStringRepresentation(false);
    }

    /// Get a string representation of the type info
    ///
    /// `simple_name`: If true, uses simple type names without module paths.
    ///
    /// *Does not need to be called at comptime.*
    pub inline fn toStringEx(self: *const TypeInfo, simple_name: bool) []const u8 {
        return comptime self.getStringRepresentation(simple_name);
    }

    fn getStringRepresentation(self: *const TypeInfo, simple_name: bool) []const u8 {
        switch (self.category) {
            .Func => {
                const fi = comptime FuncInfo.from(self.type);
                return fi.?.getStringRepresentation(false, simple_name);
            },
            else => {},
        }
        return std.fmt.comptimePrint("{s}", .{
            if (simple_name) simplifyTypeName(self.name) else self.name,
        });
    }

    /// Check if this TypeInfo is equal to another (by hash and size)
    ///
    /// *Must be called at comptime.*
    pub inline fn eql(self: *const TypeInfo, other: *const TypeInfo) bool {
        return self.hash == other.hash and self.size == other.size;
    }

    fn buildFields(comptime T: type) []const FieldInfo {
        // buildFields is only called from toTypeInfo which already does cycle detection
        // No need for additional cycle checking here

        const type_info = @typeInfo(T);
        if (type_info != .@"struct" and type_info != .@"enum" and type_info != .@"union") return &[_]FieldInfo{};

        const fields = switch (type_info) {
            .@"struct" => type_info.@"struct".fields,
            .@"enum" => type_info.@"enum".fields,
            .@"union" => type_info.@"union".fields,
            else => return &[_]FieldInfo{},
        };
        var field_infos: [fields.len]FieldInfo = undefined;
        var field_count: usize = 0;

        for (fields) |field| {
            const field_type = switch (type_info) {
                .@"struct", .@"union" => field.type,
                .@"enum" => T, // For enum fields, use the enum type itself
                else => unreachable,
            };
            const field_type_info = @typeInfo(field_type);
            const is_opaque = field_type_info == .@"opaque";
            const is_ptr_to_opaque = field_type_info == .pointer and @typeInfo(field_type_info.pointer.child) == .@"opaque";

            const field_offset = if (type_info == .@"enum" or type_info == .@"union") 0 else if (is_opaque or is_ptr_to_opaque) 0 else @offsetOf(T, field.name);

            field_infos[field_count] = FieldInfo{
                .name = field.name,
                .offset = field_offset,
                .type = ShallowTypeInfo.from(field_type),
                .container_type = ShallowTypeInfo.from(T),
            };
            field_count += 1;
        }

        return @constCast(field_infos[0..field_count]);
    }
};

pub const ReflectInfo = union(enum) {
    type: TypeInfo,
    func: FuncInfo,
    raw: type,

    pub const unknown = ReflectInfo{ .raw = void };

    /// Create ReflectInfo from any type with cycle detection
    ///
    /// *Must be called at comptime.*
    pub fn from(comptime T: type) ReflectInfo {
        return toReflectInfo(T);
    }

    pub fn getTypeInfo(self: *const ReflectInfo) ?TypeInfo {
        switch (self.*) {
            .type => |ti| return ti,
            .raw => return null,
            .func => return null,
        }
    }

    pub fn getFuncInfo(self: *const ReflectInfo) ?FuncInfo {
        switch (self.*) {
            .func => |fi| return fi,
            else => return null,
        }
    }

    pub fn hash(self: *const ReflectInfo) u64 {
        switch (self.*) {
            .type => |ti| return ti.hash,
            .raw => return typeHash(self.raw),
            .func => |fi| return fi.hash,
        }
    }

    pub fn name(self: *const ReflectInfo) []const u8 {
        switch (self.*) {
            .type => |ti| return ti.name,
            .raw => return @typeName(self.raw),
            .func => |fi| return fi.name,
        }
    }

    pub fn size(self: *const ReflectInfo) usize {
        switch (self.*) {
            .type => |ti| return ti.size,
            .raw => return @sizeOf(self.raw),
            .func => |fi| return fi.type.size,
        }
    }

    /// Check if this ReflectInfo is equal to another
    pub inline fn eql(self: *const ReflectInfo, other: *const ReflectInfo) bool {
        switch (self.*) {
            .type => |ti| {
                switch (other.*) {
                    .type => |ti2| return ti.eql(&ti2),
                    else => return false,
                }
            },
            .raw => |t| {
                switch (other.*) {
                    .raw => |t2| return t == t2,
                    else => return false,
                }
            },
            .func => |fi| {
                switch (other.*) {
                    .func => |fi2| return fi.eql(&fi2),
                    else => return false,
                }
            },
        }
    }

    /// Get a string representation of the reflected info
    pub fn toString(self: *const ReflectInfo) []const u8 {
        switch (self.*) {
            .type => |til| return til.toString(),
            .raw => return @typeName(self.raw),
            .func => |fil| return fil.toString(),
        }
    }

    pub fn toStringEx(self: *const ReflectInfo, simple_names: bool) []const u8 {
        switch (self.*) {
            .type => |til| return til.toStringEx(simple_names),
            .raw => return if (simple_names) getSimpleTypeName(self.raw) else @typeName(self.raw),
            .func => |fil| return fil.toStringEx(false, simple_names),
        }
    }
};

fn toReflectInfo(comptime T: type) ReflectInfo {
    // Check for cycles first - return cached info if available
    if (isVisited(T)) |builtin| {
        return buildReflectInfo(T, builtin);
    }

    const builtin = @typeInfo(T);
    markVisited(T, builtin);
    return buildReflectInfo(T, builtin);
}

fn buildReflectInfo(comptime T: type, comptime builtin: std.builtin.Type) ReflectInfo {
    switch (builtin) {
        .pointer,
        .optional,
        .@"opaque",
        .array,
        .vector,
        .error_union,
        => {
            return ReflectInfo{ .type = leafTypeInfo(T) };
        },
        .error_set => {
            var ri = ReflectInfo{ .type = TypeInfo{
                .hash = typeHash(T),
                .size = safeSizeOf(T),
                .type = T,
                .name = @typeName(T),
                .fields = undefined,
            } };
            if (builtin.error_set) |error_set| {
                const len = error_set.len;
                var field_infos: [len]FieldInfo = undefined;
                for (error_set, 0..) |err, i| {
                    const ErrType = @TypeOf(err);
                    field_infos[i] = FieldInfo{
                        .name = err.name,
                        .offset = 0,
                        .type = ShallowTypeInfo.from(ErrType),
                        .container_type = ShallowTypeInfo.from(T),
                    };
                }
                ri.type.fields = field_infos[0..len];
            } else {
                ri.type.fields = &[_]FieldInfo{};
            }
            return ri;
        },
        .@"fn" => |_| {
            return ReflectInfo{ .func = FuncInfo.toFuncInfo(T) };
        },
        .@"struct", .@"enum", .@"union" => {
            const ti = TypeInfo.toTypeInfo(T);
            return ReflectInfo{ .type = ti };
        },
        .type => {
            return ReflectInfo{ .type = TypeInfo.toTypeInfo(T) };
        },
        else => {
            return ReflectInfo{ .type = leafTypeInfo(T) };
        },
    }
}

/// Mode for filtering decl names
const DeclNameMode = enum {
    types_only,
    funcs_only,
    all,
};

/// Lazily get names of declarations without processing them.
/// This avoids the comptime explosion by just collecting names.
fn lazyGetDeclNames(comptime T: type, comptime mode: DeclNameMode) []const []const u8 {
    const type_info = @typeInfo(T);
    if (type_info == .pointer) {
        return lazyGetDeclNames(type_info.pointer.child, mode);
    }

    const decls = _getDecls(type_info);
    if (decls.len == 0) {
        return &[_][]const u8{};
    }

    var names: [decls.len][]const u8 = undefined;
    var count: usize = 0;

    inline for (decls) |decl| {
        const DeclType = @TypeOf(@field(T, decl.name));
        const decl_type_info = @typeInfo(DeclType);
        const is_func = decl_type_info == .@"fn";

        const include = switch (mode) {
            .types_only => !is_func,
            .funcs_only => is_func,
            .all => true,
        };

        if (include) {
            names[count] = decl.name;
            count += 1;
        }
    }

    return names[0..count];
}

/// Lazily look up a single decl (type constant) by name.
/// Only processes the requested decl, avoiding comptime explosion.
fn lazyGetDecl(comptime T: type, comptime decl_name: []const u8) ?TypeInfo {
    const zig_type_info = @typeInfo(T);
    switch (zig_type_info) {
        .pointer => return lazyGetDecl(zig_type_info.pointer.child, decl_name),
        .optional => return lazyGetDecl(zig_type_info.optional.child, decl_name),

        .bool,
        .int,
        .float,
        .void,
        .comptime_int,
        .comptime_float,
        .noreturn,
        .enum_literal,
        .undefined,
        .null,
        .error_set,
        .error_union,
        .array,
        .vector,
        .type,
        => {
            return null;
        },
        else => {},
    }
    if (zig_type_info == .pointer) {
        return lazyGetDecl(zig_type_info.pointer.child, decl_name);
    }
    if (!@hasDecl(T, decl_name)) {
        return null;
    }

    const DeclType = @TypeOf(@field(T, decl_name));
    const decl_type_info = @typeInfo(DeclType);

    // Only return TypeInfo for non-functions (type constants)
    if (decl_type_info == .@"fn") {
        return null;
    }

    // For type constants, we need to get the actual type value
    if (DeclType == type) {
        const actual_type = @field(T, decl_name);
        return TypeInfo.from(actual_type);
    }

    // For struct/enum/union instances, return their type info
    if (decl_type_info == .@"struct" or decl_type_info == .@"enum" or decl_type_info == .@"union") {
        return TypeInfo.from(DeclType);
    }

    return null;
}

/// Lazily look up a single function by name.
/// Only processes the requested function, avoiding comptime explosion.
fn lazyGetFunc(type_info: *const TypeInfo, comptime func_name: []const u8) ?FuncInfo {
    const zig_type_info = @typeInfo(type_info.type);
    if (zig_type_info == .pointer) {
        const pointee_info = comptime TypeInfo.from(zig_type_info.pointer.child);
        return lazyGetFunc(&pointee_info, func_name);
    }

    // Check if this type can have declarations before calling @hasDecl
    switch (zig_type_info) {
        .@"struct", .@"union", .@"enum", .@"opaque" => {},
        else => return null,
    }

    // Look up the declaration by name manually to avoid visibility issues with @hasDecl
    const decls = _getDecls(@typeInfo(type_info.type));
    var found: ?std.builtin.Type.Declaration = null;
    inline for (decls) |decl| {
        if (std.mem.eql(u8, decl.name, func_name)) {
            found = decl;
            break;
        }
    }
    if (found == null) return null;

    const FuncType = @TypeOf(@field(type_info.type, found.?.name));
    const func_type_info = @typeInfo(FuncType);

    if (func_type_info != .@"fn") {
        return null;
    }

    // Build FuncInfo for this specific function
    var param_infos: [func_type_info.@"fn".params.len]ParamInfo = undefined;
    var valid_params: usize = 0;

    inline for (func_type_info.@"fn".params) |param| {
        const param_type = param.type.?;
        const info = comptime toReflectInfo(param_type);
        param_infos[valid_params] = ParamInfo{
            .info = info,
            .is_noalias = param.is_noalias,
        };
        valid_params += 1;
    }

    const return_type_info = if (func_type_info.@"fn".return_type) |ret_type|
        comptime toReflectInfo(ret_type)
    else
        toReflectInfo(void);

    const func_info = FuncInfo{
        .hash = typeHash(FuncType),
        .name = func_name,
        .params = param_infos[0..valid_params],
        .return_type = return_type_info,
        .container_type = ShallowTypeInfo.from(type_info.type),
        .type = ShallowTypeInfo.from(FuncType),
        .category = FuncInfo.Category.from(FuncType),
    };

    return func_info;
}

/// Get ReflectInfo for a type
///
/// *Must be called at comptime*
pub fn getInfo(comptime T: type) ReflectInfo {
    @setEvalBranchQuota(100_000);
    return comptime ReflectInfo.from(T);
}

/// Check if a struct has a nested struct, enum, or union with the given name
///
/// Supports dot notation for nested structs (e.g., "Outer.Inner")
pub fn hasStruct(comptime T: type, struct_name: []const u8) bool {
    const type_info = @typeInfo(T);
    if (type_info == .pointer) {
        const Child = type_info.pointer.child;
        return hasStruct(Child, struct_name);
    } else if (type_info == .@"struct" or type_info == .@"enum" or type_info == .@"union") {
        var search_name = struct_name;
        // Check if struct_name contains "."
        if (std.mem.indexOfScalar(u8, struct_name, '.')) |dot_index| {
            const first_part = struct_name[0..dot_index];
            search_name = struct_name[dot_index + 1 ..];
            // Find the decl with name first_part
            inline for (comptime _getDecls(type_info)) |decl| {
                if (std.mem.eql(u8, decl.name, first_part)) {
                    const DeclType = @field(T, decl.name);
                    const decl_type_info = @typeInfo(DeclType);
                    if (decl_type_info == .@"struct" or decl_type_info == .@"enum" or decl_type_info == .@"union") {
                        return hasStruct(DeclType, search_name);
                    }
                }
            }
            return false;
        } else {
            // No dot, check direct
            inline for (comptime _getDecls(type_info)) |decl| {
                if (std.mem.eql(u8, decl.name, struct_name)) {
                    const DeclType = @field(T, decl.name);
                    const decl_type_info = @typeInfo(DeclType);
                    if (decl_type_info == .@"struct" or decl_type_info == .@"enum" or decl_type_info == .@"union") {
                        return true;
                    }
                }
            }
            return false;
        }
    }
    return false;
}

fn _getDecls(comptime type_info: std.builtin.Type) []const std.builtin.Type.Declaration {
    if (type_info == .pointer) return _getDecls(@typeInfo(type_info.pointer.child));
    if (type_info == .@"struct") return type_info.@"struct".decls;
    if (type_info == .@"enum") return type_info.@"enum".decls;
    if (type_info == .@"union") return type_info.@"union".decls;
    if (type_info == .@"opaque") return type_info.@"opaque".decls;
    return &[_]std.builtin.Type.Declaration{};
}

/// Get all decls (type constants) of a type
///
/// *Must be called at comptime.*
pub fn getDecls(type_info: *TypeInfo) []TypeInfo {
    const names = comptime type_info.getDeclNames();
    var count: usize = 0;
    inline for (names) |n| {
        if (type_info.getDecl(n)) |_| {
            count += 1;
        }
    }

    var decls: [count]TypeInfo = undefined;
    var idx: usize = 0;
    inline for (names) |n| {
        if (type_info.getDecl(n)) |dt| {
            decls[idx] = dt;
            idx += 1;
        }
    }

    return decls;
}

/// Check if a struct has a function with the given name
pub inline fn hasFunc(comptime T: type, comptime func_name: []const u8) bool {
    return hasFuncWithArgs(T, func_name, null);
}

/// Check if a struct has a function with the given name and argument types.
///
/// If arg_types is null, only the function name is checked.
/// If `func_name` is a method of `T` you do not need to include the self reference.
pub inline fn hasFuncWithArgs(comptime T: type, comptime func_name: []const u8, comptime arg_types: ?[]const type) bool {
    return comptime verifyFuncWithArgs(T, func_name, arg_types, null) catch false;
}

/// Check if a struct has a function with the given name, argument types, and return type.
///
/// If arg_types is null, only the function name and return type are checked.
/// If `func_name` is a method of `T` you do not need to include the self reference.
pub inline fn hasFuncWithArgsAndReturn(comptime T: type, comptime func_name: []const u8, comptime arg_types: ?[]const type, return_type: type) bool {
    return comptime verifyFuncWithArgs(T, func_name, arg_types, return_type) catch false;
}

/// Verify that a struct has a function with the given name and argument types.
///
/// If the function exists and matches the argument types, returns true.
///
/// If the function does not exist, returns `error.FuncDoesNotExist`.
///
/// If the member with the given name is not a function, returns `error.NotAFunction`.
///
/// If the function exists but the argument types do not match, returns `error.IncorrectArgs`.
///
/// If `arg_types` is null, only the function name is checked.
///
/// If `func_name` is a method of `T` you do not need to include the self reference.
///
/// If `return_type` is provided, it is also checked for a match.
///
/// Error variants for incorrect argument types include the expected and actual types in the error name, e.g., `IncorrectType_Expected_i32_Got_f32`.
///
/// *Must be called at comptime.*
pub fn verifyFuncWithArgs(comptime T: type, comptime func_name: []const u8, comptime arg_types: ?[]const type, comptime return_type: ?type) anyerror!bool {
    const type_info = @typeInfo(T);
    if (type_info == .pointer) {
        const Child = type_info.pointer.child;
        return verifyFuncWithArgs(Child, func_name, arg_types, return_type);
    } else if (type_info == .@"struct") {
        if (!@hasDecl(T, func_name)) return error.FuncDoesNotExist;

        const fn_type = @typeInfo(@TypeOf(@field(T, func_name)));

        if (fn_type != .@"fn") return error.NotAFunction;

        if (arg_types) |at| {
            // Check if first parameter is self (has type T, *T, or *const T)
            const has_self_param = fn_type.@"fn".params.len > 0 and
                (fn_type.@"fn".params[0].type == T or
                    fn_type.@"fn".params[0].type == *T or
                    fn_type.@"fn".params[0].type == *const T);

            // If it has self, skip it when checking arg_types; otherwise check all params
            const start_idx = if (has_self_param) 1 else 0;
            const expected_len = at.len + start_idx;

            if (fn_type.@"fn".params.len != expected_len) return error.IncorrectArgs;

            inline for (0..at.len) |i| {
                if (fn_type.@"fn".params[start_idx + i].type != at[i]) {
                    const expected = fn_type.@"fn".params[start_idx + i].type;
                    const actual = at[i];
                    const error_name = std.fmt.comptimePrint("IncorrectArgAt_{d}_Expected_{s}_Got_{s}", .{ i, getSimpleTypeName(expected.?), getSimpleTypeName(actual) });
                    const DynamicError = util.DynamicError(error_name);
                    return @field(DynamicError, error_name);
                }
            }
        }

        if (return_type) |rt| {
            if (fn_type.@"fn".return_type != rt) return error.IncorrectArgs;
        }

        return true;
    }
    return false;
}

pub fn isField(comptime T: type, comptime field_name: []const u8) bool {
    return hasField(T, field_name);
}

/// Check if a struct has a field with the given name
pub fn hasField(comptime T: type, comptime field_name: []const u8) bool {
    const info = @typeInfo(T);
    return switch (info) {
        .pointer => hasField(info.pointer.child, field_name),
        .optional => hasField(info.optional.child, field_name),
        .@"struct" => blk: {
            const fields = comptime TypeInfo.buildFields(T);
            if (fields.len == 0) break :blk @hasField(T, field_name);
            inline for (fields) |fi| {
                if (std.mem.eql(u8, fi.name, field_name)) break :blk true;
            }
            break :blk false;
        },
        .@"enum" => blk: {
            inline for (info.@"enum".fields) |field| {
                if (std.mem.eql(u8, field.name, field_name)) break :blk true;
            }
            break :blk false;
        },
        .@"union" => blk: {
            inline for (info.@"union".fields) |field| {
                if (std.mem.eql(u8, field.name, field_name)) break :blk true;
            }
            break :blk false;
        },
        else => false,
    };
}

/// Get the type of a field by name if that field exists, otherwise `null`.
pub fn getField(comptime T: type, field_name: []const u8) ?type {
    const type_info = @typeInfo(T);
    if (type_info == .pointer) {
        const Child = type_info.pointer.child;
        return getField(Child, field_name);
    }
    const fields = blk: switch (type_info) {
        .@"struct" => |info| break :blk info.fields,
        .@"enum" => |info| break :blk info.fields,
        .@"union" => |info| break :blk info.fields,
        .pointer => |info| return getField(info.pointer.child, field_name),
        .optional => |info| return getField(info.optional.child, field_name),
        else => break :blk &[_]std.builtin.Type.StructField{},
    };
    inline for (fields) |field| {
        if (std.mem.eql(u8, field.name, field_name)) {
            return field.type;
        }
    }
    return null;
}

/// Get the names of all fields in a struct
///
/// *Must be called at comptime.*
pub fn getFields(comptime T: type) []const []const u8 {
    switch (comptime getInfo(T)) {
        .type => |type_info| {
            var names: [type_info.fields.len][]const u8 = undefined;
            var count: usize = 0;
            inline for (type_info.fields) |field| {
                names[count] = field.name;
                count += 1;
            }
            return names[0..count];
        },
        else => @compileError(std.fmt.comptimePrint("TypeInfo.getFields: type '{s}' has no fields", .{@typeName(T)})),
    }
}

/// Get the simple type name (without namespace/module prefixes)
pub inline fn getSimpleTypeName(comptime T: type) []const u8 {
    switch (comptime getInfo(T)) {
        .type => |ti| return simplifyTypeName(ti.name),
        .func => |fi| return fi.name,
        .raw => |ty| return simplifyTypeName(@typeName(ty)),
    }
}

fn extractPointerPrefix(comptime type_name: []const u8) []const u8 {
    if (type_name.len == 0 or type_name[0] != '*') return type_name[0..0];
    var i: usize = 1;
    while (i < type_name.len and type_name[i] == ' ') : (i += 1) {}
    if (i + 5 <= type_name.len and std.mem.eql(u8, type_name[i .. i + 5], "const")) {
        i += 5;
        if (i < type_name.len and type_name[i] == ' ') i += 1;
    }
    return type_name[0..i];
}

fn simplifySimpleTypeName(comptime type_name: []const u8) []const u8 {
    var last_dot: ?usize = null;
    inline for (type_name, 0..) |c, i| {
        if (c == '.') last_dot = i;
    }
    if (last_dot == null) return type_name;
    return type_name[last_dot.? + 1 ..];
}

fn simplifyFunctionTypeName(comptime type_name: []const u8) []const u8 {
    // Assume starts with "fn "
    var i: usize = 3;
    while (i < type_name.len and type_name[i] != '(') : (i += 1) {}
    if (i >= type_name.len) return type_name;
    const params_start = i + 1;
    i += 1;
    var paren_count: i32 = 1;
    var params_end = i;
    while (i < type_name.len and paren_count > 0) {
        if (type_name[i] == '(') paren_count += 1 else if (type_name[i] == ')') paren_count -= 1;
        if (paren_count > 0) params_end = i + 1;
        i += 1;
    }
    if (paren_count != 0) return type_name;
    const return_type_str = type_name[i..];
    // Parse params
    var param_buf: [16][]const u8 = undefined;
    var param_count: usize = 0;
    var start = params_start;
    var j = start;
    while (j < params_end and param_count < 16) {
        if (type_name[j] == ',') {
            const param = std.mem.trim(u8, type_name[start..j], &std.ascii.whitespace);
            if (param.len > 0) {
                param_buf[param_count] = param;
                param_count += 1;
            }
            start = j + 1;
        }
        j += 1;
    }
    if (start < params_end and param_count < 16) {
        const param = std.mem.trim(u8, type_name[start..params_end], &std.ascii.whitespace);
        if (param.len > 0) {
            param_buf[param_count] = param;
            param_count += 1;
        }
    }
    // Simplify params
    var simplified_buf: [16][]const u8 = undefined;
    inline for (0..16) |idx| {
        if (idx < param_count) {
            const p = param_buf[idx];
            const prefix = extractPointerPrefix(p);
            const base = p[prefix.len..];
            const simplified = simplifySimpleTypeName(base);
            if (prefix.len == 0) {
                simplified_buf[idx] = simplified;
            } else {
                const len = prefix.len + simplified.len;
                var buf: [len]u8 = undefined;
                @memcpy(buf[0..prefix.len], prefix);
                @memcpy(buf[prefix.len..len], simplified);
                simplified_buf[idx] = buf[0..len];
            }
        }
    }
    const simplified_return = blk: {
        const prefix = extractPointerPrefix(return_type_str);
        const base = return_type_str[prefix.len..];
        const simplified = simplifySimpleTypeName(base);
        if (prefix.len == 0) break :blk simplified;
        const len = prefix.len + simplified.len;
        var buf: [len]u8 = undefined;
        @memcpy(buf[0..prefix.len], prefix);
        @memcpy(buf[prefix.len..len], simplified);
        break :blk buf[0..len];
    };
    // Calculate total length
    var total_len: usize = 4; // "fn ("
    inline for (0..16) |idx| {
        if (idx < param_count) {
            if (idx > 0) total_len += 2; // ", "
            total_len += simplified_buf[idx].len;
        }
    }
    total_len += 2; // ") "
    total_len += simplified_return.len;
    // Build output
    var out: [total_len]u8 = undefined;
    var pos: usize = 0;
    @memcpy(out[pos .. pos + 4], "fn (");
    pos += 4;
    inline for (0..16) |idx| {
        if (idx < param_count) {
            if (idx > 0) {
                @memcpy(out[pos .. pos + 2], ", ");
                pos += 2;
            }
            @memcpy(out[pos .. pos + simplified_buf[idx].len], simplified_buf[idx]);
            pos += simplified_buf[idx].len;
        }
    }
    @memcpy(out[pos .. pos + 2], ") ");
    pos += 2;
    @memcpy(out[pos .. pos + simplified_return.len], simplified_return);
    pos += simplified_return.len;
    return out[0..pos];
}

pub fn simplifyTypeName(comptime type_name: []const u8) []const u8 {
    const prefix = extractPointerPrefix(type_name);
    const base = type_name[prefix.len..];
    const simplified_base = if (std.mem.startsWith(u8, base, "fn ")) simplifyFunctionTypeName(base) else simplifySimpleTypeName(base);
    if (prefix.len == 0) return simplified_base;
    const out_len = prefix.len + simplified_base.len;
    var out: [out_len]u8 = undefined;
    @memcpy(out[0..prefix.len], prefix);
    @memcpy(out[prefix.len..out_len], simplified_base);
    return out[0..out_len];
}

// ===== TESTS =====

test "hasFuncWithArgs - funcs with self only (no additional args)" {
    const TestStruct = struct {
        value: i32,

        pub fn getValue(self: @This()) i32 {
            return self.value;
        }

        pub fn add(self: @This(), other: i32) i32 {
            return self.value + other;
        }

        pub fn combine(self: @This(), a: i32, b: f32) i32 {
            return self.value + a + @as(i32, @intFromFloat(b));
        }
    };

    // arg_types does NOT include self, so empty array means only self param
    try std.testing.expect(comptime hasFuncWithArgs(TestStruct, "getValue", &[_]type{}));
    try std.testing.expect(comptime !hasFuncWithArgs(TestStruct, "getValue", &[_]type{i32}));

    try std.testing.expect(comptime hasFuncWithArgs(TestStruct, "add", &[_]type{i32}));
    try std.testing.expect(comptime !hasFuncWithArgs(TestStruct, "add", &[_]type{}));
    try std.testing.expect(comptime !hasFuncWithArgs(TestStruct, "add", &[_]type{ i32, i32 }));

    try std.testing.expect(comptime hasFuncWithArgs(TestStruct, "combine", &[_]type{ i32, f32 }));
    try std.testing.expect(comptime !hasFuncWithArgs(TestStruct, "combine", &[_]type{i32}));
    try std.testing.expect(comptime !hasFuncWithArgs(TestStruct, "combine", &[_]type{ i32, f32, i32 }));

    try std.testing.expect(comptime !hasFuncWithArgs(TestStruct, "nonExistent", &[_]type{})); // Function doesn't exist
}

test "verifyFuncWithArgs" {
    const TestStruct = struct {
        value: i32,

        pub fn getValue(self: @This()) i32 {
            return self.value;
        }

        pub fn add(self: @This(), other: i32) i32 {
            return self.value + other;
        }
    };

    try std.testing.expect(comptime verifyFuncWithArgs(TestStruct, "getValue", &[_]type{}, null) catch false);
    try std.testing.expect(!(comptime verifyFuncWithArgs(TestStruct, "getValue", &[_]type{i32}, null) catch false));

    try std.testing.expect(comptime verifyFuncWithArgs(TestStruct, "add", &[_]type{i32}, null) catch false);
    try std.testing.expect(!(comptime verifyFuncWithArgs(TestStruct, "add", &[_]type{}, null) catch false));
    try std.testing.expect(!(comptime verifyFuncWithArgs(TestStruct, "add", &[_]type{ i32, i32 }, null) catch false));

    try std.testing.expectError(error.FuncDoesNotExist, comptime verifyFuncWithArgs(TestStruct, "nonExistent", &[_]type{}, null));

    // Test dynamic error for type mismatch
    const mismatch_result = comptime verifyFuncWithArgs(TestStruct, "add", &[_]type{f32}, null);
    if (mismatch_result) |_| {
        try std.testing.expect(false); // should fail
    } else |err| {
        const name = @errorName(err);
        try std.testing.expectEqualStrings("IncorrectArgAt_0_Expected_i32_Got_f32", name);
    }
}

test "hasField" {
    const TestStruct = struct {
        id: u32,
        name: []const u8,
    };

    const TestStructWithInner = struct {
        id: u32,
        pub const Inner = struct {
            value: i32,
        };
    };

    const TestStructNoFields = struct {};

    try std.testing.expect(hasField(TestStruct, "id"));
    try std.testing.expect(hasField(*TestStruct, "name"));
    try std.testing.expect(!hasField(TestStruct, "nonExistentField"));
    try std.testing.expect(!hasStruct(TestStruct, "Inner"));

    try std.testing.expect(comptime hasField(TestStruct, "id"));
    try std.testing.expect(comptime hasField(*TestStruct, "name"));
    try std.testing.expect(comptime !hasField(TestStruct, "nonExistentField"));
    try std.testing.expect(comptime !hasStruct(TestStruct, "Inner"));

    try std.testing.expect(hasStruct(TestStructWithInner, "Inner"));
    try std.testing.expect(hasStruct(*TestStructWithInner, "Inner"));
    try std.testing.expect(!hasField(TestStructNoFields, "any"));
    try std.testing.expect(!hasStruct(TestStructNoFields, "Inner"));
}

test "hasStruct" {
    const TestStruct = struct {
        id: u32,
        pub const Inner = struct {
            value: i32,
        };
    };

    const TestStructWithNested = struct {
        id: u32,
        pub const Nested = struct {
            pub const InnerNested = struct {
                data: f32,
            };
        };
    };

    const TestStructNoStructs = struct {
        id: u32,
        name: []const u8,
    };

    const TestEnum = enum {
        A,
        B,
        pub const InnerEnum = enum {
            X,
            Y,
        };
    };

    try std.testing.expect(hasStruct(TestStruct, "Inner"));
    try std.testing.expect(hasStruct(*TestStruct, "Inner"));
    try std.testing.expect(!hasStruct(TestStruct, "NonExistent"));

    try std.testing.expect(hasStruct(TestStructWithNested, "Nested"));
    try std.testing.expect(hasStruct(*TestStructWithNested, "Nested"));
    try std.testing.expect(hasStruct(TestStructWithNested, "Nested.InnerNested"));
    try std.testing.expect(!hasStruct(TestStructWithNested, "NonExistent"));

    try std.testing.expect(!hasStruct(TestStructNoStructs, "Inner"));
    try std.testing.expect(!hasStruct(*TestStructNoStructs, "Inner"));

    try std.testing.expect(hasStruct(TestEnum, "InnerEnum"));
}

test "getFields - returns all field names" {
    const TestStruct = struct {
        id: u32,
        name: []const u8,
        active: bool,
    };

    const fields = comptime getFields(TestStruct);
    try std.testing.expectEqual(@as(usize, 3), fields.len);

    // Check that all expected fields are present (order may vary)
    var found_id = false;
    var found_name = false;
    var found_active = false;

    inline for (fields) |field_name| {
        std.debug.print("Found field: {s}\n", .{field_name});
        if (std.mem.eql(u8, field_name, "id")) found_id = true;
        if (std.mem.eql(u8, field_name, "name")) found_name = true;
        if (std.mem.eql(u8, field_name, "active")) found_active = true;
    }

    try std.testing.expect(found_id);
    try std.testing.expect(found_name);
    try std.testing.expect(found_active);
}

test "getFieldType" {
    const TestStruct = struct {
        id: u32,
        name: []const u8,
        active: bool,
    };

    const id_type = getField(TestStruct, "id") orelse unreachable;
    const name_type = getField(TestStruct, "name") orelse unreachable;
    const active_type = getField(TestStruct, "active") orelse unreachable;
    const non_existent_type = getField(TestStruct, "nonExistent");

    try std.testing.expectEqualStrings(@typeName(u32), @typeName(id_type));
    try std.testing.expectEqualStrings(@typeName([]const u8), @typeName(name_type));
    try std.testing.expectEqualStrings(@typeName(bool), @typeName(active_type));
    try std.testing.expect(non_existent_type == null);
}

test "reflect - primitive type" {
    const info = getInfo(u32);
    switch (info) {
        .type => |ti| {
            try std.testing.expectEqualStrings(@typeName(u32), ti.name);
        },
        else => try std.testing.expect(false),
    }
}

test "reflect - struct fields" {
    const S = struct { a: u32, b: i32 };
    const info = getInfo(S);
    switch (info) {
        .type => |ti| {
            try std.testing.expectEqual(@as(usize, 2), ti.fields.len);
            try std.testing.expectEqualStrings(@typeName(u32), ti.fields[0].type.name);
            try std.testing.expectEqualStrings(@typeName(i32), ti.fields[1].type.name);
        },
        else => try std.testing.expect(false),
    }
}

// Recursive type reflection is covered indirectly by other tests; skip explicit recursive forward-decl here.

test "reflect - function type" {
    const FT = fn (i32) i32;
    const info = getInfo(FT);
    switch (info) {
        .func => |fi| {
            try std.testing.expectEqual(@as(usize, 1), fi.params.len);
            // param is a ReflectInfo; expect its type to be i32
            var saw = false;
            inline for (fi.params) |p| {
                switch (p.info) {
                    .type => |pti| {
                        try std.testing.expectEqualStrings(@typeName(i32), pti.name);
                        saw = true;
                    },
                    else => {},
                }
            }
            try std.testing.expect(saw);
        },
        else => try std.testing.expect(false),
    }
}

test "reflect - anyopaque support" {
    const ptr_info = getInfo(*anyopaque);
    switch (ptr_info) {
        .type => |ti| {
            try std.testing.expectEqualStrings(@typeName(*anyopaque), ti.name);
        },
        else => try std.testing.expect(false),
    }

    const opaque_info = getInfo(anyopaque);
    switch (opaque_info) {
        .type => |ti| {
            try std.testing.expectEqualStrings(@typeName(anyopaque), ti.name);
            try std.testing.expectEqual(@as(usize, 0), ti.size);
        },
        else => try std.testing.expect(false),
    }
}

test "reflect - function with anyopaque param" {
    const FnType = fn (*anyopaque) void;
    const fi = comptime FuncInfo.from(FnType) orelse unreachable;

    try std.testing.expectEqual(@as(usize, 1), fi.params.len);
    switch (fi.params[0].info) {
        .type => |ti| try std.testing.expectEqualStrings(@typeName(*anyopaque), ti.name),
        else => try std.testing.expect(false),
    }
}

test "reflect - TypeInfo with lazy decl/func access" {
    // Decls and funcs are now accessed lazily to avoid comptime branch quota
    // explosion when processing complex external types (like raylib).
    const S = struct {
        const Inner = struct { a: u32 };

        pub const I = Inner{ .a = 0 };
        pub fn add(x: i32) i32 {
            return x;
        }
        field: u8,
    };

    const ti = TypeInfo.from(S);

    std.debug.print("TypeInfo: {s}\n", .{ti.name});
    std.debug.print("\tSize: {d}\n", .{ti.size});
    std.debug.print("\tHash: {x}\n", .{ti.hash});
    std.debug.print("\tFields:\n", .{});
    inline for (ti.fields) |field| {
        std.debug.print("\t- Name: {s}\n", .{field.name});
        std.debug.print("\t- Offset: {d}\n", .{field.offset});
        std.debug.print("\t- Type: {s}\n", .{field.type.name});
    }

    // Verify basic type info
    try std.testing.expect(ti.hash != 0);
    try std.testing.expectEqual(@as(usize, 1), ti.size);
    try std.testing.expectEqual(@as(usize, 1), ti.fields.len);
    try std.testing.expectEqualStrings("field", ti.fields[0].name);

    // Test lazy function access - use comptime block for iteration
    std.debug.print("\tFunc names: ", .{});
    const func_names = comptime ti.getFuncNames();
    inline for (func_names) |name| {
        std.debug.print("{s} ", .{name});
    }
    std.debug.print("\n", .{});

    const add_func = comptime ti.getFunc("add") orelse {
        @compileError("Failed to get 'add' function");
    };
    try std.testing.expectEqualStrings("add", add_func.name);
    try std.testing.expectEqual(@as(usize, 1), add_func.params.len);
    std.debug.print("\tFunc 'add': {s}\n", .{add_func.toString()});

    // Test lazy decl access
    std.debug.print("\tDecls:\n", .{});
    const decl_names = comptime ti.getDeclNames();
    inline for (decl_names) |name| {
        const decl = comptime ti.getDecl(name) orelse unreachable;
        std.debug.print("\t- Name: {s}\n", .{name});
        std.debug.print("\t- Type: {s}\n", .{@typeName(decl.type)});
        std.debug.print("\t- Hash: {x}\n", .{decl.hash});
        std.debug.print("\t- Size: {d}\n", .{decl.size});
        std.debug.print("\t- Fields: {d}\n", .{decl.fields.len});
        inline for (decl.fields) |field| {
            std.debug.print("\t\t- Field Name: {s}\n", .{field.name});
            std.debug.print("\t\t- Field Type: {s}\n", .{field.type.name});
        }
    }
    std.debug.print("\n", .{});

    // Check hasDecl - needs comptime
    try std.testing.expect(comptime ti.hasFunc("add"));
    try std.testing.expect(comptime ti.hasDecl("I"));
    try std.testing.expect(comptime ti.hasDecl("Inner"));
    try std.testing.expect(comptime !ti.hasDecl("nonexistent"));
    try std.testing.expect(ti.getFunc("add") != null);
    try std.testing.expect(ti.getFunc("nonexistent") == null);
    try std.testing.expect(comptime ti.getDeclNames().len == 1);
    try std.testing.expect(comptime ti.getFuncNames().len == 1);
    try std.testing.expect(ti.getDecl("I") != null);
    try std.testing.expect(ti.toString().len > 0);
}

test "reflect - TypeInfo eql" {
    const S1 = struct { a: u32, b: i32 };
    const S2 = struct { a: u32, c: i32 }; // Different field name

    const ti1 = comptime TypeInfo.from(S1);
    const ti1_again = comptime TypeInfo.from(S1); // Same type
    const ti2 = comptime TypeInfo.from(S2);

    // eql compares hash and size - same type should be equal
    try std.testing.expect(comptime ti1.eql(&ti1_again));
    // Different types (even with same layout) have different hashes
    try std.testing.expect(comptime !ti1.eql(&ti2));

    // Also test with primitives
    const ti_u32 = comptime TypeInfo.from(u32);
    const ti_u32_again = comptime TypeInfo.from(u32);
    const ti_i32 = comptime TypeInfo.from(i32);

    try std.testing.expect(comptime ti_u32.eql(&ti_u32_again));
    try std.testing.expect(comptime !ti_u32.eql(&ti_i32));
}

test "reflect - FuncInfo eql" {
    const FT1 = fn (i32) i32;
    const FT2 = fn (i32, i32) i32; // Different signature

    const fi1 = comptime FuncInfo.from(FT1) orelse unreachable;
    const fi1_again = comptime FuncInfo.from(FT1) orelse unreachable; // Same function
    const fi2 = comptime FuncInfo.from(FT2) orelse unreachable;

    try std.testing.expect(comptime fi1.eql(&fi1_again));
    try std.testing.expect(comptime !fi1.eql(&fi2));
}

test "reflect - FieldInfo eql" {
    const S1 = struct { a: u32, b: i32 };
    const S2 = struct { a: u32, c: i32 }; // Different field name

    const ti1 = comptime TypeInfo.from(S1);
    const ti2 = comptime TypeInfo.from(S2);
    const field_a1 = ti1.fields[0];
    const field_a1_again = ti1.fields[0];
    const field_b1 = ti1.fields[1];
    const field_c2 = ti2.fields[1];

    try std.testing.expect(comptime field_a1.eql(&field_a1_again));
    try std.testing.expect(comptime !field_a1.eql(&field_b1));
    try std.testing.expect(comptime !field_a1.eql(&field_c2));
}

test "reflect - ReflectInfo eql" {
    const S = struct { a: u32, b: i32 };
    const T = struct { a: u32, b: i32 }; // Same layout but different type
    const FT = fn (i32) i32;

    const ri_type1 = comptime ReflectInfo.from(S);
    const ri_type1_again = comptime ReflectInfo.from(S);
    const ri_func = comptime ReflectInfo.from(FT);
    const ri_type2 = comptime ReflectInfo.from(T);

    try std.testing.expect(comptime ri_type1.eql(&ri_type1_again));
    try std.testing.expect(comptime !ri_type1.eql(&ri_func));
    try std.testing.expect(comptime !ri_type1.eql(&ri_type2));
}

test "reflect - PackedStruct vs UnpackedStruct" {
    const PackedStruct = packed struct {
        a: u8,
        b: u32,
    };

    const UnpackedStruct = struct { a: u8, b: u32 };

    const ti = comptime TypeInfo.from(PackedStruct);

    std.debug.print("PackedStruct TypeInfo: {s}\n", .{ti.name});
    std.debug.print("\tHash: {x}\n", .{ti.hash});
    std.debug.print("\tSize: {d}\n", .{ti.size});
    std.debug.print("\tFields:\n", .{});
    inline for (ti.fields) |field| {
        std.debug.print("\t- Name: {s}\n", .{field.name});
        std.debug.print("\t\t- Offset: {d}\n", .{field.offset});
        std.debug.print("\t\t- Type: {s}\n", .{field.type.name});
    }
    // Packed struct is backed by integer type, @sizeOf returns padded size (8 bytes for u40 backing)
    try std.testing.expectEqual(@as(usize, @sizeOf(PackedStruct)), ti.size);
    try std.testing.expectEqual(@as(usize, 2), ti.fields.len);
    try std.testing.expectEqualStrings("a", ti.fields[0].name);
    try std.testing.expectEqualStrings("b", ti.fields[1].name);

    const uti = comptime TypeInfo.from(UnpackedStruct);

    try std.testing.expect(ti.size == uti.size);

    std.debug.print("UnpackedStruct Fields:\n", .{});
    inline for (uti.fields) |field| {
        std.debug.print("\t- Name: {s}, Offset: {d}\n", .{ field.name, field.offset });
    }

    try std.testing.expect(ti.fields[0].offset != uti.fields[0].offset);
    try std.testing.expect(ti.fields[1].offset != uti.fields[1].offset);
}

test "reflect - fromMethod slice parameter type" {
    const TestStruct = struct {
        pub fn testMethod(self: *@This(), testConstU8: []const u8, testVoid: void, testOptional: ?void) void {
            _ = self;
            _ = testConstU8;
            _ = testVoid;
            _ = testOptional;
        }
    };

    // First check what Zig gives us directly
    const DirectFnType = @TypeOf(TestStruct.testMethod);
    const direct_fn_info = @typeInfo(DirectFnType);
    std.debug.print("\nDirect @typeInfo check:\n", .{});
    inline for (direct_fn_info.@"fn".params, 0..) |param, i| {
        if (param.type) |pt| {
            std.debug.print("  Param {d}: {s}\n", .{ i, @typeName(pt) });
        }
    }

    // Now check via fromMethod
    const type_info = comptime TypeInfo.from(TestStruct);
    const func_info = type_info.getFunc("testMethod").?;

    std.debug.print("\nfromMethod result:\n", .{});
    std.debug.print("Function: {s}\n", .{func_info.name});
    std.debug.print("Params: {d}\n", .{func_info.params.len});

    inline for (func_info.params, 0..) |param, i| {
        switch (param.info) {
            .type => |ti| {
                std.debug.print("  Param {d}: {s}\n", .{ i, @typeName(ti.type) });
            },
            else => {
                std.debug.print("  Param {d}: not a type\n", .{i});
            },
        }
    }

    std.debug.print("   Return: {s}\n", .{switch (func_info.return_type) {
        .type => |ti| ti.name,
        else => "not a type",
    }});

    // Check that param 1 is []const u8, not u8
    switch (func_info.params[1].info) {
        .type => |ti| {
            try std.testing.expectEqual([]const u8, ti.type);
        },
        else => {
            try std.testing.expect(false); // Should be a type
        },
    }

    switch (func_info.params[2].info) {
        .type => |ti| {
            try std.testing.expectEqual(void, ti.type);
        },
        else => {
            try std.testing.expect(false); // Should be a type
        },
    }

    switch (func_info.params[3].info) {
        .type => |ti| {
            try std.testing.expectEqual(ti.is_optional, true);
            try std.testing.expectEqual(?void, ti.type);
        },
        else => {
            try std.testing.expect(false); // Should be a type
        },
    }
}

test "reflect - getFunc finds method" {
    const TestStruct = struct {
        pub fn draw(self: *@This()) void {
            _ = self;
        }
    };

    const type_info = comptime TypeInfo.from(TestStruct);
    const func_info = type_info.getFunc("draw");

    std.debug.print("\ngetFunc result for 'draw': {}\n", .{func_info != null});
    if (func_info) |fi| {
        std.debug.print("  Function name: {s}\n", .{fi.name});
        std.debug.print("  Params: {d}\n", .{fi.params.len});
    }

    try std.testing.expect(func_info != null);
}

test "FuncInfo.invoke calls function" {
    const Target = struct {
        pub fn addOne(value: *i32) i32 {
            return value.* + 1;
        }

        pub fn inc(self: *@This()) void {
            _ = self;
        }
    };

    const ti = comptime TypeInfo.from(Target);
    const fi = ti.getFunc("addOne").?;

    var value: i32 = 41;
    const result = fi.invoke(.{&value});

    try std.testing.expectEqual(@as(i32, 42), result);
    std.debug.print("invoked: {s}\n", .{fi.toString()});

    // Also test method invoke using a single non-tuple arg and tuple form
    const inc_fi = ti.getFunc("inc").?;
    var t = Target{};
    // tuple form
    inc_fi.invoke(.{&t});
    // single-arg form (non-tuple)
    inc_fi.invoke(&t);
}

test "FuncInfo.toPtr" {
    const Target = struct {
        pub fn multiply(a: i32, b: i32) i32 {
            return a * b;
        }
    };

    const ti = comptime TypeInfo.from(Target);
    const fi = ti.getFunc("multiply").?;

    const fn_ptr = comptime fi.toPtr();

    const result = fn_ptr(6, 7);
    try std.testing.expectEqual(@as(i32, 42), result);
    std.debug.print("Function pointer call result: {d}\n", .{result});
}

test "TypeInfo.new constructs value" {
    const Foo = struct {
        a: i32,
        b: i32 = 2,
    };

    const ti = comptime TypeInfo.from(Foo);

    const foo_default = ti.new(.{});
    try std.testing.expectEqual(@as(i32, 0), foo_default.a);
    try std.testing.expectEqual(@as(i32, 2), foo_default.b);

    const foo_override = ti.new(.{ .a = 5 });
    try std.testing.expectEqual(@as(i32, 5), foo_override.a);
    try std.testing.expectEqual(@as(i32, 2), foo_override.b);
}

test "reflect - pointer type distinct from pointee type" {
    const MyStruct = struct {
        value: i32 = 42,
    };

    // Get reflection info for the struct and its pointer
    const struct_info = comptime getInfo(MyStruct);
    const ptr_info = comptime getInfo(*MyStruct);

    // They should be different
    try std.testing.expect(!struct_info.eql(&ptr_info));

    // The struct should be a struct category
    try std.testing.expectEqual(TypeInfo.Category.Struct, struct_info.type.category);

    // The pointer should be a pointer category
    try std.testing.expectEqual(TypeInfo.Category.Pointer, ptr_info.type.category);

    // Verify cached lookups return the correct types
    const struct_info2 = comptime getInfo(MyStruct);
    const ptr_info2 = comptime getInfo(*MyStruct);

    try std.testing.expect(struct_info.eql(&struct_info2));
    try std.testing.expect(ptr_info.eql(&ptr_info2));

    // Verify both have empty fields (pointer types don't have fields)
    try std.testing.expectEqual(@as(usize, 0), ptr_info.type.fields.len);
    // But the struct should have a field
    try std.testing.expectEqual(@as(usize, 1), struct_info.type.fields.len);
}

test "reflect - optional and array types distinct from base type" {
    const BaseType = i32;

    const base_info = comptime getInfo(BaseType);
    const optional_info = comptime getInfo(?BaseType);
    const array_info = comptime getInfo([4]BaseType);

    // All should be different
    try std.testing.expect(!base_info.eql(&optional_info));
    try std.testing.expect(!base_info.eql(&array_info));
    try std.testing.expect(!optional_info.eql(&array_info));

    // Verify categories
    try std.testing.expectEqual(TypeInfo.Category.Primitive, base_info.type.category);
    try std.testing.expectEqual(TypeInfo.Category.Optional, optional_info.type.category);
    try std.testing.expectEqual(TypeInfo.Category.Slice, array_info.type.category);

    // Verify optional flag
    try std.testing.expect(!base_info.type.is_optional);
    try std.testing.expect(optional_info.type.is_optional);

    // Verify cached lookups work correctly
    const optional_info2 = comptime getInfo(?BaseType);
    try std.testing.expect(optional_info.eql(&optional_info2));
}

test "reflect - lazyGetDecl returns null for non-struct types" {
    // Test that lazyGetDecl correctly returns null for all @typeInfo kinds
    // that don't support declarations

    // Primitive types
    try std.testing.expectEqual(@as(?TypeInfo, null), comptime lazyGetDecl(bool, "someDecl"));
    try std.testing.expectEqual(@as(?TypeInfo, null), comptime lazyGetDecl(i32, "someDecl"));
    try std.testing.expectEqual(@as(?TypeInfo, null), comptime lazyGetDecl(u64, "someDecl"));
    try std.testing.expectEqual(@as(?TypeInfo, null), comptime lazyGetDecl(f32, "someDecl"));
    try std.testing.expectEqual(@as(?TypeInfo, null), comptime lazyGetDecl(f64, "someDecl"));

    // Void and special types
    try std.testing.expectEqual(@as(?TypeInfo, null), comptime lazyGetDecl(void, "someDecl"));
    try std.testing.expectEqual(@as(?TypeInfo, null), comptime lazyGetDecl(type, "someDecl"));
    try std.testing.expectEqual(@as(?TypeInfo, null), comptime lazyGetDecl(noreturn, "someDecl"));

    // Array and vector types
    try std.testing.expectEqual(@as(?TypeInfo, null), comptime lazyGetDecl([5]u8, "someDecl"));
    try std.testing.expectEqual(@as(?TypeInfo, null), comptime lazyGetDecl(@Vector(4, f32), "someDecl"));

    // Error types
    try std.testing.expectEqual(@as(?TypeInfo, null), comptime lazyGetDecl(anyerror, "someDecl"));

    // Pointer types (should delegate to pointee, which for primitives returns null)
    try std.testing.expectEqual(@as(?TypeInfo, null), comptime lazyGetDecl(*u32, "someDecl"));
    try std.testing.expectEqual(@as(?TypeInfo, null), comptime lazyGetDecl(?*u32, "someDecl"));

    // Optional types (should delegate to child, which for primitives returns null)
    try std.testing.expectEqual(@as(?TypeInfo, null), comptime lazyGetDecl(?u32, "someDecl"));
}

test "reflect - lazyGetDecl works for struct types" {
    const TestStruct = struct {
        pub const InnerType = u32;
        pub const AnotherType = struct { value: i32 };
    };

    // Should find type declarations
    const inner_type = comptime lazyGetDecl(TestStruct, "InnerType");
    try std.testing.expect(inner_type != null);
    try std.testing.expectEqual(TypeInfo.Category.Primitive, inner_type.?.category);

    const another_type = comptime lazyGetDecl(TestStruct, "AnotherType");
    try std.testing.expect(another_type != null);
    try std.testing.expectEqual(TypeInfo.Category.Struct, another_type.?.category);

    // Should return null for non-existent declarations
    try std.testing.expectEqual(@as(?TypeInfo, null), comptime lazyGetDecl(TestStruct, "NonExistent"));

    // Should return null for functions (not declarations)
    try std.testing.expectEqual(@as(?TypeInfo, null), comptime lazyGetDecl(TestStruct, "someFunc"));
}

test "reflect - lazyGetDecl pointer delegation" {
    const TestStruct = struct {
        pub const InnerType = u32;
    };

    // Pointer to struct should delegate to the struct
    const ptr_inner = comptime lazyGetDecl(*TestStruct, "InnerType");
    try std.testing.expect(ptr_inner != null);
    try std.testing.expectEqual(TypeInfo.Category.Primitive, ptr_inner.?.category);

    // Optional pointer to struct should also delegate
    const opt_ptr_inner = comptime lazyGetDecl(?*TestStruct, "InnerType");
    try std.testing.expect(opt_ptr_inner != null);
    try std.testing.expectEqual(TypeInfo.Category.Primitive, opt_ptr_inner.?.category);
}

test "reflect - lazyGetFunc pointer delegation" {
    const TestStruct = struct {
        pub fn testMethod(self: *@This()) void {
            _ = self;
        }
    };

    // Test that TypeInfo.hasFunc works for pointer types
    const ptr_type_info = comptime TypeInfo.from(*TestStruct);
    try std.testing.expect(ptr_type_info.hasFunc("testMethod"));

    // Pointer to primitive should not have methods
    const prim_ptr_type_info = comptime TypeInfo.from(*u32);
    try std.testing.expect(!prim_ptr_type_info.hasFunc("someMethod"));
}
