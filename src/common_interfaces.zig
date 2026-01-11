const std = @import("std");
const interf = @import("interface.zig");

/// An interface template that is for the common equality check of a type
pub const Equal = interf.Template(struct {
    pub const Name: []const u8 = "Equal";
    pub fn eql(_: *const @This(), _: *const @This()) bool {
        unreachable;
    }
});

/// An interface template that is for the common hashing of a type
pub const Hashable = interf.Template(struct {
    pub const Name: []const u8 = "Hash";
    pub fn hash(_: *const @This()) u64 {
        unreachable;
    }
});

/// An interface template that is for the common comparison of two types
///
pub const Comparable = interf.Template(struct {
    pub const Name: []const u8 = "Comparable";
    pub fn cmp(_: *const @This(), _: *const @This()) std.math.Order {
        unreachable;
    }
});

/// An interface template that combines Comparable and Equal
pub const ComparableOrEqual = interf.Templates(&[_]type{ Comparable, Equal });

/// An interface template that is for the common formatting of a type
///
/// **When using interface instances (e.g., interface.ptr), std.fmt's {f} formatting
/// may not work due to method resolution on pointer types. Use the underlying value directly
/// for reliable {f} formatting and use the template to validate `format` exists.**
pub const Format = interf.Template(struct {
    pub const Name: []const u8 = "Format";
    pub fn format(_: *const @This(), writer: *std.io.Writer) std.io.Writer.Error!void {
        _ = writer;
        unreachable;
    }
});

/// An interface template that is for the common deinitialization of a type
pub const Deinit = interf.Template(struct {
    pub const Name: []const u8 = "Deinit";
    pub fn deinit(_: *@This()) void {
        unreachable;
    }
});

/// An interface template that is for the common deinitialization of a type with allocator
pub const DeinitAlloc = interf.Template(struct {
    pub const Name: []const u8 = "DeinitAlloc";
    pub fn deinit(_: *@This(), allocator: std.mem.Allocator) void {
        _ = allocator;
        unreachable;
    }
});

test {
    const Extra = interf.Template(struct {
        pub const Name: []const u8 = "Extra";
        pub fn extra() void {}
    });

    const MyType = struct {
        a: i32,
        b: i32,

        pub fn eql(this: *const @This(), other: *const @This()) bool {
            std.debug.print("eql called\n", .{});
            return this.a == other.a and this.b == other.b;
        }

        pub fn hash(this: *const @This()) u64 {
            std.debug.print("hash called\n", .{});
            return @as(u64, @intCast(this.a)) * 31 + @as(u64, @intCast(this.b));
        }

        pub fn cmp(this: *const @This(), other: *const @This()) std.math.Order {
            std.debug.print("cmp called\n", .{});
            if (this.a < other.a) return .lt;
            if (this.a > other.a) return .gt;
            if (this.b < other.b) return .lt;
            if (this.b > other.b) return .gt;
            return .eq;
        }

        /// Used for testing missing method for combined templates (comment out to test)
        pub fn extra() void {
            std.debug.print("extra called\n", .{});
        }

        pub fn format(this: *const @This(), writer: *std.io.Writer) std.io.Writer.Error!void {
            try writer.print("MyType {{ a: {}, b: {} }}", .{ this.a, this.b });
        }
    };

    var obj1 = MyType{ .a = 1, .b = 2 };
    var obj2 = MyType{ .a = 1, .b = 3 };
    const Combined = interf.Templates(&[_]type{ Equal, Hashable, Comparable, Extra, Format });

    var interface: Combined.Interface = undefined;
    Combined.populate(&interface, &obj1);
    //const interface = Combined.interface(MyType, obj1);
    try std.testing.expect(interface.vtable.eql(interface.ptr, &obj2) == false);
    try std.testing.expect(interface.vtable.hash(interface.ptr) != interface.vtable.hash(&obj2));

    try std.testing.expect(interface.vtable.cmp(interface.ptr, &obj2) == .lt);

    const result = std.fmt.allocPrint(std.testing.allocator, "{f}", .{obj1}) catch unreachable;
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("MyType { a: 1, b: 2 }", result);
}
