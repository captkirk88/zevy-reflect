const std = @import("std");
const reflect = @import("reflect.zig");

/// Creates an interface validator from a template type.
/// Returns a type that can validate and constrain implementations.
///
/// This is similar to traits or interfaces in other languages, but uses
/// compile-time reflection to verify that a type implements the required
/// methods defined in the template type and can generate vtables with injected
/// self parameters that match the implementation type.
///
/// No more `@ptrCast(@alignCast(&myStructInstance))` shenanigans!
///
/// Example:
/// ```zig
/// // Define your template
/// const Drawable = Template(struct {
///     pub fn draw(self: *@This()) void { unreachable; }
/// });
///
/// // Define concrete implementations
/// const Sprite = struct {
///    pub fn draw(self: *@This()) void {
///       // draw the sprite
///   }
/// };
///
/// // Validate that Sprite satisfies the Drawable interface
/// Drawable.validate(Sprite);
///
/// // Create an interface instance from a concrete implementation
/// var sprite = Sprite{};
/// var interface: Drawable.Interface = undefined; // the interface type
/// Drawable.populate(&interface, &sprite);
/// interface.vtable.draw(interface.ptr);
/// ```
pub inline fn Template(comptime Tpl: type) type {
    // If Tpl is already a Template, return it directly
    {
        const t_info = reflect.getTypeInfo(Tpl);
        if (t_info.category != .Struct and t_info.category != .Enum and t_info.category != .Union) {
            @compileError("Template " ++ reflect.getSimpleTypeName(Tpl) ++ "' cannot be created from " ++ @tagName(t_info.category) ++ " types");
        }
        if (t_info.hasDecl("TemplateType")) return Tpl;
    }

    return struct {
        fn getTplInfo() reflect.TypeInfo {
            return reflect.getTypeInfo(Tpl);
        }

        pub const Name = blk: {
            if (@hasDecl(Tpl, "Name")) {
                const NameValue = @field(Tpl, "Name");
                const NameType = @TypeOf(NameValue);
                if (NameType == []const u8) {
                    break :blk NameValue;
                } else {
                    @compileError(@typeName(Tpl) ++ " 'Name' must be []const u8");
                }
            }
            const t_info = reflect.getTypeInfo(Tpl);
            break :blk t_info.toStringEx(true);
        };

        fn resolveTemplateType(comptime T: type) type {
            const t_info = reflect.getTypeInfo(T);
            const func_names = t_info.getFuncNames();
            if (func_names.len == 0) return T;

            var fields: [func_names.len]std.builtin.Type.StructField = undefined;
            for (func_names, 0..) |name, i| {
                const func_info = t_info.getFunc(name);
                if (func_info) |func| {
                    const PtrType = @TypeOf(func.toPtr());
                    const p = @typeInfo(PtrType).pointer;
                    const child = p.child;
                    const new_child = substituteFunctionType(child, T, anyopaque);
                    const NormalizedPtrType = @Type(.{ .pointer = .{
                        .child = new_child,
                        .is_const = p.is_const,
                        .is_volatile = p.is_volatile,
                        .is_allowzero = p.is_allowzero,
                        .size = p.size,
                        .alignment = p.alignment,
                        .sentinel_ptr = p.sentinel_ptr,
                        .address_space = p.address_space,
                    } });
                    fields[i] = .{
                        .name = name[0..name.len :0],
                        .type = NormalizedPtrType,
                        .default_value_ptr = null,
                        .is_comptime = false,
                        .alignment = @alignOf(NormalizedPtrType),
                    };
                } else {
                    @compileError("Template method info not found for '" ++ name ++ "'' in " ++ Name);
                }
            }

            return @Type(.{ .@"struct" = .{
                .layout = .auto,
                .fields = &fields,
                .decls = &.{},
                .is_tuple = false,
            } });
        }

        pub const TemplateType = resolveTemplateType(Tpl);
        pub const types: []const type = &[_]type{TemplateType};

        const _Interface = blk: {
            //const func_names = reflect.getTypeInfo(Tpl).getFuncNames();
            //const field_count = func_names.len + 2;
            var fields: [2]std.builtin.Type.StructField = undefined;

            fields[0] = .{
                .name = "ptr",
                .type = *Tpl,
                .default_value_ptr = null,
                .is_comptime = false,
                .alignment = @alignOf(*Tpl),
            };

            fields[1] = .{
                .name = "vtable",
                .type = TemplateType,
                .default_value_ptr = null,
                .is_comptime = false,
                .alignment = @alignOf(TemplateType),
            };

            // for (func_names, 0..) |func_name, i| {
            //     const FieldType = @TypeOf(@field(@as(TemplateType, undefined), func_name));
            //     fields[i + 2] = .{
            //         .name = func_name[0..func_name.len :0],
            //         .type = FieldType,
            //         .default_value_ptr = null,
            //         .is_comptime = false,
            //         .alignment = @alignOf(FieldType),
            //     };
            // }

            break :blk @Type(.{ .@"struct" = .{
                .layout = .auto,
                .fields = &fields,
                .decls = &.{},
                .is_tuple = false,
            } });
        };

        /// The interface type containing `ptr` and `vtable` fields.
        pub const Interface: type = _Interface;

        /// Create a interface instance from a pointer to a concrete implementation.
        ///
        /// Usage:
        /// ```zig
        /// const DoSomething = Template(struct {
        ///     pub fn doSomething(self: *@This(), value: u32) u32 {
        ///         unreachable;
        ///     }
        /// });
        ///
        /// const DoingSomething = struct {
        ///     pub fn doSomething(self: *DoingSomething, value: u32) u32 {
        ///         return value;  // did something
        ///     }
        /// };
        /// const interface = DoSomething.interface(DoingSomething, .{});
        /// interface.doSomething(42);
        /// ```
        pub fn interfaceFromPtr(comptime Implementation: type, inst: *Implementation) blk: {
            validate(Implementation);
            break :blk Interface;
        } {
            return interfaceRaw(Implementation, @ptrCast(@alignCast(inst)));
        }

        pub fn interfaceRaw(Implementation: type, inst: *anyopaque) blk: {
            validate(Implementation);
            break :blk Interface;
        } {
            var _interface: _Interface = undefined;
            _interface.ptr = @ptrCast(@alignCast(inst));
            _interface.vtable = vTableAsTemplate(Implementation);

            //populateMethods(&_interface);

            return _interface;
        }

        /// Populates an existing interface instance from a concrete implementation.
        ///
        /// Usage:
        /// ```zig
        /// Template(...).populate(&interface_instance, &impl_instance);
        /// ```
        pub fn populate(iface: *Interface, inst: anytype) void {
            iface.ptr = @ptrCast(@alignCast(inst));
            iface.vtable = comptime blk: {
                const InstType = @TypeOf(inst);
                if (@typeInfo(InstType) != .pointer) {
                    @compileError("populate requires a pointer to the implementation (e.g. &inst), got value of type " ++ reflect.getSimpleTypeName(InstType));
                }
                const Implementation = @typeInfo(InstType).pointer.child;
                break :blk vTableAsTemplate(Implementation);
            };
        }

        /// Populate an interface instance from a value type by allocating it on the heap.
        ///
        /// *Caller is responsible for freeing the allocated implementation instance.*
        pub fn populateFromValue(iface: *Interface, allocator: std.mem.Allocator, inst: anytype) !blk: {
            const InstType = @TypeOf(inst);
            break :blk *InstType;
        } {
            const InstType = @TypeOf(inst);
            if (@typeInfo(InstType) == .pointer) {
                @compileError("populateFromValue requires a value type for the implementation, got pointer type " ++ reflect.getSimpleTypeName(InstType));
            }

            const impl_ptr = try allocator.create(InstType);
            impl_ptr.* = inst;
            iface.ptr = @ptrCast(@alignCast(impl_ptr));
            iface.vtable = comptime blk: {
                const Implementation = InstType;
                break :blk vTableAsTemplate(Implementation);
            };

            return impl_ptr;
        }

        fn populateMethods(iface: *Interface) void {
            inline for (reflect.getTypeInfo(Tpl).getFuncNames()) |func_name| {
                @field(iface, func_name) = @field(iface.vtable, func_name);
            }
        }

        /// Validates that a type satisfies this interface.
        pub fn validate(implementationType: type) void {
            validateThis(implementationType, false);
        }

        /// Validates that a type satisfies this interface with verbose error messages.
        pub fn validateVerbose(implementationType: type) void {
            validateThis(implementationType, true);
        }

        fn validateThis(implementationType: type, comptime verbose: bool) void {
            const Implementation = implementationType;

            comptime {
                const impl_info = reflect.TypeInfo.from(Implementation);
                const func_names = getTplInfo().getFuncNames();
                const tmpl_struct_fields = getTplInfo().fields;

                var missing_methods: []const []const u8 = &.{};

                // Handle template vtables defined as fields (e.g. function pointer structs)
                if (func_names.len == 0) {
                    for (tmpl_struct_fields) |fld| {
                        const impl_func_info = impl_info.getFunc(fld.name);
                        if (impl_func_info == null) {
                            missing_methods = missing_methods ++ &[_][]const u8{fld.name ++ ": " ++ fld.type.name};
                            continue;
                        }

                        // Presence is enough here; signature compatibility is checked when casting vtables.
                    }
                }

                for (func_names) |method_name| {
                    const tmpl_func_info = getTplInfo().getFunc(method_name) orelse {
                        @compileError("We should not be seeing this at all");
                    };
                    const impl_func_info = impl_info.getFunc(method_name);

                    var func_params: [tmpl_func_info.params.len]reflect.ParamInfo = undefined;
                    for (0..tmpl_func_info.params.len) |j| {
                        func_params[j] = tmpl_func_info.params[j];
                        switch (func_params[j].info) {
                            .type => |ti| {
                                // If the param is exactly the template type, replace with Implementation
                                if (ti.type == Tpl) {
                                    func_params[j] = reflect.ParamInfo{
                                        .info = .{ .type = reflect.TypeInfo.from(Implementation) },
                                        .is_comptime = func_params[j].is_comptime,
                                    };
                                } else {
                                    // If it's a pointer to the template (e.g. *Template or *const Template),
                                    // construct a corresponding pointer-to-Implementation preserving constness.
                                    if (@typeInfo(ti.type) == .pointer) {
                                        const p = @typeInfo(ti.type).pointer;
                                        const child = p.child;
                                        if (child == Tpl) {
                                            const new_ptr_type = if (p.is_const) *const Implementation else *Implementation;
                                            func_params[j] = reflect.ParamInfo{
                                                .info = .{ .type = reflect.TypeInfo.from(new_ptr_type) },
                                                .is_comptime = func_params[j].is_comptime,
                                            };
                                        } else {
                                            func_params[j] = reflect.ParamInfo{ .info = .{ .type = ti }, .is_comptime = func_params[j].is_comptime };
                                        }
                                    } else {
                                        func_params[j] = reflect.ParamInfo{ .info = .{ .type = ti }, .is_comptime = func_params[j].is_comptime };
                                    }
                                }
                            },
                            .func => |fi| {
                                // Substitute types within the function signature
                                func_params[j] = reflect.ParamInfo{
                                    .info = substituteType(.{ .func = fi }, Tpl, Implementation),
                                    .is_comptime = func_params[j].is_comptime,
                                };
                            },
                        }
                    }

                    const mixed_func_info = reflect.FuncInfo{
                        .name = tmpl_func_info.name,
                        .params = func_params[0..tmpl_func_info.params.len],
                        .return_type = tmpl_func_info.return_type,
                        .container_type = impl_info.toShallow(),
                        .hash = tmpl_func_info.hash,
                        .type = tmpl_func_info.type,
                    };
                    if (impl_func_info == null) {
                        missing_methods = missing_methods ++ &[_][]const u8{mixed_func_info.toStringEx(false, !verbose)};
                    } else {
                        // Check if parameters match (handling self parameters)
                        var param_match = true;

                        if (tmpl_func_info.params.len != impl_func_info.?.params.len) {
                            param_match = false;
                        } else {
                            for (tmpl_func_info.params, 0..) |tmpl_param, i| {
                                const impl_param = impl_func_info.?.params[i];
                                var expected_param = tmpl_param;

                                // If the template parameter itself is a function type, rewrite any
                                // embedded references to the template type so we compare against
                                // the implementation's signature (e.g. fn(*Template) -> void).
                                switch (tmpl_param.info) {
                                    .func => {
                                        expected_param = reflect.ParamInfo{
                                            .info = substituteType(tmpl_param.info, Tpl, Implementation),
                                            .is_noalias = tmpl_param.is_noalias,
                                            .is_comptime = tmpl_param.is_comptime,
                                        };
                                    },
                                    else => {},
                                }

                                // Check if template param references the template type (self parameter)
                                var is_tmpl_self = false;
                                var tmpl_is_const = false;
                                switch (tmpl_param.info) {
                                    .type => |ti| {
                                        const tmpl_type = ti.type;
                                        if (tmpl_type == Tpl) {
                                            is_tmpl_self = true;
                                        } else if (@typeInfo(tmpl_type) == .pointer) {
                                            const ptr_info = @typeInfo(tmpl_type).pointer;
                                            const child = ptr_info.child;
                                            if (child == Tpl) {
                                                is_tmpl_self = true;
                                                tmpl_is_const = ptr_info.is_const;
                                            }
                                        }
                                    },
                                    else => {},
                                }

                                // Check if impl param references the impl type (self parameter)
                                var is_impl_self = false;
                                var impl_is_const = false;
                                switch (impl_param.info) {
                                    .type => |ti| {
                                        const impl_type = ti.type;
                                        if (impl_type == Implementation) {
                                            is_impl_self = true;
                                        } else if (@typeInfo(impl_type) == .pointer) {
                                            const ptr_info = @typeInfo(impl_type).pointer;
                                            const child = ptr_info.child;
                                            if (child == Implementation) {
                                                is_impl_self = true;
                                                impl_is_const = ptr_info.is_const;
                                            }
                                        }
                                    },
                                    else => {},
                                }

                                // Both are self parameters - check const correctness
                                if (is_tmpl_self and is_impl_self) {
                                    // Template is mutable but impl is const - error (can't mutate through const ptr)
                                    if (!tmpl_is_const and impl_is_const) {
                                        param_match = false;
                                        break;
                                    }
                                    // Template is const and impl is const - ok
                                    // Template is const and impl is mutable - ok (can call mutable through const)
                                    // Template is mutable and impl is mutable - ok
                                    continue;
                                }

                                // If only one is self, mismatch
                                if (is_tmpl_self != is_impl_self) {
                                    param_match = false;
                                    break;
                                }

                                // Otherwise check if they're equal
                                if (!impl_param.eql(&expected_param)) {
                                    param_match = false;
                                    break;
                                }
                            }
                        }

                        if (!param_match) {
                            missing_methods = missing_methods ++ &[_][]const u8{mixed_func_info.toStringEx(false, !verbose)};
                        }
                    }
                }

                if (missing_methods.len > 0) {
                    var error_msg: []const u8 = "Implementation '" ++ impl_info.toStringEx(!verbose) ++ "' ";
                    error_msg = error_msg ++ "does not satisfy interface '" ++ Name ++ "'. ";

                    error_msg = error_msg ++ "Missing methods:\n";
                    for (missing_methods) |method| {
                        error_msg = error_msg ++ "  - " ++ method ++ "\n";
                    }
                    @compileError(error_msg);
                }
            }
        }

        /// Helper function to substitute Template with Implementation in ReflectInfo recursively
        fn substituteType(comptime info: reflect.ReflectInfo, comptime template_type: type, comptime impl_type: type) reflect.ReflectInfo {
            switch (info) {
                .type => |ti| {
                    const new_type = substituteTypeInType(ti.type, template_type, impl_type);
                    return .{ .type = reflect.TypeInfo.from(new_type) };
                },
                .func => |fi| {
                    const new_fn_type = substituteFunctionType(fi.type.type, template_type, impl_type);
                    var new_params: [fi.params.len]reflect.ParamInfo = undefined;
                    for (fi.params, 0..) |param, i| {
                        new_params[i] = reflect.ParamInfo{
                            .info = substituteType(param.info, template_type, impl_type),
                            .is_noalias = param.is_noalias,
                            .is_comptime = param.is_comptime,
                        };
                    }
                    const new_return = if (fi.return_type) |ret| substituteType(ret, template_type, impl_type) else null;
                    const new_fi = reflect.FuncInfo{
                        .hash = fi.hash,
                        .name = @typeName(new_fn_type),
                        .params = &new_params,
                        .return_type = new_return,
                        .container_type = fi.container_type,
                        .type = reflect.ShallowTypeInfo.from(new_fn_type),
                    };
                    return .{ .func = new_fi };
                },
            }
        }

        fn substituteTypeInType(comptime T: type, comptime template_type: type, comptime impl_type: type) type {
            if (T == template_type) return impl_type;
            if (@typeInfo(T) == .pointer) {
                const p = @typeInfo(T).pointer;
                const child = p.child;
                if (child == template_type) {
                    return if (p.is_const) *const impl_type else *impl_type;
                }
            }
            return T;
        }

        fn substituteFunctionType(comptime FnType: type, comptime template_type: type, comptime impl_type: type) type {
            const fn_info = @typeInfo(FnType).@"fn";
            var new_params: [fn_info.params.len]std.builtin.Type.Fn.Param = undefined;
            for (fn_info.params, 0..) |param, i| {
                const param_type = param.type.?;
                const new_param_type = substituteTypeInType(param_type, template_type, impl_type);
                new_params[i] = .{
                    .is_generic = param.is_generic,
                    .is_noalias = param.is_noalias,
                    .type = new_param_type,
                };
            }
            const new_return_type = if (fn_info.return_type) |rt| substituteTypeInType(rt, template_type, impl_type) else null;
            return @Type(.{ .@"fn" = .{
                .calling_convention = fn_info.calling_convention,
                .is_generic = fn_info.is_generic,
                .is_var_args = fn_info.is_var_args,
                .params = &new_params,
                .return_type = new_return_type,
            } });
        }

        /// Get the struct type representing the vtable for a given implementation.
        fn VTableType(comptime Implementation: type) type {
            if (Implementation == TemplateType) return TemplateType;
            const template_info = comptime reflect.getTypeInfo(Tpl);
            const impl_info = comptime reflect.getTypeInfo(Implementation);
            const func_names = template_info.getFuncNames();
            const tmpl_struct_fields = template_info.fields;

            return comptime blk: {
                const count = tmpl_struct_fields.len + func_names.len;
                var fields: [count]std.builtin.Type.StructField = undefined;

                // Populate using implementation function pointers
                populate_fields(0, tmpl_struct_fields, func_names, impl_info, &fields, false);

                break :blk @Type(.{ .@"struct" = .{
                    .layout = .auto,
                    .fields = &fields,
                    .decls = &.{},
                    .is_tuple = false,
                } });
            };
        }

        /// Build and return a vtable instance for the implementation. This both validates
        /// the implementation and provides typed function pointers grouped by template methods.
        pub fn vTable(comptime Implementation: type) blk: {
            validate(Implementation);
            break :blk VTableType(Implementation);
        } {
            return comptime blk: {
                const template_info = reflect.getTypeInfo(Tpl);
                const impl_info = reflect.getTypeInfo(Implementation);
                const func_names = template_info.getFuncNames();
                const tmpl_struct_fields = template_info.fields;

                var table: VTableType(Implementation) = undefined;
                for (tmpl_struct_fields) |fld| {
                    const func_info = impl_info.getFunc(fld.name) orelse continue;
                    @field(table, fld.name) = func_info.toPtr();
                }

                for (func_names) |name| {
                    const func_info = impl_info.getFunc(name) orelse continue;
                    @field(table, name) = func_info.toPtr();
                }

                break :blk table;
            };
        }

        /// Build a vtable that matches the original template's type (useful for externally
        /// defined vtable structs such as std.mem.Allocator.VTable).
        ///
        /// This casts the generated implementation vtable field-by-field into the template
        /// vtable type, assuming compatible function pointer layouts.
        pub fn vTableAsTemplate(comptime Implementation: type) TemplateType {
            const vt = vTable(Implementation);
            return castVTableToTemplate(Implementation, vt);
        }

        /// Cast an implementation vtable to the template's exact vtable struct type.
        fn castVTableToTemplate(comptime Implementation: type, vtable: VTableType(Implementation)) TemplateType {
            const tmpl_ti = reflect.TypeInfo.from(TemplateType);
            comptime if (tmpl_ti.category != .Struct) {
                @compileError("castVTableToTemplate requires a struct Template type");
            };

            var out: TemplateType = undefined;
            inline for (tmpl_ti.fields) |field| {
                const FieldType = field.type.type;
                const src_field = @field(vtable, field.name);
                const casted: FieldType = @ptrCast(src_field);
                @field(out, field.name) = casted;
            }

            return out;
        }
    };
}

