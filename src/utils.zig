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

fn Gen(comptime T: type) type {
    return struct {
        value: T,
    };
}
