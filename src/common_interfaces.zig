const std = @import("std");
const interf = @import("interface.zig");

pub const Equal = interf.Template(struct {
    pub fn eql(_: *const @This(), _: *const @This()) bool {
        unreachable;
    }
});

pub const Hashable = interf.Template(struct {
    pub fn hash(_: *const @This()) u64 {
        unreachable;
    }
});

pub const Comparable = interf.Template(struct {
    pub fn cmp(_: *const @This(), _: *const @This()) std.math.Order {
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
    };

    var obj1 = MyType{ .a = 1, .b = 2 };
    var obj2 = MyType{ .a = 1, .b = 3 };
    const Combined = interf.Templates(&[_]type{ Equal, Hashable, Comparable, Extra });

    var interface: Combined.Interface = undefined;
    Combined.populate(&interface, &obj1);
    //const interface = Combined.interface(MyType, obj1);
    try std.testing.expect(interface.vtable.eql(interface.ptr, &obj2) == false);
    try std.testing.expect(interface.vtable.hash(interface.ptr) != interface.vtable.hash(&obj2));
}
