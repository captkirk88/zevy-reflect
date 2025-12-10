const std = @import("std");

pub const Unknown = ReflectInfo.unknown;

pub inline fn typeHash(comptime T: type) u64 {
    return std.hash.Wyhash.hash(0, @typeName(T));
}

pub inline fn hash(data: []const u8) u64 {
    return std.hash.Wyhash.hash(0, data);
}

pub inline fn hashWithSeed(data: []const u8, seed: u64) u64 {
    return std.hash.Wyhash.hash(seed, data);
}

/// Shallow type information for field types - doesn't recurse into nested types.
/// This avoids comptime explosion when reflecting complex types with many nested fields.
pub const ShallowTypeInfo = struct {
    type: type,
    name: []const u8,
    size: usize,

    pub fn from(comptime T: type) ShallowTypeInfo {
        return ShallowTypeInfo{
            .type = T,
            .name = @typeName(T),
            .size = @sizeOf(T),
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
                    f.container_info = ti;
                    return f;
                } else {
                    return null;
                }
            },
            .field => |fii| {
                if (std.mem.eql(u8, fii.name, field_name) and fii.container_type == container_info.type) {
                    return fii;
                } else {
                    return null;
                }
            },
            else => return null,
        }
    }

    /// Check if this FieldInfo is equal to another
    ///
    /// *Must be called at comptime.*
    pub fn eql(self: *const FieldInfo, other: *const FieldInfo) bool {
        return self.container_type.eql(&other.container_type) and std.mem.eql(u8, self.name, other.name);
    }
};

pub const FuncInfo = struct {
    hash: u64,
    name: []const u8,
    params: []const ReflectInfo,
    return_type: ?ReflectInfo,

    /// Create FuncInfo from a function type
    fn from(comptime FuncType: type) ?FuncInfo {
        return comptime toFuncInfo(FuncType, &[_]ReflectInfo{});
    }

    /// Create FuncInfo for a method of a struct given the struct's TypeInfo and method name
    fn fromMethod(comptime type_info: *const TypeInfo, comptime func_name: []const u8) ?FuncInfo {
        const ti = @typeInfo(type_info.type);
        if (ti != .@"struct") {
            return null;
        }
        inline for (getDecls(ti)) |decl| {
            if (std.mem.eql(u8, decl.name, func_name)) {
                const fn_type_info = @typeInfo(@TypeOf(@field(type_info.type, decl.name)));
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
                    param_infos[pi_i] = ReflectInfo{ .type = p_ti };
                    pi_i += 1;
                }

                const return_ref = if (fn_type_info.@"fn".return_type) |ret_type| ReflectInfo{ .type = comptime TypeInfo.from(ret_type) } else null;

                return FuncInfo{
                    .hash = hash(std.fmt.comptimePrint(
                        "{s}.{s}",
                        .{ @typeName(@Type(type_info)), func_name },
                    )),
                    .name = decl.name,
                    .params = param_infos[0..pi_i],
                    .return_type = return_ref,
                };
            }
        }
        return null;
    }

    pub fn getParam(self: *const FuncInfo, index: usize) ?TypeInfo {
        if (index >= self.params.len) return null;
        return self.params[index];
    }

    pub fn paramsCount(self: *const FuncInfo) usize {
        return self.params.len;
    }

    /// Get a string representation of the function signature
    ///
    /// *Does not need to be called at comptime.*
    pub inline fn toString(self: *const FuncInfo) []const u8 {
        return comptime self.getStringRepresentation();
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

    fn getStringRepresentation(self: *const FuncInfo) []const u8 {
        var params_str: []const u8 = "";
        var first: bool = true;
        inline for (self.params) |param| {
            switch (param) {
                .type => |ti| {
                    if (first) params_str = ti.name else params_str = std.fmt.comptimePrint("{s}, {s}", .{ params_str, ti.name });
                },
                .func => |fi| {
                    if (first) params_str = fi.name else params_str = std.fmt.comptimePrint("{s}, {s}", .{ params_str, fi.name });
                },
                .field => |_| {},
            }
            first = false;
        }
        const return_str = if (self.return_type) |ret| switch (ret) {
            .type => |ti| ti.name,
            .func => |fi| fi.name,
            .field => |_| "void",
        } else "void";

        return std.fmt.comptimePrint("fn {s}({s}) -> {s}", .{ self.name, params_str, return_str });
    }

    // Helper for FuncInfo.from with cycle detection
    fn toFuncInfo(comptime FuncType: type, comptime visited: []const ReflectInfo) ?FuncInfo {
        inline for (visited) |info| {
            switch (info) {
                .func => |fi| {
                    if (std.mem.eql(u8, fi.name, @typeName(FuncType))) return fi;
                },
                else => {},
            }
        }

        var type_info = @typeInfo(FuncType);
        const type_hash = typeHash(FuncType);
        // create a stub ReflectInfo for this func so recursive references can find it
        const stub_reflect = ReflectInfo{ .func = FuncInfo{
            .hash = type_hash,
            .name = @typeName(FuncType),
            .params = &[_]ReflectInfo{},
            .return_type = null,
        } };
        const next_visited = visited ++ [_]ReflectInfo{stub_reflect};
        if (type_info == .optional) {
            type_info = @typeInfo(type_info.optional.child);
        }
        if (type_info != .@"fn") {
            @compileError(std.fmt.comptimePrint(
                "FuncInfo can only be created from function types: {s}",
                .{@typeName(FuncType)},
            ));
        }
        var param_infos: [type_info.@"fn".params.len]ReflectInfo = undefined;
        var valid_params: usize = 0;
        inline for (type_info.@"fn".params, 0..) |param, i| {
            _ = i;
            // Handle null param.type (anytype parameters)
            if (param.type == null) {
                return null;
            }
            const ti = @typeInfo(@TypeOf(param.type));
            const param_type = if (ti == .optional) param.type.? else param.type.?;
            if (comptime toReflectInfo(param_type, next_visited)) |info| {
                param_infos[valid_params] = info;
                valid_params += 1;
            } else {
                // Skip unsupported parameter types (like *anyopaque) instead of erroring
                // Return null to indicate this function can't be fully reflected
                return null;
            }
        }
        const return_type_info = if (type_info.@"fn".return_type) |ret_type| comptime toReflectInfo(ret_type, next_visited) else null;
        return FuncInfo{
            .hash = type_hash,
            .name = @typeName(FuncType),
            .params = param_infos[0..valid_params],
            .return_type = return_type_info,
        };
    }
};

