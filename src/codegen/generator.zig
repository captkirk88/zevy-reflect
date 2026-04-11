const std = @import("std");
const reflect = @import("../reflect.zig");

pub fn Generator(comptime InputType: type, comptime ConfigType: type) type {
    validateConfigType(ConfigType);

    return struct {
        pub const Input = InputType;
        pub const Config = ConfigType;

        fn ReturnType(comptime Implementation: type) type {
            const generate_type = @TypeOf(Implementation.generate);
            const fn_info = @typeInfo(generate_type).@"fn";
            return fn_info.return_type orelse
                @compileError("Generator generate must have a concrete return type");
        }

        pub fn validate(comptime Implementation: type) void {
            if (!@hasDecl(Implementation, "generate")) {
                @compileError(std.fmt.comptimePrint(
                    "Generator implementation {s} must declare pub fn generate(input: {s}, config: {s}) <struct>",
                    .{ @typeName(Implementation), @typeName(InputType), @typeName(ConfigType) },
                ));
            }

            const generate_type = @TypeOf(Implementation.generate);
            const generate_info = @typeInfo(generate_type);
            if (generate_info != .@"fn") {
                @compileError("Generator implementation generate must be a function");
            }

            const fn_info = generate_info.@"fn";
            if (fn_info.params.len != 2) {
                @compileError(std.fmt.comptimePrint(
                    "Generator implementation {s}.generate must accept exactly two parameters",
                    .{@typeName(Implementation)},
                ));
            }

            const input_param = fn_info.params[0].type orelse
                @compileError("Generator generate input parameter must have a concrete type");
            const config_param = fn_info.params[1].type orelse
                @compileError("Generator generate config parameter must have a concrete type");
            const return_type = ReturnType(Implementation);

            if (input_param != InputType) {
                @compileError(std.fmt.comptimePrint(
                    "Generator implementation {s}.generate expected first parameter {s}, found {s}",
                    .{ @typeName(Implementation), @typeName(InputType), @typeName(input_param) },
                ));
            }

            if (config_param != ConfigType) {
                @compileError(std.fmt.comptimePrint(
                    "Generator implementation {s}.generate expected second parameter {s}, found {s}",
                    .{ @typeName(Implementation), @typeName(ConfigType), @typeName(config_param) },
                ));
            }

            if (@typeInfo(return_type) != .@"struct") {
                @compileError(std.fmt.comptimePrint(
                    "Generator implementation {s}.generate must return a struct, found {s}",
                    .{ @typeName(Implementation), @typeName(return_type) },
                ));
            }
        }

        pub fn wrap(comptime Implementation: type) type {
            validate(Implementation);

            return struct {
                pub const Input = InputType;
                pub const Config = ConfigType;
                pub const Output = ReturnType(Implementation);

                pub fn generate(comptime input: InputType, comptime config: ConfigType) Output {
                    validateConfigType(ConfigType);

                    if (@hasDecl(Implementation, "validateInput")) {
                        Implementation.validateInput(input);
                    }
                    if (@hasDecl(Implementation, "validateConfig")) {
                        Implementation.validateConfig(config);
                    }

                    return Implementation.generate(input, config);
                }

                pub fn generateToFile(
                    io: std.Io,
                    comptime input: InputType,
                    comptime config: ConfigType,
                    output_path: []const u8,
                ) !void {
                    const generated = generate(input, config);
                    comptime {
                        if (!@hasField(Output, "source")) {
                            @compileError(std.fmt.comptimePrint(
                                "Generator output {s} must contain a 'source: []const u8' field to use generateToFile",
                                .{@typeName(Output)},
                            ));
                        }
                        if (@TypeOf(@field(@as(Output, undefined), "source")) != []const u8) {
                            @compileError(std.fmt.comptimePrint(
                                "Generator output {s}.source must be []const u8",
                                .{@typeName(Output)},
                            ));
                        }
                    }

                    const file = try std.Io.Dir.cwd().createFile(io, output_path, .{});
                    defer file.close(io);

                    try file.writeStreamingAll(io, generated.source);
                }
            };
        }
    };
}

pub fn validateConfigType(comptime ConfigType: type) void {
    switch (@typeInfo(ConfigType)) {
        .@"struct", .@"union", .@"enum" => {},
        else => @compileError(std.fmt.comptimePrint(
            "Generator config type must be a struct, union, or enum; found {s}",
            .{reflect.getSimpleTypeName(ConfigType)},
        )),
    }
}

test "Generator wraps a typed implementation" {
    const DemoInput = struct {
        subject: type,
    };

    const DemoConfig = struct {
        name: []const u8,
    };

    const DemoOutput = struct {
        source: []const u8,
        label: []const u8,
    };

    const DemoGenerator = Generator(DemoInput, DemoConfig).wrap(struct {
        pub fn validateConfig(comptime config: DemoConfig) void {
            if (config.name.len == 0) @compileError("DemoConfig.name cannot be empty");
        }

        pub fn generate(comptime input: DemoInput, comptime config: DemoConfig) DemoOutput {
            return .{
                .source = std.fmt.comptimePrint("// {s}: {s}", .{ config.name, @typeName(input.subject) }),
                .label = config.name,
            };
        }
    });

    const generated = comptime DemoGenerator.generate(.{ .subject = u32 }, .{ .name = "demo" });
    try std.testing.expect(std.mem.eql(u8, generated.source, "// demo: u32"));
    try std.testing.expect(std.mem.eql(u8, generated.label, "demo"));
}
