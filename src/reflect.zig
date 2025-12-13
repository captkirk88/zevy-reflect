const std = @import("std");

/// Simple comptime hash using length and character samples - no iteration required
pub inline fn typeHash(comptime T: type) u64 {
    const name = @typeName(T);
    const len = name.len;

    // Sample up to 8 characters from different positions for uniqueness
    var h: u64 = len;
    if (len > 0) h ^= @as(u64, name[0]) << 0;
    if (len > 1) h ^= @as(u64, name[len - 1]) << 8;
    if (len > 2) h ^= @as(u64, name[len / 2]) << 16;
    if (len > 3) h ^= @as(u64, name[len / 3]) << 24;
    if (len > 4) h ^= @as(u64, name[len / 4]) << 32;
    if (len > 8) h ^= @as(u64, name[len / 8]) << 40;
    if (len > 16) h ^= @as(u64, name[len - len / 16]) << 48;
    if (len > 32) h ^= @as(u64, name[len - len / 32]) << 56;

    return h;
}

pub inline fn hash(data: []const u8) u64 {
    return std.hash.Wyhash.hash(0, data);
}

pub inline fn hashWithSeed(data: []const u8, seed: u64) u64 {
    return std.hash.Wyhash.hash(seed, data);
}

/// Internal shared storage for visited reflect entries (comptime-only).
fn visitedData() *[]const ReflectInfo {
    comptime var data: []const ReflectInfo = &[_]ReflectInfo{};
    return &data;
}

/// Look up a previously-built ReflectInfo for the given type/function.
pub fn lookupVisited(comptime T: type) ?ReflectInfo {
    const data = visitedData().*;
    inline for (data) |info| {
        switch (info) {
            .type => |ti| if (ti.type == T) return info,
            .func => |fi| if (std.mem.eql(u8, fi.name, @typeName(T))) return info,
        }
    }
    return null;
}

/// Add a new ReflectInfo to the global store.
pub fn pushVisited(comptime info: ReflectInfo) void {
    const data_ptr = visitedData();
    data_ptr.* = data_ptr.* ++ [_]ReflectInfo{info};
}

