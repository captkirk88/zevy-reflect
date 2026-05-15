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
pub const PublicTypesResult = struct {
    names: []const []const u8,
    types: []const []const u8,
};

/// Maximum number of public type declarations that getPublicTypes will report.
const max_public_types = 64;

const PublicTypesRaw = struct {
    count: usize,
    names: [max_public_types][]const u8,
    types: [max_public_types][]const u8,
};

fn computePublicTypesRaw(comptime T: type) PublicTypesRaw {
    const ti = reflect.TypeInfo.from(T);
    const decls = ti.getDeclNames();

    var raw = PublicTypesRaw{ .count = 0, .names = undefined, .types = undefined };

    inline for (decls) |decl| {
        if (ti.getDecl(decl)) |d| {
            switch (d.category) {
                .Struct, .Enum, .Union, .Primitive => {
                    raw.names[raw.count] = decl;
                    raw.types[raw.count] = @typeName(d.type);
                    raw.count += 1;
                    if (raw.count >= max_public_types) break;
                },
                else => {},
            }
        }
    }
    return raw;
}

pub fn getPublicTypes(comptime T: type) ?PublicTypesResult {
    // const fields in a struct body are in static (rodata) memory —
    // pointers into them are valid at runtime.
    const Storage = struct {
        const raw: PublicTypesRaw = computePublicTypesRaw(T);
    };
    if (Storage.raw.count == 0) return null;
    return PublicTypesResult{
        .names = Storage.raw.names[0..Storage.raw.count],
        .types = Storage.raw.types[0..Storage.raw.count],
    };
}

/// Returns `true` if `T` structurally requires cleanup.
/// This checks for types that need explicit cleanup by examining:
/// - Types with a `deinit` method or opaque types
/// - Slices and dynamic arrays (which represent allocated memory)
/// - Optional types wrapping types that require cleanup
/// - Struct/union fields that transitively require cleanup
///
/// This is purely structural and doesn't search for function names beyond `deinit`,
/// making it efficient for reference-counted pointers (Arc/Rc) to determine if cleanup
/// is needed without expensive reflection.
///
/// Pointers are **not** recursed into (other than slice detection) because
/// ownership is not implied by single pointers.
pub fn requiresCleanup(comptime T: type) bool {
    const ti = @typeInfo(T);
    switch (ti) {
        // Opaque types might have cleanup
        .@"opaque" => return @hasDecl(T, "deinit"),

        // Slices and dynamic arrays always represent managed memory
        .pointer => |p| {
            if (p.size == .slice or p.size == .many) {
                return true;
            }
            // Single pointers are borrows, not ownership
            return false;
        },

        // Arrays might contain types needing cleanup
        .array => |a| return requiresCleanup(a.child),

        // Optionals wrap types that might need cleanup
        .optional => |o| return requiresCleanup(o.child),

        // Structs: check for deinit or fields needing cleanup
        .@"struct" => |s| {
            if (@hasDecl(T, "deinit")) return true;
            inline for (s.fields) |field| {
                if (requiresCleanup(field.type)) return true;
            }
            return false;
        },

        // Unions: check for deinit or fields needing cleanup
        .@"union" => |u| {
            if (@hasDecl(T, "deinit")) return true;
            inline for (u.fields) |field| {
                if (requiresCleanup(field.type)) return true;
            }
            return false;
        },

        // Primitives and everything else: no cleanup needed
        else => return false,
    }
}

/// Returns `true` if `T` has a `deinit` method, or if any of its fields
/// (struct / union / optional / array — but not through pointer indirection)
/// transitively have one.
///
/// Use this at comptime to decide whether a type requires cleanup without
/// necessarily exposing its own `deinit`.
///
/// Pointers are **not** recursed into because ownership is not implied.
pub fn hasDeinit(comptime T: type) bool {
    const ti = @typeInfo(T);
    switch (ti) {
        // Opaque types expose methods as decls
        .@"opaque" => return @hasDecl(T, "deinit"),
        .@"struct" => |s| {
            if (@hasDecl(T, "deinit")) return true;
            inline for (s.fields) |field| {
                if (hasDeinit(field.type)) return true;
            }
            return false;
        },
        .@"union" => |u| {
            if (@hasDecl(T, "deinit")) return true;
            inline for (u.fields) |field| {
                if (hasDeinit(field.type)) return true;
            }
            return false;
        },
        .optional => |o| return hasDeinit(o.child),
        .array => |a| return hasDeinit(a.child),
        // Pointers: don't recurse — pointer fields are borrows, not owned
        .pointer => return false,
        // Primitives and everything else: no cleanup needed
        else => return false,
    }
}