pub const TypeInfo = struct {
    hash: u64,
    size: usize,
    type: type,
    name: []const u8,
    fields: []const FieldInfo,

    /// Create `TypeInfo` from any type except opaque types (like `anyopaque`)
    ///
    /// *Must be called at comptime.*
    ///
    /// TODO handle opaque types better
    fn from(comptime T: type) TypeInfo {
        return comptime toTypeInfo(T, &[_]ReflectInfo{});
    }

    /// Helper for TypeInfo.from with cycle detection
    /// Uses direct type comparison at comptime instead of hashing to avoid branch quota issues.
    fn toTypeInfo(comptime T: type, comptime visited: []const ReflectInfo) TypeInfo {
        // Use direct type comparison for cycle detection - cheaper at comptime
        inline for (visited) |info| {
            switch (info) {
                .type => |ti| {
                    if (ti.type == T) return ti;
                },
                else => {},
            }
        }

        const type_name = @typeName(T);
        const type_hash = typeHash(T);

        // create stub reflect for T and append to visited so recursive refs can find it
        const stub_reflect = ReflectInfo{ .type = TypeInfo{ .hash = type_hash, .size = @sizeOf(T), .type = T, .name = type_name, .fields = &[_]FieldInfo{} } };
        const next_visited = visited ++ [_]ReflectInfo{stub_reflect};

        const ti = comptime TypeInfo{
            .hash = type_hash,
            .size = @sizeOf(T),
            .type = T,
            .name = type_name,
            .fields = TypeInfo.buildFields(T, next_visited),
        };
        return ti;
    }

    pub fn getField(self: *const TypeInfo, field_name: []const u8) ?FieldInfo {
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
    pub fn getDecl(self: *const TypeInfo, comptime decl_name: []const u8) ?TypeInfo {
        return comptime lazyGetDecl(self.type, decl_name);
    }

    /// Get a function by name.
    ///
    /// *Does not need to be called at comptime.*
    pub fn getFunc(self: *const TypeInfo, comptime func_name: []const u8) ?FuncInfo {
        return comptime lazyGetFunc(self.type, func_name);
    }

    /// Get the names of all type decls (non-function declarations).
    ///
    /// *Must be called at comptime.*
    pub fn getDeclNames(self: *const TypeInfo) []const []const u8 {
        return comptime lazyGetDeclNames(self.type, .types_only);
    }

    /// Get the names of all function decls.
    ///
    /// *Must be called at comptime.*
    pub fn getFuncNames(self: *const TypeInfo) []const []const u8 {
        return comptime lazyGetDeclNames(self.type, .funcs_only);
    }

    /// Check if this type has a declaration with the given name.
    ///
    /// Declaration can be a function or other public declaration.
    ///
    /// *Must be called at comptime.*
    pub fn hasDecl(self: *const TypeInfo, comptime decl_name: []const u8) bool {
        if (comptime lazyGetDecl(self.type, decl_name) == null) {
            return comptime lazyGetFunc(self.type, decl_name) != null;
        }
        return true;
    }

    /// Get a string representation of the type info
    ///
    /// *Does not need to be called at comptime.*
    pub inline fn toString(self: *const TypeInfo) []const u8 {
        return comptime self.getStringRepresentation();
    }

    fn getStringRepresentation(self: *const TypeInfo) []const u8 {
        return std.fmt.comptimePrint("TypeInfo{{ name {s}, size: {d}, hash: {x}, type: {s}}}", .{
            self.name,
            self.size,
            self.hash,
            @typeName(self.type),
        });
    }

    /// Check if this TypeInfo is equal to another (by hash and size)
    ///
    /// *Must be called at comptime.*
    pub fn eql(self: *const TypeInfo, other: *const TypeInfo) bool {
        return self.hash == other.hash and self.size == other.size;
    }

    fn buildFields(comptime T: type, comptime visited: []const ReflectInfo) []const FieldInfo {
        _ = visited; // No longer needed since we don't recurse
        const type_info = @typeInfo(T);
        if (type_info != .@"struct") {
            return &[_]FieldInfo{};
        }
        const fields = blk: {
            if (type_info == .@"struct") break :blk type_info.@"struct".fields;
            if (type_info == .@"enum") break :blk type_info.@"enum".fields;
            if (type_info == .@"union") break :blk type_info.@"union".fields;
            @compileError("Type is not a struct, enum, or union");
        };
        var field_infos: [fields.len]FieldInfo = undefined;
        var field_count: usize = 0;
        for (fields) |field| {
            // Skip fields with opaque types
            const field_type_info = @typeInfo(field.type);
            if (field_type_info == .@"opaque") continue;
            if (field_type_info == .pointer and @typeInfo(field_type_info.pointer.child) == .@"opaque") continue;

            // Use shallow type info - doesn't recurse into nested types
            field_infos[field_count] = FieldInfo{
                .name = field.name,
                .offset = @offsetOf(T, field.name),
                .type = ShallowTypeInfo{
                    .type = field.type,
                    .name = @typeName(field.type),
                    .size = @sizeOf(field.type),
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
    field: FieldInfo,

    pub const unknown = ReflectInfo{ .type = TypeInfo{
        .hash = 0,
        .size = 0,
        .type = void,
        .fields = &[_]FieldInfo{},
        .name = "unknown",
    } };

    /// Create ReflectInfo from any type with cycle detection
    ///
    /// *Must be called at comptime.*
    pub fn from(comptime T: type) ?ReflectInfo {
        return toReflectInfo(T, &[_]ReflectInfo{});
    }

    /// Check if this ReflectInfo is equal to another
    ///
    /// *Must be called at comptime.*
    pub fn eql(self: *const ReflectInfo, other: *const ReflectInfo) bool {
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
            .field => |fii| {
                switch (other.*) {
                    .field => |fii2| return fii.eql(&fii2),
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

fn toReflectInfo(comptime T: type, comptime visited: []const ReflectInfo) ?ReflectInfo {
    // If already visited, return the visited ReflectInfo - use direct type comparison
    inline for (visited) |info| {
        switch (info) {
            .type => |ti| {
                if (ti.type == T) return info;
            },
            .func => |fi| {
                // For functions, compare names since we don't have direct type
                if (std.mem.eql(u8, fi.name, @typeName(T))) return info;
            },
            .field => |fii| {
                if (fii.type.type) return info;
            },
        }
    }
    const type_info = @typeInfo(T);

    switch (type_info) {
        .pointer => |info| {
            const Child = info.pointer.child;
            // Handle pointer to opaque (like *anyopaque)
            if (@typeInfo(Child) == .@"opaque") {
                return null;
            }
            return toReflectInfo(Child, visited);
        },
        .@"opaque" => {
            return null;
        },
        .optional => |info| {
            const Child = info.optional.child;
            return toReflectInfo(Child, visited);
        },
        .array, .vector => |info| {
            const Child = switch (info) {
                .array => info.array.child,
                .vector => info.vector.child,
                else => void,
            };
            return toReflectInfo(Child, visited);
        },
        .error_union => |info| {
            const Child = info.error_union.error_set;
            return toReflectInfo(Child, visited);
        },
        .error_set => {
            var ri = ReflectInfo{ .type = TypeInfo{
                .hash = typeHash(T),
                .size = @sizeOf(T),
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
            return ri;
        },
        .bool, .int, .float => {
            return ReflectInfo{ .type = TypeInfo{
                .hash = typeHash(T),
                .size = @sizeOf(T),
                .type = T,
                .name = @typeName(T),
                .fields = &[_]FieldInfo{},
            } };
        },
        .@"fn" => |_| {
            const fi = FuncInfo.toFuncInfo(T, visited) orelse return null;
            return ReflectInfo{ .func = fi };
        },
        .@"struct", .@"enum", .@"union" => {
            const ti = TypeInfo.toTypeInfo(T, visited);
            return ReflectInfo{ .type = ti };
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
    if (!@hasDecl(T, func_name)) {
        return null;
    }

    const DeclType = @TypeOf(@field(T, func_name));
    const decl_type_info = @typeInfo(DeclType);

    if (decl_type_info != .@"fn") {
        return null;
    }

    // Check for unsupported parameter types
    inline for (decl_type_info.@"fn".params) |param| {
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
    var param_infos: [decl_type_info.@"fn".params.len]ReflectInfo = undefined;
    var valid_params: usize = 0;

    inline for (decl_type_info.@"fn".params) |param| {
        const param_type = param.type.?;
        if (toReflectInfo(param_type, &[_]ReflectInfo{})) |info| {
            param_infos[valid_params] = info;
            valid_params += 1;
        } else {
            return null;
        }
    }

    const return_type_info = if (decl_type_info.@"fn".return_type) |ret_type|
        toReflectInfo(ret_type, &[_]ReflectInfo{})
    else
        null;

    return FuncInfo{
        .hash = hash(std.fmt.comptimePrint("{s}.{s}", .{ @typeName(T), func_name })),
        .name = func_name,
        .params = param_infos[0..valid_params],
        .return_type = return_type_info,
    };
}

/// Get full TypeInfo for a type
pub fn getTypeInfo(comptime T: type) TypeInfo {
    return comptime TypeInfo.from(T);
}

/// Get ReflectInfo for a type or null if unsupported
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
pub fn hasField(comptime T: type, field_name: []const u8) bool {
    const type_info = @typeInfo(T);
    const fields = blk: {
        if (type_info == .@"struct") break :blk type_info.@"struct".fields;
        if (type_info == .@"enum") break :blk type_info.@"enum".fields;
        if (type_info == .@"union") break :blk type_info.@"union".fields;
        if (type_info == .pointer) {
            const Child = type_info.pointer.child;
            return hasField(Child, field_name);
        }
        if (type_info == .optional) {
            const Child = type_info.optional.child;
            return hasField(Child, field_name);
        }
        return false;
    };
    inline for (fields) |field| {
        if (std.mem.eql(u8, field.name, field_name)) {
            return true;
        }
    }
    return false;
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
        .pointer => |info| return getField(info.pointer.child),
        .optional => |info| return getField(info.optional.child),
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
                switch (p) {
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

test "reflect - ReflectInfo.field variant eql" {
    const S = struct { a: u32, b: i32 };
    const T = struct { x: u32, y: i32 };

    const ri_field1 = comptime ReflectInfo{ .field = TypeInfo.from(S).fields[0] };
    const ri_field2 = comptime ReflectInfo{ .field = TypeInfo.from(S).fields[0] };
    const ri_field_other = comptime ReflectInfo{ .field = TypeInfo.from(T).fields[0] };

    try std.testing.expect(comptime ri_field1.eql(&ri_field2));
    try std.testing.expect(comptime !ri_field1.eql(&ri_field_other));
}
