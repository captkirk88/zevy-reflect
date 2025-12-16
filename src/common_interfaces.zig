const std = @import("std");
const impl = @import("impl.zig");

pub const Equal = impl.Template(struct {
    pub fn eql(_: *const @This(), _: *const @This()) bool {
        unreachable;
    }
});

pub const Hashable = impl.Template(struct {
    pub fn hash(_: *const @This()) u64 {
        unreachable;
    }
});

pub const Comparable = impl.Template(struct {
    pub fn cmp(_: *const @This(), _: *const @This()) std.math.Order {
        unreachable;
    }
});

test {
    const MyType = struct {
        a: i32,
        b: i32,

        pub fn eql(this: *const @This(), other: *const @This()) bool {
            //std.debug.print("eql called\n", .{});
            return this.a == other.a and this.b == other.b;
        }

        pub fn hash(this: *const @This()) u64 {
            //std.debug.print("hash called\n", .{});
            return @as(u64, @intCast(this.a)) * 31 + @as(u64, @intCast(this.b));
        }

        pub fn cmp(this: *const @This(), other: *const @This()) std.math.Order {
            //std.debug.print("cmp called\n", .{});
            if (this.a < other.a) return .lt;
            if (this.a > other.a) return .gt;
            if (this.b < other.b) return .lt;
            if (this.b > other.b) return .gt;
            return .eq;
        }
    };

    var obj1 = MyType{ .a = 1, .b = 2 };
    var obj2 = MyType{ .a = 1, .b = 3 };
    const Combined = impl.Interfaces(&[_]type{ Equal, Hashable, Comparable });
    const vt = Combined.vTable(MyType);
    try std.testing.expect(vt.eql(&obj1, &obj2) == false);
    try std.testing.expect(vt.eql(&obj1, &obj1) == true);
    const hash1 = vt.hash(&obj1);
    const hash2 = vt.hash(&obj2);
    try std.testing.expect(hash1 != hash2);
    try std.testing.expect(vt.cmp(&obj1, &obj2) == .lt);

    const InterfaceType = Combined.Interface;
    var interface: InterfaceType = undefined;
    interface.ptr = @ptrCast(@alignCast(&obj1));
    interface.vtable = Combined.vTableAsTemplate(MyType);
    //const interface = Combined.interface(MyType, obj1);
    try std.testing.expect(interface.vtable.eql(interface.ptr, &obj2) == false);
    try std.testing.expect(interface.vtable.hash(interface.ptr) != interface.vtable.hash(&obj2));
}