/// A simple Result type that can be used in comptime code.
///
/// *Maybe one day Zig will have closures...*
pub fn Result(comptime Ok: type, comptime Err: type) type {
    return union(enum) {
        Ok: Ok,
        Err: Err,

        pub fn success(value: Ok) Result(Ok, Err) {
            return Result(Ok, Err){ .Ok = value };
        }

        pub fn fail(error_: Err) Result(Ok, Err) {
            return Result(Ok, Err){ .Err = error_ };
        }

        pub fn err(err_: anyerror) Result(Ok, Err) {
            return Result(Ok, Err){ .Err = @as(Err, @errorName(err_)) };
        }

        pub fn isOk(self: @This()) bool {
            return switch (self) {
                .Ok => true,
                .Err => false,
            };
        }

        pub fn unwrap(self: @This()) Ok {
            return switch (self) {
                .Ok => self.Ok,
                .Err => @panic("called unwrap on an Err value"),
            };
        }

        pub fn unwrapErr(self: @This()) Err {
            return switch (self) {
                .Ok => @panic("called unwrapErr on an Ok value"),
                .Err => self.Err,
            };
        }

        pub fn expect(self: @This(), message: []const u8) Ok {
            return switch (self) {
                .Ok => self.Ok,
                .Err => @panic(message),
            };
        }

        pub fn expectErr(self: @This(), message: []const u8) Err {
            return switch (self) {
                .Ok => @panic(message),
                .Err => self.Err,
            };
        }

        pub fn map(self: @This(), comptime F: fn (Ok) Ok) Result(Ok, Err) {
            return switch (self) {
                .Ok => Result(Ok, Err){ .Ok = F(self.Ok) },
                .Err => self,
            };
        }

        pub fn mapErr(self: @This(), comptime F: fn (Err) Err) Result(Ok, Err) {
            return switch (self) {
                .Ok => self,
                .Err => Result(Ok, Err){ .Err = F(self.Err) },
            };
        }

        pub fn andThen(self: @This(), comptime F: fn (Ok) Result(Ok, Err)) Result(Ok, Err) {
            return switch (self) {
                .Ok => F(self.Ok),
                .Err => self,
            };
        }

        pub fn orElse(self: @This(), comptime F: fn (Err) Result(Ok, Err)) Result(Ok, Err) {
            return switch (self) {
                .Ok => self,
                .Err => F(self.Err),
            };
        }

        pub fn remapOk(self: @This(), comptime NewOk: type, comptime F: fn (Ok) NewOk) Result(NewOk, Err) {
            return switch (self) {
                .Ok => Result(NewOk, Err){ .Ok = F(self.Ok) },
                .Err => Result(NewOk, Err){ .Err = self.Err },
            };
        }

        pub fn remapError(self: @This(), comptime NewErr: type, comptime F: fn (Err) NewErr) Result(Ok, NewErr) {
            return switch (self) {
                .Ok => Result(Ok, NewErr){ .Ok = self.Ok },
                .Err => Result(Ok, NewErr){ .Err = F(self.Err) },
            };
        }
    };
}