// Top-level helper for Templates to populate struct fields from template info
fn populate_fields(comptime start: usize, tmpl_struct_fields: []const reflect.FieldInfo, func_names: []const []const u8, template_info: reflect.TypeInfo, fields: anytype, use_func_ptr: bool) void {
    var index = start;
    for (tmpl_struct_fields, 0..) |fld, i| {
        const func_info: ?reflect.FuncInfo = if (!use_func_ptr) template_info.getFunc(fld.name) orelse @compileError("Template method info not found for " ++ fld.name ++ " in " ++ reflect.getSimpleTypeName(template_info.type)) else null;
        const PtrType = if (!use_func_ptr) @TypeOf(func_info.?.toPtr()) else null;
        const FieldType = if (use_func_ptr) fld.type.type else PtrType;
        fields[index + i] = std.builtin.Type.StructField{
            .name = fld.name[0..fld.name.len :0],
            .type = FieldType,
            .default_value_ptr = null,
            .is_comptime = false,
            .alignment = @alignOf(FieldType),
        };
    }
    index += tmpl_struct_fields.len;
    for (func_names, 0..) |name, i| {
        const func_info = template_info.getFunc(name) orelse @compileError("Template method info not found for " ++ name ++ " in " ++ reflect.getSimpleTypeName(template_info.type));
        const PtrType = @TypeOf(func_info.toPtr());
        fields[index + i] = std.builtin.Type.StructField{
            .name = name[0..name.len :0],
            .type = PtrType,
            .default_value_ptr = null,
            .is_comptime = false,
            .alignment = @alignOf(PtrType),
        };
    }
}

