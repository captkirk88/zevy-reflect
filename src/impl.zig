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
/// pub fn drawAll(comptime DrawType: Implements(Drawable), drawable: anytype) void {
///     DrawType.satisfies(drawable); // if not satisfied then compile error will be shown
/// }
/// ```
///
/// This continues the explicitness of Zig which should be a code guideline all follow in most cases.
pub fn Implements(comptime Template: type) type {
    return struct {
        const Template_ = Template;

        /// Validates that a type satisfies this interface.
        pub fn satisfies(value: anytype) void {
            const Implementation = @TypeOf(value);

            // TODO TypeInfo needs a utility method isPointer(), isOptional(), etc.
            switch (@typeInfo(Implementation)) {
                .pointer => {
                    satisfies(value.*);
                    return;
                },
                .optional => {
                    if (value != null) satisfies(value.?);
                    return;
                },
                else => {},
            }

            comptime {
                const template_info = reflect.getTypeInfo(Template_);
                const impl_info = reflect.getTypeInfo(Implementation);
                const func_names = template_info.getFuncNames();

                var missing_methods: []const []const u8 = &.{};

                for (func_names) |method_name| {
                    var tmpl_func_info = template_info.getFunc(method_name).?;

                    // Check if first param is a self reference and replace it with Implementation type
                    if (tmpl_func_info.params.len > 0) {
                        const first_param = tmpl_func_info.params[0];
                        var is_self = false;

                        if (first_param == .type) {
                            const param_type = first_param.type.type;
                            if (param_type == Template_) {
                                is_self = true;
                            } else if (@typeInfo(param_type) == .pointer) {
                                const child = @typeInfo(param_type).pointer.child;
                                if (child == Template_) {
                                    is_self = true;
                                }
                            }
                        }

                        if (is_self) {
                            // Build new params array with first param replaced
                            var new_params: [tmpl_func_info.params.len]reflect.ReflectInfo = undefined;
                            new_params[0] = .{ .type = impl_info };
                            for (tmpl_func_info.params[1..], 1..) |param, i| {
                                new_params[i] = param;
                            }

                            // Create new FuncInfo with modified params
                            tmpl_func_info = .{
                                .hash = tmpl_func_info.hash,
                                .name = tmpl_func_info.name,
                                .params = &new_params,
                                .return_type = tmpl_func_info.return_type,
                            };
                        }
                    }

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
                                if (tmpl_param == .type) {
                                    const tmpl_type = tmpl_param.type.type;
                                    if (tmpl_type == Template_) {
                                        is_tmpl_self = true;
                                    } else if (@typeInfo(tmpl_type) == .pointer) {
                                        const child = @typeInfo(tmpl_type).pointer.child;
                                        if (child == Template_) {
                                            is_tmpl_self = true;
                                        }
                                    }
                                }

                                // Check if impl param references the impl type (self parameter)
                                var is_impl_self = false;
                                if (impl_param == .type) {
                                    const impl_type = impl_param.type.type;
                                    if (impl_type == Implementation) {
                                        is_impl_self = true;
                                    } else if (@typeInfo(impl_type) == .pointer) {
                                        const child = @typeInfo(impl_type).pointer.child;
                                        if (child == Implementation) {
                                            is_impl_self = true;
                                        }
                                    }
                                }

                                // Both are self parameters - they match
                                if (is_tmpl_self and is_impl_self) {
                                    continue;
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
                    var error_msg: []const u8 = "Implementation " ++ reflect.getSimpleTypeName(Implementation) ++ " does not satisfy interface " ++ reflect.getSimpleTypeName(Template_) ++ ". Missing methods:\n";
                    for (missing_methods) |method| {
                        error_msg = error_msg ++ "  - " ++ method ++ "\n";
                    }
                    @compileError(error_msg);
                }
            }
        }
    };
}

// ===== TESTS =====

test "Implements - basic validation" {
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

    const DrawableImpl = Implements(Drawable);
    const circle = MyCircle{ .radius = 32 };
    DrawableImpl.satisfies(circle);
}

test "Implements - missing required method fails compilation" {
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
    // const DrawableImpl = Implements(Drawable);

    // const badShape = BadShape{};
    // DrawableImpl.check(badShape);
}

test "Implements - reusable validator" {
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

    const LoggerImpl = Implements(Logger);
    var Simple = SimpleLogger{};
    var Detailed = DetailedLogger{};
    LoggerImpl.satisfies(&Simple);
    LoggerImpl.satisfies(&Detailed);
}