test "Result type" {
    const MyResult = Result(u32, error{ A, B });
    const r1 = MyResult{ .Ok = 42 };
    const r2 = MyResult{ .Err = error.A };
    try std.testing.expect(r1.Ok == 42);
    try std.testing.expect(r2.Err == error.A);
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
        if (!std.mem.eql(u8, r.types[0], @typeName(namespace.TestStruct))) {
            std.debug.print("getPublicTypes mismatch: expected {s}, got {s}\n", .{ @typeName(namespace.TestStruct), r.types[0] });
        }
        try std.testing.expect(std.mem.eql(u8, r.types[0], @typeName(namespace.TestStruct)));
        const inner_result = getPublicTypes(namespace.TestStruct);
        if (inner_result) |ir| {
            try std.testing.expectEqualStrings("A", ir.names[0]);
            try std.testing.expectEqualStrings("B", ir.names[1]);
            try std.testing.expectEqualStrings("Inner", ir.names[2]);
            try std.testing.expect(std.mem.eql(u8, ir.types[0], @typeName(u32)));
            try std.testing.expect(std.mem.eql(u8, ir.types[1], @typeName(f32)));
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
        if (!std.mem.eql(u8, r.names[1], "Y")) {
            std.debug.print("getPublicTypes union name mismatch: expected Y, got {s}\n", .{r.names[1]});
        }
        try std.testing.expectEqualStrings("Y", r.names[1]);
        try std.testing.expect(std.mem.eql(u8, r.types[0], @typeName(bool)));
        try std.testing.expect(std.mem.eql(u8, r.types[1], @typeName(u8)));
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

test "hasDeinit - plain data type" {
    const Plain = struct { x: i32, y: bool };
    try std.testing.expect(!hasDeinit(Plain));
    try std.testing.expect(!hasDeinit(bool));
    try std.testing.expect(!hasDeinit(u64));
}

test "hasDeinit - type with deinit" {
    const WithDeinit = struct {
        buf: []u8,
        pub fn deinit(self: *@This()) void {
            _ = self;
        }
    };
    try std.testing.expect(hasDeinit(WithDeinit));
}

test "hasDeinit - nested field with deinit" {
    const Inner = struct {
        data: []u8,
        pub fn deinit(self: *@This()) void {
            _ = self;
        }
    };
    const Outer = struct { inner: Inner, count: u32 };
    try std.testing.expect(hasDeinit(Outer));
}

test "hasDeinit - pointer field not recursed" {
    const Pointee = struct {
        pub fn deinit(self: *@This()) void {
            _ = self;
        }
    };
    const Borrower = struct { ptr: *Pointee };
    // ptr is a borrow — Borrower itself doesn't need deinit
    try std.testing.expect(!hasDeinit(Borrower));
}

test "requiresCleanup - plain data types need no cleanup" {
    try std.testing.expect(!requiresCleanup(bool));
    try std.testing.expect(!requiresCleanup(u64));
    try std.testing.expect(!requiresCleanup(f32));
    const Plain = struct { x: i32, y: bool };
    try std.testing.expect(!requiresCleanup(Plain));
}

test "requiresCleanup - slices always require cleanup" {
    try std.testing.expect(requiresCleanup([]u8));
    try std.testing.expect(requiresCleanup([]const u8));
    try std.testing.expect(requiresCleanup([*]u8));
    try std.testing.expect(requiresCleanup([]i32));
}

test "requiresCleanup - arrays with cleanup children" {
    const WithDeinit = struct {
        pub fn deinit(self: *@This()) void {
            _ = self;
        }
    };
    try std.testing.expect(requiresCleanup([10]WithDeinit));
}

test "requiresCleanup - optionals of slices" {
    try std.testing.expect(requiresCleanup(?[]u8));
    try std.testing.expect(requiresCleanup(?[]i32));
}

test "requiresCleanup - type with deinit" {
    const WithDeinit = struct {
        pub fn deinit(self: *@This()) void {
            _ = self;
        }
    };
    try std.testing.expect(requiresCleanup(WithDeinit));
}

test "requiresCleanup - struct with slice field" {
    const WithSlice = struct { buf: []u8, count: u32 };
    try std.testing.expect(requiresCleanup(WithSlice));
}

test "requiresCleanup - struct with deinit field" {
    const Inner = struct {
        pub fn deinit(self: *@This()) void {
            _ = self;
        }
    };
    const Outer = struct { inner: Inner, count: u32 };
    try std.testing.expect(requiresCleanup(Outer));
}

test "requiresCleanup - single pointer is borrow (not cleanup)" {
    try std.testing.expect(!requiresCleanup(*u32));
    const Data = struct { x: i32 };
    try std.testing.expect(!requiresCleanup(*Data));
}

test "requiresCleanup - optional of non-cleanup type" {
    try std.testing.expect(!requiresCleanup(?u32));
    try std.testing.expect(!requiresCleanup(?bool));
}

test "requiresCleanup - array of primitives" {
    try std.testing.expect(!requiresCleanup([10]u8));
    try std.testing.expect(!requiresCleanup([100]i32));
}