/// Creates a combined interface from multiple template types.
pub fn Templates(comptime TemplateTypes: []const type) type {
    const CombinedTemplate = comptime blk: {
        var all_fields: []const std.builtin.Type.StructField = &.{};
        for (TemplateTypes) |Tpl| {
            const template_type = if (@hasDecl(Tpl, "TemplateType")) Tpl.TemplateType else Tpl;
            const template_info = reflect.getTypeInfo(template_type);
            const func_names = template_info.getFuncNames();
            const tmpl_struct_fields = template_info.fields;

            const count = tmpl_struct_fields.len + func_names.len;
            var fields: [count]std.builtin.Type.StructField = undefined;
            // Populate fields using the template's signatures
            populate_fields(0, tmpl_struct_fields, func_names, template_info, &fields, true);

            all_fields = all_fields ++ &fields;
        }

        break :blk @Type(.{ .@"struct" = .{
            .layout = .auto,
            .fields = all_fields,
            .decls = &.{},
            .is_tuple = false,
        } });
    };

    return Template(CombinedTemplate);
}

// ===== TESTS =====

test "Interface - missing required method fails compilation" {
    // Uncomment this test to see compile error as expected:
    // const Drawable = struct {
    //     pub fn draw(self: *@This()) void {
    //         _ = self;
    //     }
    // };

    // const BadShape = struct {
    //     pub fn someOtherMethod(self: *@This()) void {
    //         _ = self;
    //     }
    // };

    // // This should not compile - missing 'draw' method
    // const DrawableImpl = Template(Drawable);

    // DrawableImpl.validate(BadShape);
}

