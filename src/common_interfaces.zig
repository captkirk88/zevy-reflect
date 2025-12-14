const std = @import("std");
const impl = @import("impl.zig");

/// Equality interface
///
/// Usage:
/// ```zig
/// pub const Point = struct {
///     pub const vtable = Interface(Equal(Point)).vTableAsTemplate(@This());
///     x: i32,
///     y: i32,
///
///     pub fn eql(this: *const Point, other: *const Point) bool {
///         return this.x == other.x and this.y == other.y;
///     }
/// };
///
/// var p1 = Point{ .x = 1, .y = 2 };
/// var p2 = Point{ .x = 1, .y = 2 };
/// p1.vtable.eql(&p1, &p2); // returns true
/// ```
pub fn Equal() type {
    const vt = struct {
        eql: *const fn (*const anyopaque, *const anyopaque) bool,
    };
    return impl.Interface(vt);
}

/// Usage:
/// ```zig
/// pub const Point = struct {
///     pub const vtable = Interface(Equal()).vTableAsTemplate(@This());
///     x: i32,
///     y: i32,
///
///     pub fn hash(this: *const Point) u64 {
///         return @as(u64, this.x) * 31 + @as(u64, this.y);
///     }
/// };
///
/// var p1 = Point{ .x = 1, .y = 2 };
/// var p2 = Point{ .x = 1, .y = 2 };
/// p1.vtable.eql(&p1, &p2); // returns true
/// ```
pub fn Hashable() type {
    return impl.Interface(struct {
        hash: *const fn (*const anyopaque) u64,
    });
}

/// Comparable interface
///
/// Usage:
/// ```zig
/// pub const MyType = struct {
///     pub const vtable = Interface(Comparable()).vTableAsTemplate(@This());
///     a: i32,
///     b: i32,
///
///     pub fn cmp(this: *const MyType, other: *const MyType) std.math.Order {
///         if (this.a < other.a) return .lt;
///         if (this.a > other.a) return .gt;
///         if (this.b < other.b) return .lt;
///         if (this.b > other.b) return .gt;
///       return .eq;
///   }
/// };
///
/// var obj1 = MyType{ .a = 1, .b = 2 };
/// var obj2 = MyType{ .a = 1, .b = 2 };
/// MyType.vtable.cmp(&obj1, &obj2); // returns .eq
/// ```
pub fn Comparable() type {
    return impl.Interface(struct {
        cmp: *const fn (*const anyopaque, *const anyopaque) std.math.Order,
    });
}

test {
    const MyType = struct {
        pub const vtable = impl.Interfaces(&[_]type{
            Equal().TemplateType,
            Hashable().TemplateType,
            Comparable().TemplateType,
        }).vTable(@This());
        a: i32,
        b: i32,

        pub fn eql(this: *const @This(), other: *const @This()) bool {
            return this.a == other.a and this.b == other.b;
        }

        pub fn hash(this: *const @This()) u64 {
            return @as(u64, @intCast(this.a)) * 31 + @as(u64, @intCast(this.b));
        }

        pub fn cmp(this: *const @This(), other: *const @This()) std.math.Order {
            if (this.a < other.a) return .lt;
            if (this.a > other.a) return .gt;
            if (this.b < other.b) return .lt;
            if (this.b > other.b) return .gt;
            return .eq;
        }
    };

    var obj1 = MyType{ .a = 1, .b = 2 };
    var obj2 = MyType{ .a = 1, .b = 3 };
    try std.testing.expect(MyType.vtable.eql(&obj1, &obj2) == false);
    const hash1 = MyType.vtable.hash(&obj1);
    const hash2 = MyType.vtable.hash(&obj2);
    try std.testing.expect(hash1 != hash2);
    try std.testing.expect(MyType.vtable.cmp(&obj1, &obj2) == .lt);
}