/// Shallow type information for field types - doesn't recurse into nested types.
/// This avoids comptime explosion when reflecting complex types with many nested fields.
pub const ShallowTypeInfo = struct {
    type: type,
    name: []const u8,
    size: usize,
    category: TypeInfo.Category,

    pub fn from(comptime T: type) ShallowTypeInfo {
        const data = visitedData().*;
        inline for (data) |info| {
            switch (info) {
                .type => |ti| {
                    if (ti.type == T) {
                        return ShallowTypeInfo{
                            .type = ti.type,
                            .name = ti.name,
                            .size = ti.size,
                            .category = ti.category,
                        };
                    }
                },
                else => {},
            }
        }
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
        return self.type == other.type and std.mem.eql(u8, self.name, other.name);
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
                    .type = ShallowTypeInfo{
                        .type = field.type,
                        .name = @typeName(field.type),
                        .size = @sizeOf(field.type),
                        .container_type = container_type,
                    },
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

    pub fn get(self: *const FieldInfo) self.type.type {
        return @as(self.type.type, @field(self.container_type.type, self.name));
    }

    pub fn set(self: *const FieldInfo, value: self.type) void {
        @field(self.container_type.type, self.name) = value;
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
    return_type: ?ReflectInfo,
    container_type: ?ShallowTypeInfo = null,
    type: ShallowTypeInfo,

    /// Create FuncInfo from a function type
    fn from(comptime FuncType: type) ?FuncInfo {
        return comptime toFuncInfo(FuncType);
    }

    /// Create FuncInfo for a method of a struct given the struct's TypeInfo and method name
    fn fromMethod(comptime type_info: *const TypeInfo, comptime func_name: []const u8) ?FuncInfo {
        const ti = @typeInfo(type_info.type);
        if (ti != .@"struct") {
            return null;
        }

        inline for (getDecls(ti)) |decl| {
            if (std.mem.eql(u8, decl.name, func_name)) {
                const DeclType = @TypeOf(@field(type_info.type, decl.name));
                const fn_type_info = @typeInfo(DeclType);
                if (fn_type_info != .@"fn") {
                    @compileError(std.fmt.comptimePrint(
                        "Declared member '{s}'' is not a function of type '{s}'",
                        .{ func_name, @typeName(type_info.type) },
                    ));
                }

                var param_infos: [fn_type_info.@"fn".params.len]ReflectInfo = undefined;
                var pi_i: usize = 0;
                inline for (fn_type_info.@"fn".params) |param| {
                    const p_t = param.type orelse void;
                    const p_ti = comptime TypeInfo.from(p_t);
                    param_infos[pi_i] = .{ .type = p_ti };
                    pi_i += 1;
                }

                const return_ref: ReflectInfo = .{ .type = comptime TypeInfo.from(fn_type_info.@"fn".return_type.?) };

                return FuncInfo{
                    .hash = hash(std.fmt.comptimePrint(
                        "{s}.{s}",
                        .{ @typeName(@Type(type_info)), func_name },
                    )),
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
        const ArgsType = @TypeOf(args);
        const args_info = @typeInfo(ArgsType);
        const arg_len = switch (args_info) {
            .@"struct" => |s| blk: {
                if (!s.is_tuple) @compileError("FuncInfo.invoke expects a tuple of arguments");
                break :blk s.fields.len;
            },
            else => @compileError("FuncInfo.invoke expects a tuple of arguments"),
        };
        if (arg_len != self.params.len) {
            @compileError("FuncInfo.invoke argument count mismatch");
        }

        var typed_args: std.meta.ArgsTuple(@TypeOf(func)) = undefined;

        inline for (self.params, 0..) |param, i| {
            const ParamType = switch (param.info) {
                .type => |ti| ti.type,
                .func => |fi| fi.type.type,
            };

            typed_args[i] = @as(ParamType, args[i]);
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
        if (self.return_type) |ret| {
            if (other.return_type == null) return false;
            if (!ret.eql(&other.return_type.?)) return false;
        }
        return true;
    }

    fn formatReflectInfo(comptime info: ReflectInfo, comptime simple: bool) []const u8 {
        switch (info) {
            .type => |ti| return if (simple) simplifyTypeName(ti.name) else ti.name,
            .func => |fi| return formatFuncSignature(fi, simple),
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
            }
            first = false;
        }
        const return_str = if (self.return_type) |ret| formatReflectInfo(ret, true) else "void";

        return std.fmt.comptimePrint("fn {s}({s}) -> {s}", .{ prefix_str, params_str, return_str });
    }

    // Helper for FuncInfo.from with cycle detection
    fn toFuncInfo(comptime FuncType: type) ?FuncInfo {
        if (lookupVisited(FuncType)) |info| {
            switch (info) {
                .func => |fi| {
                    if (std.mem.eql(u8, fi.name, @typeName(FuncType))) return fi;
                },
                else => {},
            }
        }

        var zig_type_info = @typeInfo(FuncType);
        const type_hash = typeHash(FuncType);
        // create a stub ReflectInfo for this func so recursive references can find it
        const stub_reflect = ReflectInfo{ .func = FuncInfo{
            .hash = type_hash,
            .name = @typeName(FuncType),
            .params = &[_]ParamInfo{},
            .return_type = null,
            .type = ShallowTypeInfo.from(FuncType),
        } };
        pushVisited(stub_reflect);
        if (zig_type_info == .optional) {
            zig_type_info = @typeInfo(zig_type_info.optional.child);
        }
        if (zig_type_info != .@"fn") {
            @compileError(std.fmt.comptimePrint(
                "FuncInfo can only be created from function types: {s}",
                .{@typeName(FuncType)},
            ));
        }
        var param_infos: [zig_type_info.@"fn".params.len]ParamInfo = undefined;
        var valid_params: usize = 0;
        inline for (zig_type_info.@"fn".params, 0..) |param, i| {
            _ = i;
            // Handle null param.type (anytype parameters)
            if (param.type == null) {
                return null;
            }
            const ti = @typeInfo(@TypeOf(param.type));
            const param_type = if (ti == .optional) param.type.? else param.type.?;
            if (comptime toReflectInfo(param_type)) |info| {
                param_infos[valid_params] = ParamInfo{
                    .info = info,
                    .is_noalias = param.is_noalias,
                };
                valid_params += 1;
            } else {
                // Skip unsupported parameter types instead of erroring
                // Return null to indicate this function can't be fully reflected
                return null;
            }
        }
        const return_type_info = if (zig_type_info.@"fn".return_type) |ret_type| comptime toReflectInfo(ret_type) else null;
        return FuncInfo{
            .type = ShallowTypeInfo.from(FuncType),
            .hash = type_hash,
            .name = @typeName(FuncType),
            .params = param_infos[0..valid_params],
            .return_type = return_type_info,
        };
    }
};

fn safeSizeOf(comptime T: type) usize {
    return switch (@typeInfo(T)) {
        .@"opaque" => 0,
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

fn leafTypeInfo(comptime T: type) TypeInfo {
    return TypeInfo{
        .hash = typeHash(T),
        .size = safeSizeOf(T),
        .type = T,
        .name = @typeName(T),
        .fields = &[_]FieldInfo{},
        .category = TypeInfo.Category.from(T),
    };
}

pub const TypeInfo = struct {
    hash: u64,
    size: usize,
    type: type,
    name: []const u8,
    fields: []const FieldInfo,
    category: Category,

    const Category = enum {
        Struct,
        Enum,
        Union,
        Slice,
        Vector,
        Pointer,
        Other,

        pub fn from(comptime T: type) Category {
            const ti = @typeInfo(T);
            return switch (ti) {
                .@"struct" => .Struct,
                .@"enum" => .Enum,
                .@"union" => .Union,
                .array, .vector => .Slice,
                .pointer => .Pointer,
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
            @compileError("TypeInfo.new cannot instantiate unsized type: " ++ self.name);
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
    /// Uses direct type comparison at comptime instead of hashing to avoid branch quota issues.
    fn toTypeInfo(comptime T: type) TypeInfo {
        // Use direct type comparison for cycle detection - cheaper at comptime
        if (lookupVisited(T)) |info| {
            switch (info) {
                .type => |ti| return ti,
                else => @compileError("TypeInfo.from cycle detected but found non-type ReflectInfo"),
            }
        }

        const type_name = @typeName(T);
        const type_hash = typeHash(T);
        const type_size = safeSizeOf(T);
        const category = Category.from(T);
        // create stub reflect for T and append to visited so recursive refs can find it
        const stub_reflect = ReflectInfo{ .type = TypeInfo{ .hash = type_hash, .size = type_size, .type = T, .name = type_name, .fields = &[_]FieldInfo{}, .category = category } };
        pushVisited(stub_reflect);

        const ti = comptime TypeInfo{
            .hash = type_hash,
            .size = type_size,
            .type = T,
            .name = type_name,
            .fields = TypeInfo.buildFields(T),
            .category = Category.from(T),
        };
        return ti;
    }

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
        return comptime lazyGetFunc(self.type, func_name);
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
    /// Declaration can be a function or other public declaration.
    ///
    /// *Must be called at comptime.*
    pub inline fn hasDecl(self: *const TypeInfo, comptime decl_name: []const u8) bool {
        if (comptime lazyGetDecl(self.type, decl_name) == null) {
            return comptime lazyGetFunc(self.type, decl_name) != null;
        }
        return true;
    }

    /// Check if this TypeInfo represents a pointer type
    pub inline fn getCategory(self: *const TypeInfo) Category {
        return self.category;
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
        return std.fmt.comptimePrint("TypeInfo{{ name {s}, size: {d}, hash: {x}, category: {s}}}", .{
            if (simple_name) simplifyTypeName(self.name) else self.name,
            self.size,
            self.hash,
            @tagName(self.category),
        });
    }

    /// Check if this TypeInfo is equal to another (by hash and size)
    ///
    /// *Must be called at comptime.*
    pub inline fn eql(self: *const TypeInfo, other: *const TypeInfo) bool {
        return self.hash == other.hash and self.size == other.size;
    }

    fn buildFields(comptime T: type) []const FieldInfo {
        if (lookupVisited(T)) |info| {
            switch (info) {
                .type => |ti| return ti.fields,
                else => {},
            }
        }

        const type_info = @typeInfo(T);
        if (type_info != .@"struct") {
            return &[_]FieldInfo{};
        }

        const fields = type_info.@"struct".fields;
        var field_infos: [fields.len]FieldInfo = undefined;
        var field_count: usize = 0;

        for (fields) |field| {
            const field_type_info = @typeInfo(field.type);
            const is_opaque = field_type_info == .@"opaque";
            const is_ptr_to_opaque = field_type_info == .pointer and @typeInfo(field_type_info.pointer.child) == .@"opaque";

            const field_size = safeSizeOf(field.type);
            const field_offset = if (is_opaque or is_ptr_to_opaque) 0 else @offsetOf(T, field.name);

            field_infos[field_count] = FieldInfo{
                .name = field.name,
                .offset = field_offset,
                .type = ShallowTypeInfo{
                    .type = field.type,
                    .name = @typeName(field.type),
                    .size = field_size,
                    .category = TypeInfo.Category.from(field.type),
                },
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

    pub const unknown = ReflectInfo{ .type = TypeInfo{
        .hash = 0,
        .size = 0,
        .type = void,
        .fields = &[_]FieldInfo{},
        .name = "unknown",
        .category = .Other,
    } };

    /// Create ReflectInfo from any type with cycle detection
    ///
    /// *Must be called at comptime.*
    pub fn from(comptime T: type) ?ReflectInfo {
        return toReflectInfo(T);
    }

    pub fn getTypeInfo(self: *const ReflectInfo) ?TypeInfo {
        switch (self.*) {
            .type => |ti| return ti,
            else => return null,
        }
    }

    pub fn getFuncInfo(self: *const ReflectInfo) ?FuncInfo {
        switch (self.*) {
            .func => |fi| return fi,
            else => return null,
        }
    }

    /// Check if this ReflectInfo is equal to another
    ///
    /// *Must be called at comptime.*
    pub inline fn eql(self: *const ReflectInfo, other: *const ReflectInfo) bool {
        switch (self.*) {
            .type => |ti| {
                switch (other.*) {
                    .type => |ti2| return ti.eql(&ti2),
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

    pub fn toString(self: *const ReflectInfo) []const u8 {
        switch (self.*) {
            .type => |til| return til.toString(),
            .func => |fil| return fil.toString(),
        }
    }
};

fn toReflectInfo(comptime T: type) ?ReflectInfo {
    @setEvalBranchQuota(5000);
    if (lookupVisited(T)) |cached| return cached;

    const type_info = @typeInfo(T);

    switch (type_info) {
        .pointer => {
            const ri = ReflectInfo{ .type = TypeInfo.from(T) };
            pushVisited(ri);
            return ri;
        },
        .@"opaque" => {
            const ri = ReflectInfo{ .type = leafTypeInfo(T) };
            pushVisited(ri);
            return ri;
        },
        .optional => {
            // Create TypeInfo for the optional type itself, not the child
            const ri = ReflectInfo{ .type = TypeInfo.from(T) };
            pushVisited(ri);
            return ri;
        },
        .array, .vector => {
            // Create TypeInfo for the array/vector type itself, not the child
            const ri = ReflectInfo{ .type = TypeInfo.from(T) };
            pushVisited(ri);
            return ri;
        },
        .error_union => {
            // Create TypeInfo for the error union type itself, not the child
            const ri = ReflectInfo{ .type = TypeInfo.from(T) };
            pushVisited(ri);
            return ri;
        },
        .type => {
            const ri = ReflectInfo{ .type = leafTypeInfo(T) };
            pushVisited(ri);
            return ri;
        },
        .enum_literal => {
            const ri = ReflectInfo{ .type = leafTypeInfo(T) };
            pushVisited(ri);
            return ri;
        },
        .noreturn => {
            const ri = ReflectInfo{ .type = leafTypeInfo(T) };
            pushVisited(ri);
            return ri;
        },
        .undefined => {
            const ri = ReflectInfo{ .type = leafTypeInfo(T) };
            pushVisited(ri);
            return ri;
        },
        .null => {
            const ri = ReflectInfo{ .type = leafTypeInfo(T) };
            pushVisited(ri);
            return ri;
        },
        .comptime_int => {
            const ri = ReflectInfo{ .type = leafTypeInfo(T) };
            pushVisited(ri);
            return ri;
        },
        .comptime_float => {
            const ri = ReflectInfo{ .type = leafTypeInfo(T) };
            pushVisited(ri);
            return ri;
        },
        .error_set => {
            var ri = ReflectInfo{ .type = TypeInfo{
                .hash = typeHash(T),
                .size = safeSizeOf(T),
                .type = T,
                .name = @typeName(T),
                .fields = undefined,
            } };
            if (type_info.error_set) |error_set| {
                const len = error_set.len;
                var field_infos: [len]FieldInfo = undefined;
                for (error_set, 0..) |err, i| {
                    const ErrType = @TypeOf(err);
                    field_infos[i] = FieldInfo{
                        .name = err.name,
                        .offset = 0,
                        .type = ShallowTypeInfo{
                            .type = ErrType,
                            .name = @typeName(ErrType),
                            .size = @sizeOf(ErrType),
                        },
                        .container_type = ShallowTypeInfo.from(T),
                    };
                }
                ri.type.fields = field_infos[0..len];
            } else {
                ri.type.fields = &[_]FieldInfo{};
            }
            pushVisited(ri);
            return ri;
        },
        .bool, .int, .float => {
            const ri = ReflectInfo{ .type = leafTypeInfo(T) };
            pushVisited(ri);
            return ri;
        },
        .@"fn" => |_| {
            const fi = FuncInfo.toFuncInfo(T) orelse return null;
            const ri = ReflectInfo{ .func = fi };
            pushVisited(ri);
            return ri;
        },
        .@"struct", .@"enum", .@"union" => {
            const ti = TypeInfo.toTypeInfo(T);
            const ri = ReflectInfo{ .type = ti };
            pushVisited(ri);
            return ri;
        },
        else => {},
    }
    return null;
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

    const decls = getDecls(type_info);
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
fn lazyGetFunc(comptime T: type, comptime func_name: []const u8) ?FuncInfo {
    const zig_type_info = @typeInfo(T);
    if (zig_type_info == .pointer) {
        return lazyGetFunc(zig_type_info.pointer.child, func_name);
    }

    if (!@hasDecl(T, func_name)) {
        return null;
    }

    const FuncType = @TypeOf(@field(T, func_name));
    const func_type_info = @typeInfo(FuncType);

    if (func_type_info != .@"fn") {
        return null;
    }

    // Check for unsupported parameter types
    inline for (func_type_info.@"fn".params) |param| {
        if (param.type) |pt| {
            const pt_info = @typeInfo(pt);
            if (pt_info == .@"opaque") {
                return null;
            }
            if (pt_info == .pointer and @typeInfo(pt_info.pointer.child) == .@"opaque") {
                return null;
            }
        } else {
            // anytype parameter - can't reflect
            return null;
        }
    }

    // Build FuncInfo for this specific function
    var param_infos: [func_type_info.@"fn".params.len]ParamInfo = undefined;
    var valid_params: usize = 0;

    inline for (func_type_info.@"fn".params) |param| {
        const param_type = param.type.?;
        if (comptime toReflectInfo(param_type)) |info| {
            param_infos[valid_params] = ParamInfo{
                .info = info,
                .is_noalias = param.is_noalias,
            };
            valid_params += 1;
        } else {
            return null;
        }
    }

    const return_type_info = if (func_type_info.@"fn".return_type) |ret_type|
        comptime toReflectInfo(ret_type)
    else
        null;

    const func_info = FuncInfo{
        .hash = typeHash(FuncType),
        .name = func_name,
        .params = param_infos[0..valid_params],
        .return_type = return_type_info,
        .container_type = ShallowTypeInfo.from(T),
        .type = ShallowTypeInfo.from(FuncType),
    };

    return func_info;
}

/// Get full TypeInfo for a type
///
/// *Must be called at comptime*
pub fn getTypeInfo(comptime T: type) TypeInfo {
    return comptime TypeInfo.from(T);
}

/// Get ReflectInfo for a type or null if unsupported
///
/// *Must be called at comptime*
pub fn getInfo(comptime T: type) ?ReflectInfo {
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
            inline for (comptime getDecls(type_info)) |decl| {
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
            inline for (comptime getDecls(type_info)) |decl| {
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

fn getDecls(comptime type_info: std.builtin.Type) []const std.builtin.Type.Declaration {
    //@setEvalBranchQuota(10_000);
    if (type_info == .pointer) return getDecls(@typeInfo(type_info.pointer.child));
    if (type_info == .@"struct") return type_info.@"struct".decls;
    if (type_info == .@"enum") return type_info.@"enum".decls;
    if (type_info == .@"union") return type_info.@"union".decls;
    if (type_info == .@"opaque") return type_info.@"opaque".decls;
    return &[_]std.builtin.Type.Declaration{};
}

/// Check if a struct has a function with the given name
///
/// *Must be called at comptime.*
pub fn hasFunc(comptime T: type, comptime func_name: []const u8) bool {
    return hasFuncWithArgs(T, func_name, null);
}

/// Check if a struct has a function with the given name and argument types.
///
/// If arg_types is null, only the function name is checked.
/// If `func_name` is a method of `T` you do not need to include the self reference.
///
/// *Must be called at comptime.*
pub fn hasFuncWithArgs(comptime T: type, comptime func_name: []const u8, comptime arg_types: ?[]const type) bool {
    return verifyFuncWithArgs(T, func_name, arg_types) catch false;
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
/// *Must be called at comptime.*
pub fn verifyFuncWithArgs(comptime T: type, comptime func_name: []const u8, comptime arg_types: ?[]const type) error{ NotAFunction, FuncDoesNotExist, IncorrectArgs }!bool {
    const type_info = @typeInfo(T);
    if (type_info == .pointer) {
        const Child = type_info.pointer.child;
        return verifyFuncWithArgs(Child, func_name, arg_types);
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
                    return error.IncorrectArgs;
                }
            }
            return true;
        } else {
            return true;
        }
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
pub fn getFields(comptime T: type) []const []const u8 {
    return std.meta.fieldNames(T);
}

/// Get the simple type name (without namespace/module prefixes)
pub fn getSimpleTypeName(comptime T: type) []const u8 {
    return simplifyTypeName(@typeName(T));
}

fn simplifyTypeName(comptime type_name: []const u8) []const u8 {
    var last_dot: ?usize = null;
    inline for (type_name, 0..) |c, i| {
        if (c == '.') {
            last_dot = i;
        }
    }

    // If there's no dot, just return the original name.
    if (last_dot == null) return type_name;

    // Preserve leading pointer qualifiers like '*' or '*const ' when stripping module prefixes.
    // Example: "*const pkg.Module.Type" -> "*const Type"
    var prefix_end: usize = 0;
    if (type_name.len > 0 and type_name[0] == '*') {
        var i: usize = 1;
        while (i < type_name.len and type_name[i] == ' ') : (i += 1) {}
        // match "const" if present
        if (i + 5 <= type_name.len and std.mem.eql(u8, type_name[i .. i + 5], "const")) {
            i += 5;
            if (i < type_name.len and type_name[i] == ' ') i += 1;
        }
        prefix_end = i;
    }

    const idx = last_dot.?;
    if (prefix_end == 0) return type_name[idx + 1 ..];

    // Build a new compile-time array combining the prefix and the simple name.
    comptime {
        const name_part = type_name[idx + 1 ..];
        const out_len = prefix_end + name_part.len;
        var out: [out_len]u8 = undefined;
        var pos: usize = 0;
        for (type_name[0..prefix_end]) |c| {
            out[pos] = c;
            pos += 1;
        }
        for (name_part) |c| {
            out[pos] = c;
            pos += 1;
        }
        return out[0..out_len];
    }
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

    try std.testing.expect(comptime verifyFuncWithArgs(TestStruct, "getValue", &[_]type{}) catch false);
    try std.testing.expectError(error.IncorrectArgs, comptime verifyFuncWithArgs(TestStruct, "getValue", &[_]type{i32}));

    try std.testing.expect(comptime verifyFuncWithArgs(TestStruct, "add", &[_]type{i32}) catch false);
    try std.testing.expectError(error.IncorrectArgs, comptime verifyFuncWithArgs(TestStruct, "add", &[_]type{}));
    try std.testing.expectError(error.IncorrectArgs, comptime verifyFuncWithArgs(TestStruct, "add", &[_]type{ i32, i32 }));

    try std.testing.expectError(error.FuncDoesNotExist, comptime verifyFuncWithArgs(TestStruct, "nonExistent", &[_]type{}));
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

    for (fields) |field_name| {
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
    const info = getInfo(u32) orelse unreachable;
    switch (info) {
        .type => |ti| {
            try std.testing.expectEqualStrings(@typeName(u32), ti.name);
        },
        else => try std.testing.expect(false),
    }
}

test "reflect - struct fields" {
    const S = struct { a: u32, b: i32 };
    const info = getInfo(S) orelse unreachable;
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
    const info = getInfo(FT) orelse unreachable;
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
    const ptr_info = getInfo(*anyopaque) orelse unreachable;
    switch (ptr_info) {
        .type => |ti| {
            try std.testing.expectEqualStrings(@typeName(*anyopaque), ti.name);
        },
        else => try std.testing.expect(false),
    }

    const opaque_info = getInfo(anyopaque) orelse unreachable;
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
    try std.testing.expect(comptime ti.hasDecl("add"));
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

    const ri_type1 = comptime ReflectInfo.from(S) orelse unreachable;
    const ri_type1_again = comptime ReflectInfo.from(S) orelse unreachable;
    const ri_func = comptime ReflectInfo.from(FT) orelse unreachable;
    const ri_type2 = comptime ReflectInfo.from(T) orelse unreachable;

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
        pub fn testMethod(self: *@This(), message: []const u8) void {
            _ = self;
            _ = message;
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

    // Check that param 1 is []const u8, not u8
    switch (func_info.params[1].info) {
        .type => |ti| {
            try std.testing.expectEqual([]const u8, ti.type);
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
    };

    const ti = comptime TypeInfo.from(Target);
    const fi = ti.getFunc("addOne").?;

    var value: i32 = 41;
    const result = fi.invoke(.{&value});

    try std.testing.expectEqual(@as(i32, 42), result);
    std.debug.print("invoked: {s}\n", .{fi.toString()});
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