test "Interface - reusable validator" {
    const Logger = struct {
        pub fn log(_: *@This()) void {
            unreachable;
        }
    };

    const SimpleLogger = struct {
        pub fn log(self: *@This()) void {
            _ = self;
        }
    };

    const DetailedLogger = struct {
        pub fn log(self: *@This()) void {
            _ = self;
        }
    };

    const LoggerTemplate = Template(Logger);
    LoggerTemplate.validate(SimpleLogger);
    LoggerTemplate.validate(DetailedLogger);
}

test "Interface.vTable builds vtable" {
    const Drawable = struct {
        pub fn draw(_: *@This()) void {
            unreachable;
        }
    };

    const Sprite = struct {
        called: bool = false,

        pub fn draw(self: *@This()) void {
            self.called = true;
        }
    };

    const DrawableTemplate = Template(Drawable);
    const vt = DrawableTemplate.vTable(Sprite);

    var sprite = Sprite{};
    vt.draw(&sprite);

    try std.testing.expect(sprite.called);
}

test "Interface.create initializes ptr field" {
    const Drawable = struct {
        pub fn draw(_: *@This()) void {
            unreachable;
        }
    };

    const Sprite = struct {
        x: f32 = 10.0,
        y: f32 = 20.0,

        pub fn draw(self: *@This()) void {
            _ = self;
        }
    };

    const DrawableTemplate = Template(Drawable);
    var spr = Sprite{};
    const drawable_interface = DrawableTemplate.vTable(Sprite);

    drawable_interface.draw(&spr);
}

