const std = @import("std");
const reflect = @import("reflect.zig");

/// Creates an interface validator from a template type.
/// Returns a type that can validate and constrain implementations.
///
/// Example:
/// ```zig
/// // Define your interfaces like you would in most programming languages
/// pub const Drawable = struct {
///     ptr: *anyopaque,
///     pub fn draw(self: *@This()) void {
///         self.ptr.draw();
///     }
/// };
///
/// pub const MyCircle = struct {
///     radius: f32,
///     pub fn draw(self: *@This()) void { ... }
/// };
///
/// pub fn drawAll(drawable: anytype) void {
///     Interface(Drawable).validate(drawable); // if not satisfied then compile error will be shown
/// }
/// ```
///
/// This continues the explicitness of Zig which should be a code guideline all follow in most cases.
pub fn Interface(comptime Template: type) type {
    return struct {
        pub const TemplateType = Template;

        /// Validates that a type satisfies this interface.
        pub fn validate(value: type) void {
            validateThis(value, false);
        }

        /// Validates that a type satisfies this interface with verbose error messages.
        pub fn validateVerbose(value: type) void {
            validateThis(value, true);
        }

        fn validateThis(value: type, comptime verbose: bool) void {
            const Implementation = value;

            // switch (@typeInfo(Implementation)) {
            //     .pointer => {
            //         validate(value.*);
            //         return;
            //     },
            //     .optional => {
            //         if (value != null) validate(value.?);
            //         return;
            //     },
            //     else => {},
            // }

            comptime {
                const template_info = reflect.TypeInfo.from(TemplateType);
                const impl_info = reflect.TypeInfo.from(Implementation);
                const func_names = template_info.getFuncNames();

                var missing_methods: []const []const u8 = &.{};

                for (func_names) |method_name| {
                    const tmpl_func_info = template_info.getFunc(method_name).?;
                    const impl_func_info = impl_info.getFunc(method_name);

                    var func_params: [tmpl_func_info.params.len]reflect.ParamInfo = undefined;
                    for (0..tmpl_func_info.params.len) |j| {
                        func_params[j] = tmpl_func_info.params[j];
                        switch (func_params[j].info) {
                            .type => |ti| {
                                // If the param is exactly the template type, replace with Implementation
                                if (ti.type == Template) {
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
                                        if (child == Template) {
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
                                    .info = substituteType(.{ .func = fi }, Template, Implementation),
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
                                            .info = substituteType(tmpl_param.info, Template, Implementation),
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
                                        if (tmpl_type == Template) {
                                            is_tmpl_self = true;
                                        } else if (@typeInfo(tmpl_type) == .pointer) {
                                            const ptr_info = @typeInfo(tmpl_type).pointer;
                                            const child = ptr_info.child;
                                            if (child == Template) {
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
                    var error_msg: []const u8 = "Implementation " ++ if (verbose == false) reflect.getSimpleTypeName(Implementation) else @typeName(Implementation) ++ " ";
                    error_msg = error_msg ++ "does not satisfy interface " ++ if (verbose == false) reflect.getSimpleTypeName(Template) else @typeName(Template) ++ ". ";

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
        /// The fields correspond to the template's method names and hold typed function pointers.
        fn VTableType(comptime Implementation: type) type {
            const template_info = comptime reflect.getTypeInfo(TemplateType);
            const impl_info = comptime reflect.getTypeInfo(Implementation);
            const func_names = template_info.getFuncNames();
            const tmpl_struct_fields = template_info.fields;
            const use_fields = func_names.len == 0;

            return comptime blk: {
                const count = if (use_fields) tmpl_struct_fields.len else func_names.len;
                var fields: [count]std.builtin.Type.StructField = undefined;

                if (use_fields) {
                    for (tmpl_struct_fields, 0..) |fld, i| {
                        const func_info = impl_info.getFunc(fld.name) orelse @compileError(reflect.getSimpleTypeName(Implementation) ++ " is missing method '" ++ fld.name ++ "' required by interface " ++ reflect.getSimpleTypeName(TemplateType));
                        const PtrType = @TypeOf(func_info.toPtr());
                        fields[i] = std.builtin.Type.StructField{
                            .name = fld.name[0..fld.name.len :0],
                            .type = PtrType,
                            .default_value_ptr = null,
                            .is_comptime = false,
                            .alignment = @alignOf(PtrType),
                        };
                    }
                } else {
                    for (func_names, 0..) |name, i| {
                        const func_info = impl_info.getFunc(name) orelse @compileError(reflect.getSimpleTypeName(Implementation) ++ " is missing method '" ++ name ++ "' required by interface " ++ reflect.getSimpleTypeName(TemplateType));
                        const PtrType = @TypeOf(func_info.toPtr());

                        fields[i] = std.builtin.Type.StructField{
                            .name = name[0..name.len :0],
                            .type = PtrType,
                            .default_value_ptr = null,
                            .is_comptime = false,
                            .alignment = @alignOf(PtrType),
                        };
                    }
                }

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
        pub fn vTable(comptime Implementation: type) VTableType(Implementation) {
            return comptime blk: {
                // Reuse validation to ensure the implementation matches the template contract.
                validate(Implementation);

                const template_info = reflect.getTypeInfo(TemplateType);
                const impl_info = reflect.getTypeInfo(Implementation);
                const func_names = template_info.getFuncNames();
                const tmpl_struct_fields = @typeInfo(TemplateType).@"struct".fields;
                const use_fields = func_names.len == 0;

                var table: VTableType(Implementation) = undefined;
                if (use_fields) {
                    for (tmpl_struct_fields) |fld| {
                        const func_info = impl_info.getFunc(fld.name) orelse continue;
                        @field(table, fld.name) = func_info.toPtr();
                    }
                } else {
                    for (func_names) |name| {
                        const func_info = impl_info.getFunc(name) orelse continue;
                        @field(table, name) = func_info.toPtr();
                    }
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
        pub fn castVTableToTemplate(comptime Implementation: type, vtable: VTableType(Implementation)) TemplateType {
            const tmpl_ti = reflect.TypeInfo.from(TemplateType);
            comptime if (tmpl_ti.category != .Struct) {
                @compileError("castVTableToTemplate requires a struct Template type (vtable)");
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

pub fn Interfaces(comptime InterfaceTypes: []const type) type {
    return struct {
        pub const types: []const type = InterfaceTypes;

        /// Validates that a type satisfies all interfaces in this composition.
        pub fn validate(value: type) void {
            comptime {
                for (InterfaceTypes) |InterfaceType| {
                    Interface(InterfaceType).validate(value);
                }
            }
        }

        fn CombinedVTableType(comptime Implementation: type) type {
            return comptime blk: {
                validate(Implementation);
                var all_fields: []const std.builtin.Type.StructField = &.{};
                for (InterfaceTypes) |Intf| {
                    const VT = Interface(Intf).VTableType(Implementation);
                    const vt_info = @typeInfo(VT);
                    all_fields = all_fields ++ vt_info.@"struct".fields;
                }
                break :blk @Type(.{ .@"struct" = .{
                    .layout = .auto,
                    .fields = all_fields,
                    .decls = &.{},
                    .is_tuple = false,
                } });
            };
        }

        /// Build and return a combined vtable instance for the implementation.
        /// Note: For large numbers of interfaces (3+), this may hit eval branch quota limits
        /// during vtable construction due to repeated validation and introspection.
        pub fn vTable(comptime Implementation: type) CombinedVTableType(Implementation) {
            return comptime blk: {
                validate(Implementation);
                var table: CombinedVTableType(Implementation) = undefined;
                for (InterfaceTypes) |Intf| {
                    const vt = Interface(Intf).vTable(Implementation);
                    const vt_info = @typeInfo(@TypeOf(vt));
                    for (vt_info.@"struct".fields) |field| {
                        @field(table, field.name) = @field(vt, field.name);
                    }
                }
                break :blk table;
            };
        }

        pub fn vTableAsTemplate(comptime Implementation: type) InterfaceTypes[0] {
            const vt = vTable(Implementation);
            return castVTableToTemplate(Implementation, vt);
        }

        pub fn castVTableToTemplate(comptime Implementation: type, vtable: CombinedVTableType(Implementation)) type {
            const first_intf = InterfaceTypes[0];
            const tmpl_ti = reflect.TypeInfo.from(first_intf);
            comptime if (tmpl_ti.category != .Struct) {
                @compileError("castVTableToTemplate requires a struct Template type (vtable)");
            };

            var out: first_intf = undefined;
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
    // const DrawableImpl = Interface(Drawable);

    // const badShape = BadShape{};
    // DrawableImpl.validate(badShape);
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

    const LoggerImpl = Interface(Logger);
    LoggerImpl.validate(SimpleLogger);
    LoggerImpl.validate(DetailedLogger);
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

    const DrawableImpl = Interface(Drawable);
    const vt = DrawableImpl.vTable(Sprite);

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

    const DrawableImpl = Interface(Drawable);
    var spr = Sprite{};
    const drawable_interface = DrawableImpl.vTable(Sprite);

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

    const GameObjectImpl = Interfaces(&[_]type{ Drawable, Updatable, Destroyable });

    const vt = GameObjectImpl.vTable(GameObject);

    var obj = GameObject{};
    vt.draw(&obj);
    vt.update(&obj, 0.16);
    vt.destroy(&obj);
    try std.testing.expect(obj.updated);
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
    const DrawableUpdatable = Interfaces(&[_]type{ Drawable, Updatable });
    const vt = DrawableUpdatable.vTable(GameObject);

    var obj = GameObject{};
    vt.draw(&obj);
    vt.update(&obj, 0.16);

    try std.testing.expect(obj.drawn);
    try std.testing.expect(obj.updated);

    // Further extend with Destroyable - this creates Interfaces with 3 types
    const FullGameObject = Interfaces(DrawableUpdatable.types ++ &[_]type{Destroyable});

    // Validate works
    FullGameObject.validate(GameObject);

    // TODO: vTable construction hits eval branch quota with 3+ interfaces
    // const vt2 = FullGameObject.vTable(GameObject);
    // var obj2 = GameObject{};
    // vt2.draw(&obj2);
    // vt2.update(&obj2, 0.16);
    // vt2.destroy(&obj2);
    // try std.testing.expect(obj2.drawn);
    // try std.testing.expect(obj2.updated);
    // try std.testing.expect(obj2.destroyed);
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

    const ReaderImpl = Interface(Reader);

    const vt = ReaderImpl.vTable(Buffer);
    var buf = Buffer{ .value = 123 };
    const result = vt.read(&buf);

    const Writer = struct {
        pub fn write(_: *@This(), _: u32) void {
            unreachable;
        }
    };

    const ReaderWriter = Interfaces(&[_]type{ Reader, Writer }); // or use Interfaces(&[_]type{Reader, Writer})
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

    const ReaderImpl = Interface(Reader);
    ReaderImpl.validate(MutableBuffer);

    const vt = ReaderImpl.vTable(MutableBuffer);
    var buf = MutableBuffer{ .value = 456 };
    const result = vt.read(&buf);

    try std.testing.expectEqual(@as(u32, 456), result);
    try std.testing.expectEqual(@as(u32, 1), buf.read_count);
}

test "Interface - function pointer parameter substitution" {
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

    const CallbackHolderImpl = Interface(CallbackHolder);
    CallbackHolderImpl.validate(MyHolder);
}

test "Interface - function pointer parameter substitution with self pointer" {
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

    const ProcessorImpl = Interface(Processor);
    ProcessorImpl.validate(MyProcessor);
}

test "Interface - Allocator vtable" {
    const MyAllocator = struct {
        base_allocator: std.mem.Allocator,

        const vtable = Interface(std.mem.Allocator.VTable).vTableAsTemplate(@This());

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

test "Interface - vTableAsTemplate" {
    const VTable = struct {
        doThing: *const fn (self: *anyopaque, value: u32) u32,
    };

    const Impl = struct {
        pub fn doThing(_: *@This(), value: u32) u32 {
            return value * 2;
        }
    };

    const TraitImpl = Interface(VTable);
    var inst = Impl{};
    var vt = TraitImpl.vTableAsTemplate(Impl);

    const result = vt.doThing(&inst, 21);
    try std.testing.expectEqual(@as(u32, 42), result);
}
