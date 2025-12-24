const std = @import("std");
const reflect = @import("reflect.zig");

/// Check if a type is an instantiation of a generic type with the given base name.
/// For example, isGenericInstantiation(MyType, "ArrayList") checks if MyType is ArrayList(SomeType).
pub fn isGenericInstantiation(comptime T: anytype, comptime base_name: []const u8) bool {
    const info = reflect.getInfo(if (@typeInfo(@TypeOf(T)) == .type) T else @TypeOf(T));
    switch (info) {
        .type => {
            const name = @typeName(T);
            var buf: [base_name.len + 1]u8 = undefined;
            @memcpy(buf[0..base_name.len], base_name);
            buf[base_name.len] = '(';
            return std.mem.indexOf(u8, name, &buf) != null;
        },
        .func => |fi| return fi.return_type == .type and fi.return_type.type.type == type,
    }
}

/// Get all public types exposed in a parent type.
/// Returns an optional struct with names as an array of strings and types as an array of types, or null if none.
///
/// Example:
/// ```zig
/// const namespace = struct {
///     pub const TestStruct = struct {
///         pub const A = u32;
///         pub const B = f32;
///         pub Inner = struct {};
///         pub var d: i32 = 1; // not type
///     };
/// };
/// const result = getPublicTypes(namespace);
/// if (result) |r| {
///    ...
/// }
/// ```
pub fn getPublicTypes(comptime T: type) ?struct {
    names: []const []const u8,
    types: []const type,
} {
    const info = reflect.getInfo(T);
    if (info != .type) return null;

    const ti = info.type;
    const decls = ti.getDeclNames();

    comptime var count = 0;
    inline for (decls) |decl| {
        if (ti.getDecl(decl)) |d| {
            switch (d.category) {
                .Struct, .Enum, .Union, .Primitive => count += 1,
                else => {},
            }
        }
    }

    if (decls.len == 0) return null;

    var names: [count][]const u8 = undefined;
    var types: [count]type = undefined;

    comptime var i = 0;
    inline for (decls) |decl| {
        if (ti.getDecl(decl)) |d| {
            switch (d.category) {
                .Struct, .Enum, .Union, .Primitive => {
                    names[i] = decl;
                    types[i] = d.type;
                    i += 1;
                },
                else => {},
            }
        }
    }

    return .{ .names = &names, .types = &types };
}

test "isGenericInstantiation - primitive type" {
    try std.testing.expect(!isGenericInstantiation(u32, "Gen"));
}

test "isGenericInstantiation - wrong base name" {
    const list = Gen(u32);
    try std.testing.expect(!isGenericInstantiation(list, "Other"));
}

test "isGenericInstantiation - custom generic function" {
    try std.testing.expect(isGenericInstantiation(Gen, "Gen"));
}

test "isGenericInstantiation - instantiated generic type" {
    const gen = Gen;
    const generic = gen(u32);
    try std.testing.expect(isGenericInstantiation(gen, "Gen"));
    try std.testing.expect(isGenericInstantiation(generic, "Gen"));
}

test "getPublicTypes - struct with public types" {
    const namespace = struct {
        pub const TestStruct = struct {
            pub const A = u32;
            pub const B = f32;
            pub const Inner = struct {};
            pub var d: i32 = 1; // not type
        };
    };

    const result = getPublicTypes(namespace);
    try std.testing.expect(result != null);
    if (result) |r| {
        try std.testing.expectEqual(@as(usize, 1), r.names.len);
        try std.testing.expectEqual(@as(usize, 1), r.types.len);
        try std.testing.expectEqualStrings("TestStruct", r.names[0]);
        try std.testing.expect(r.types[0] == namespace.TestStruct);
        const inner_result = getPublicTypes(namespace.TestStruct);
        if (inner_result) |ir| {
            try std.testing.expectEqualStrings("A", ir.names[0]);
            try std.testing.expectEqualStrings("B", ir.names[1]);
            try std.testing.expectEqualStrings("Inner", ir.names[2]);
            try std.testing.expect(ir.types[0] == u32);
            try std.testing.expect(ir.types[1] == f32);
        }
    }
}

test "getPublicTypes - union with public types" {
    const TestUnion = union(enum) {
        pub const X = bool;
        pub const Y = u8;
        a: u32,
    };

    const result = getPublicTypes(TestUnion);
    try std.testing.expect(result != null);
    if (result) |r| {
        try std.testing.expectEqual(@as(usize, 2), r.names.len);
        try std.testing.expectEqual(@as(usize, 2), r.types.len);
        try std.testing.expectEqualStrings("X", r.names[0]);
        try std.testing.expectEqualStrings("Y", r.names[1]);
        try std.testing.expect(r.types[0] == bool);
        try std.testing.expect(r.types[1] == u8);
    }
}

test "getPublicTypes - no public types" {
    const TestStruct = struct {
        const b = u33;
    };

    const result = getPublicTypes(TestStruct);
    try std.testing.expect(result == null);
}

test "getPublicTypes - primitive type" {
    const result = getPublicTypes(u32);
    try std.testing.expect(result == null);
}

fn Gen(comptime T: type) type {
    return struct {
        value: T,
    };
}