test "Interfaces composition" {
    const Drawable = struct {
        pub fn draw(_: *@This()) void {
            unreachable;
        }
    };

    const Updatable = struct {
        pub fn update(_: *@This(), _: f32) void {
            unreachable;
        }
    };

    const Destroyable = struct {
        pub fn destroy(_: *@This()) void {
            unreachable;
        }
    };

    const GameObject = struct {
        drawn: bool = false,
        updated: bool = false,

        pub fn draw(self: *@This()) void {
            self.drawn = true;
        }

        pub fn update(self: *@This(), delta: f32) void {
            _ = delta;
            self.updated = true;
        }

        pub fn destroy(self: *@This()) void {
            _ = self;
        }
    };

    const GameObjectImpl = Templates(&[_]type{ Template(Drawable), Template(Updatable), Template(Destroyable) });

    const vt = GameObjectImpl.vTable(GameObject);

    var obj = GameObject{};
    vt.draw(&obj);
    vt.update(&obj, 0.16);
    vt.destroy(&obj);
    try std.testing.expect(obj.updated);
}

test "Interfaces.TemplateVTable" {
    const A = struct {
        pub fn a(_: *@This()) void {
            unreachable;
        }
    };
    const B = struct {
        pub fn b(_: *@This(), _: u32) void {
            unreachable;
        }
    };

    const Impl = struct {
        value: u32 = 0,
        pub fn a(self: *@This()) void {
            _ = self;
        }

        pub fn b(self: *@This(), v: u32) void {
            self.value += v;
        }
    };
    _ = Impl;

    const Comp = Templates(&[_]type{ Template(A), Template(B) });
    const vt = Comp.TemplateType;
    try std.testing.expectEqual(2, @typeInfo(vt).@"struct".fields.len);
    const type_info = comptime reflect.getTypeInfo(Comp.TemplateType);
    std.debug.print("TemplateVTable Type:\n", .{});
    std.debug.print("{s}\n", .{type_info.toStringEx(true)});
    inline for (type_info.fields) |field| {
        std.debug.print("Field: {s}, Type: {s}\n", .{ field.name, field.type.name });
    }
}

