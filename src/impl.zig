const std = @import("std");
const reflect = @import("reflect.zig");

/// Creates an interface validator from a template type.
/// Returns a type that can validate and constrain implementations.
///
/// Example:
/// ```zig
/// // Define your interfaces like you would in most programming languages
/// pub const Drawable = struct {
///     pub fn draw(self: *@This()) void {};
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

                    if (impl_func_info == null) {
                        missing_methods = missing_methods ++ &[_][]const u8{tmpl_func_info.toString()};
                    } else {
                        // Check if parameters match (handling self parameters)
                        var param_match = true;

                        if (tmpl_func_info.params.len != impl_func_info.?.params.len) {
                            param_match = false;
                        } else {
                            for (tmpl_func_info.params, 0..) |tmpl_param, i| {
                                const impl_param = impl_func_info.?.params[i];

                                // Check if template param references the template type (self parameter)
                                var is_tmpl_self = false;
                                switch (tmpl_param.info) {
                                    .type => |ti| {
                                        const tmpl_type = ti.type;
                                        if (tmpl_type == Template) {
                                            is_tmpl_self = true;
                                        } else if (@typeInfo(tmpl_type) == .pointer) {
                                            const child = @typeInfo(tmpl_type).pointer.child;
                                            if (child == Template) {
                                                is_tmpl_self = true;
                                            }
                                        }
                                    },
                                    else => {},
                                }

                                // Check if impl param references the impl type (self parameter)
                                var is_impl_self = false;
                                switch (impl_param.info) {
                                    .type => |ti| {
                                        const impl_type = ti.type;
                                        if (impl_type == Implementation) {
                                            is_impl_self = true;
                                        } else if (@typeInfo(impl_type) == .pointer) {
                                            const child = @typeInfo(impl_type).pointer.child;
                                            if (child == Implementation) {
                                                is_impl_self = true;
                                            }
                                        }
                                    },
                                    else => {},
                                }

                                // Both are self parameters - they match
                                if (is_tmpl_self and is_impl_self) {
                                    continue;
                                }

                                // If only one is self, mismatch
                                if (is_tmpl_self != is_impl_self) {
                                    param_match = false;
                                    break;
                                }

                                // Otherwise check if they're equal
                                if (!impl_param.eql(&tmpl_param)) {
                                    param_match = false;
                                    break;
                                }
                            }
                        }

                        if (!param_match) {
                            missing_methods = missing_methods ++ &[_][]const u8{tmpl_func_info.toString()};
                        }
                    }
                }

                if (missing_methods.len > 0) {
                    var error_msg: []const u8 = "Implementation " ++ reflect.getSimpleTypeName(Implementation) ++ " does not satisfy interface " ++ reflect.getSimpleTypeName(Template) ++ ". Missing methods:\n";
                    for (missing_methods) |method| {
                        error_msg = error_msg ++ "  - " ++ method ++ "\n";
                    }
                    @compileError(error_msg);
                }
            }
        }

        /// Get the struct type representing the vtable for a given implementation.
        /// The fields correspond to the template's method names and hold typed function pointers.
        fn VTableType(comptime Implementation: type) type {
            const template_info = comptime reflect.getTypeInfo(TemplateType);
            const impl_info = comptime reflect.getTypeInfo(Implementation);
            const func_names = template_info.getFuncNames();

            return comptime blk: {
                var fields: [func_names.len]std.builtin.Type.StructField = undefined;

                for (func_names, 0..) |name, i| {
                    const func_info = impl_info.getFunc(name).?;
                    const PtrType = @TypeOf(func_info.toPtr());

                    fields[i] = std.builtin.Type.StructField{
                        .name = name[0..name.len :0],
                        .type = PtrType,
                        .default_value_ptr = null,
                        .is_comptime = false,
                        .alignment = @alignOf(PtrType),
                    };
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

                var table: VTableType(Implementation) = undefined;
                for (func_names) |name| {
                    const func_info = impl_info.getFunc(name).?;
                    @field(table, name) = func_info.toPtr();
                }

                break :blk table;
            };
        }
    };
}

pub fn Interfaces(comptime InterfaceTypes: []const type) type {
    return struct {
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
    };
}

// ===== TESTS =====

test "Interface - basic validation" {
    const Drawable = struct {
        pub fn draw(self: *@This()) void {
            _ = self;
        }
    };

    const MyCircle = struct {
        radius: f32,
        pub fn draw(self: *@This()) void {
            _ = self;
        }
    };

    const DrawableImpl = Interface(Drawable);
    DrawableImpl.validate(MyCircle);
}

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
        pub fn log(self: *@This()) void {
            _ = self;
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
        pub fn draw(self: *@This()) void {
            _ = self;
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

test "Interfaces" {
    const Drawable = struct {
        pub fn draw(self: *@This()) void {
            _ = self;
        }
    };

    const Updatable = struct {
        pub fn update(self: *@This(), delta: f32) void {
            _ = self;
            _ = delta;
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
    };

    const GameObjectImpl = Interfaces(&[_]type{ Drawable, Updatable });

    const vt = GameObjectImpl.vTable(GameObject);

    var obj = GameObject{};
    vt.draw(&obj);
    vt.update(&obj, 0.16);
    try std.testing.expect(obj.updated);
}
