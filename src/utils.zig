const std = @import("std");
const reflect = @import("reflect.zig");

/// Check if a type is an instantiation of a generic type with the given base name.
pub fn isGeneric(comptime T: anytype) bool {
    const TType = if (@TypeOf(T) == type) T else @TypeOf(T);
    const zig_type_info = @typeInfo(TType);
    switch (zig_type_info) {
        .@"fn" => return zig_type_info.@"fn".is_generic,
        else => return false,
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

/// Create a dynamic error set with a single error whose name is given by the comptime string.
pub fn DynamicError(comptime name: [:0]const u8) type {
    return @Type(.{
        .error_set = &[_]std.builtin.Type.Error{
            .{ .name = name },
        },
    });
}

/// Append a dynamic error to an existing error set, returning the merged error set.
pub fn MergeDynamicError(comptime BaseError: type, comptime dynamic_error_name: [:0]const u8) type {
    const MergedDynamicError = DynamicError(dynamic_error_name);
    return BaseError || MergedDynamicError;
}

test "isGeneric - primitive type" {
    try std.testing.expect(!isGeneric(u32));
}

test "isGeneric - wrong base name" {
    const list = Gen(u32);
    // Gen(u32) is an instantiated generic type, so isGeneric should return true
    try std.testing.expect(!isGeneric(list));
}

test "isGeneric - custom generic function" {
    try std.testing.expect(isGeneric(Gen));
}

test "isGeneric - instantiated generic type" {
    const gen = Gen;
    const generic = gen(u32);
    try std.testing.expect(isGeneric(gen));
    try std.testing.expect(!isGeneric(generic));
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

test "makeDynamicError" {
    const MyError = DynamicError("Foo");
    const err = MyError.Foo;
    try std.testing.expect(@TypeOf(err) == MyError);
    const name = @errorName(err);
    try std.testing.expectEqualStrings("Foo", name);
}

test "appendDynamicError" {
    const BaseError = error{ A, B };
    const Appended = MergeDynamicError(BaseError, "C");
    const errC = Appended.C;
    try std.testing.expect(@TypeOf(errC) == Appended);
    try std.testing.expectEqualStrings("C", @errorName(errC));
    const errA = Appended.A;
    try std.testing.expectEqualStrings("A", @errorName(errA));
}

fn Gen(comptime T: type) type {
    return struct {
        value: T,
    };
}