test "Interface.extend hierarchical composition" {
    const Drawable = struct {
        pub fn draw(_: *@This()) void {
            unreachable;
        }
    };

    const Updatable = struct {
        pub fn update(_: *@This(), _: f32) void {
            unreachable;
        }
    };

    const Destroyable = struct {
        pub fn destroy(_: *@This()) void {
            unreachable;
        }
    };

    const GameObject = struct {
        drawn: bool = false,
        updated: bool = false,
        destroyed: bool = false,

        pub fn draw(self: *@This()) void {
            self.drawn = true;
        }

        pub fn update(self: *@This(), delta: f32) void {
            _ = delta;
            self.updated = true;
        }

        pub fn destroy(self: *@This()) void {
            self.destroyed = true;
        }
    };

    // Extend Drawable with Updatable
    const DrawableUpdatableTypes = &[_]type{ Template(Drawable), Template(Updatable) };
    const DrawableUpdatable = Templates(DrawableUpdatableTypes);
    const vt = DrawableUpdatable.vTable(GameObject);

    var obj = GameObject{};
    vt.draw(&obj);
    vt.update(&obj, 0.16);

    try std.testing.expect(obj.drawn);
    try std.testing.expect(obj.updated);

    // Further extend with Destroyable - this creates Interfaces with 3 types
    const FullGameObject = Templates(DrawableUpdatableTypes ++ &[_]type{Template(Destroyable)});

    // Validate works
    FullGameObject.validate(GameObject);

    // T-O-D-O: (OLD and fixed!) vTable construction hits eval branch quota with 3+ interfaces
    const vt2 = FullGameObject.vTable(GameObject);
    var obj2 = GameObject{};
    vt2.draw(&obj2);
    vt2.update(&obj2, 0.16);
    vt2.destroy(&obj2);
    try std.testing.expect(obj2.drawn);
    try std.testing.expect(obj2.updated);
    try std.testing.expect(obj2.destroyed);
}

test "Const-correct interfaces" {
    const Reader = struct {
        pub fn read(_: *const @This()) u32 {
            unreachable;
        }
    };

    const Buffer = struct {
        value: u32 = 42,

        pub fn read(self: *const @This()) u32 {
            return self.value;
        }

        pub fn write(self: *@This(), val: u32) void {
            self.value = val;
        }
    };

    const ReaderTemplate = Template(Reader);

    const vt = ReaderTemplate.vTable(Buffer);
    var buf = Buffer{ .value = 123 };
    const result = vt.read(&buf);

    const Writer = struct {
        pub fn write(_: *@This(), _: u32) void {
            unreachable;
        }
    };

    const ReaderWriter = Templates(&[_]type{ Template(Reader), Template(Writer) }); // or use Interfaces(&[_]type{Template(Reader), Template(Writer)})
    const rw_vt = ReaderWriter.vTable(Buffer);
    rw_vt.write(&buf, 456);
    const new_result = rw_vt.read(&buf);
    std.debug.print("Read value: {d}, New value: {d}\n", .{ result, new_result });
    try std.testing.expectEqual(@as(u32, 123), result);
    try std.testing.expectEqual(@as(u32, 456), new_result);
}

test "Const-correct interfaces - mutable implementation allowed for const template" {
    const Reader = struct {
        pub fn read(self: *const @This()) u32 {
            _ = self;
            return 42;
        }
    };

    const MutableBuffer = struct {
        value: u32 = 42,
        read_count: u32 = 0,

        // More restrictive (mutable) implementation is acceptable
        pub fn read(self: *@This()) u32 {
            self.read_count += 1;
            return self.value;
        }
    };

    const ReaderTemplate = Template(Reader);
    ReaderTemplate.validate(MutableBuffer);

    const vt = ReaderTemplate.vTable(MutableBuffer);
    var buf = MutableBuffer{ .value = 456 };
    const result = vt.read(&buf);

    try std.testing.expectEqual(@as(u32, 456), result);
    try std.testing.expectEqual(@as(u32, 1), buf.read_count);
}

test "Template - function pointer parameter substitution" {
    const CallbackHolder = struct {
        pub fn setCallback(_: *@This(), _: fn (*@This()) void) void {
            unreachable;
        }
    };

    const MyHolder = struct {
        pub fn setCallback(self: *@This(), cb: fn (*@This()) void) void {
            _ = self;
            _ = cb;
        }
    };

    const CallbackHolderTemplate = Template(CallbackHolder);
    CallbackHolderTemplate.validate(MyHolder);
}

test "Template - function pointer parameter substitution with self pointer" {
    const Processor = struct {
        pub fn process(self: *@This(), cb: fn (*std.mem.Allocator, u32) u32) u32 {
            return cb(self, 0);
        }
    };

    const MyProcessor = struct {
        pub fn process(self: *@This(), cb: fn (*std.mem.Allocator, u32) u32) u32 {
            return cb(self, 0);
        }
    };

    const ProcessorTemplate = Template(Processor);
    ProcessorTemplate.validate(MyProcessor);
}

test "Template - Allocator vtable" {
    const MyAllocator = struct {
        base_allocator: std.mem.Allocator,

        const vtable = Template(std.mem.Allocator.VTable).vTableAsTemplate(@This());

        pub fn init(allc: std.mem.Allocator) @This() {
            return .{ .base_allocator = allc };
        }
        pub fn alloc(self: *@This(), len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
            _ = alignment; // base allocator handles default alignment for u8
            _ = ret_addr;
            const buf = self.base_allocator.alloc(u8, len) catch return null;
            return buf.ptr;
        }

        pub fn free(self: *@This(), buf: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
            _ = alignment;
            _ = ret_addr;
            self.base_allocator.free(buf);
        }

        pub fn resize(self: *@This(), buf: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
            _ = alignment;
            _ = ret_addr;
            return self.base_allocator.resize(buf, new_len);
        }

        pub fn remap(self: *@This(), buf: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
            _ = alignment;
            _ = ret_addr;
            const res = self.base_allocator.remap(buf, new_len) orelse return null;
            return res.ptr;
        }

        pub fn allocator(self: *@This()) std.mem.Allocator {
            return .{
                .ptr = self,
                .vtable = &vtable,
            };
        }
    };

    var myAllocator = MyAllocator.init(std.testing.allocator);
    const allocator = myAllocator.allocator();
    // Verify we produced a valid vtable pointer matching the template type.
    try std.testing.expect(@intFromPtr(allocator.vtable) != 0);
    const buf = try allocator.alloc(u8, 128);
    defer allocator.free(buf);
    try std.testing.expect(buf.len == 128);
}

test "Template - vTableAsTemplate" {
    const VTable = struct {
        doThing: *const fn (self: *anyopaque, value: u32) u32,
    };

    const Impl = struct {
        pub fn doThing(_: *@This(), value: u32) u32 {
            return value * 2;
        }
    };

    var inst = Impl{};
    var vt = Template(VTable).vTableAsTemplate(Impl);

    const result = vt.doThing(&inst, 21);
    try std.testing.expectEqual(@as(u32, 42), result);
}

test "Template - create" {
    const PluginTemplate = struct {
        pub fn name() []const u8 {
            unreachable;
        }
        pub fn initialize(_: *@This()) void {
            unreachable;
        }
        pub fn isInitialized(_: *const @This()) bool {
            unreachable;
        }
    };

    const MyPlugin = struct {
        initialized: bool = false,
        pub fn name() []const u8 {
            return "MyPlugin";
        }
        pub fn initialize(self: *@This()) void {
            self.initialized = true;
        }

        pub fn isInitialized(self: *const @This()) bool {
            return self.initialized;
        }
    };
    var myPlugin = MyPlugin{};
    var interface = Template(PluginTemplate).interfaceFromPtr(MyPlugin, &myPlugin);
    const plugin_name = interface.vtable.name();
    try std.testing.expectEqualStrings("MyPlugin", plugin_name);
    interface.vtable.initialize(interface.ptr);
    try std.testing.expectEqual(true, interface.vtable.isInitialized(interface.ptr));

    const impl = std.testing.allocator.create(MyPlugin) catch unreachable;
    defer std.testing.allocator.destroy(impl);
    const another_interface = Template(PluginTemplate).interfaceFromPtr(MyPlugin, impl);
    const another_plugin_name = another_interface.vtable.name();
    try std.testing.expectEqualStrings("MyPlugin", another_plugin_name);
    another_interface.vtable.initialize(another_interface.ptr);
    try std.testing.expectEqual(true, another_interface.vtable.isInitialized(another_interface.ptr));
}

test "Template.populate populates Interface fields" {
    // hopefully will fix zevy_ecs plugin issues...

    const PluginTemplateType = struct {
        pub const Name: []const u8 = "My Amazing Plugin";
        pub fn name() []const u8 {
            unreachable;
        }
        pub fn initialize(_: *@This()) void {
            unreachable;
        }
        pub fn isInitialized(_: *const @This()) bool {
            unreachable;
        }
    };

    const PluginTemplate = Template(PluginTemplateType);

    const MyPlugin = struct {
        initialized: bool = false,
        pub fn name() []const u8 {
            return "MyPlugin";
        }
        pub fn initialize(self: *@This()) void {
            self.initialized = true;
        }
        pub fn isInitialized(self: *const @This()) bool {
            return self.initialized;
        }
    };

    var impl = MyPlugin{};
    const Plugin = Template(PluginTemplate).Interface;
    var raw_iface: Plugin = undefined;
    PluginTemplate.populate(&raw_iface, &impl);
    try std.testing.expectEqualStrings("MyPlugin", raw_iface.vtable.name());
    try std.testing.expectEqual(false, raw_iface.vtable.isInitialized(raw_iface.ptr));
    raw_iface.vtable.initialize(raw_iface.ptr);
    try std.testing.expectEqual(true, raw_iface.vtable.isInitialized(raw_iface.ptr));
}
