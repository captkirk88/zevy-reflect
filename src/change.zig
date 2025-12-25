const std = @import("std");
const reflect = @import("reflect.zig");

const Allocator = std.mem.Allocator;

/// Change tracking container for any struct type T
///
/// Automatically detects changes by comparing a hash of the current data
/// against a stored prior hash. Only uses 8 bytes of additional memory.
/// Fields with names starting with `_` are ignored for change tracking.
///
/// Call init() to snapshot the current state, isChanged() to detect modifications.
///
/// Example:
/// const MyStruct = struct {
///    a: i32,
///   b: f32,
///   _internal: bool, // ignored for change tracking
/// };
/// var changeable = try Change(MyStruct).init(allocator, .{ .a = 0, .b = 0.0, ._internal = false });
/// defer changeable.deinit(allocator);
/// var data = changeable.get();
/// data.a = 42;
/// if (changeable.isChanged()) {
///   // process changes
///   changeable.finish(); // update prior hash to current state
/// }
pub fn Change(comptime T: type) type {
    const type_info = @typeInfo(T);
    if (type_info != .@"struct") {
        @compileError(std.fmt.comptimePrint("Change() requires type '{s}' to be a struct, got: {s}", .{ @typeName(T), @tagName(type_info) }));
    }
    const fields = type_info.@"struct".fields;
    if (fields.len == 0) {
        @compileError(std.fmt.comptimePrint("Change() requires type '{s}' to have fields", .{@typeName(T)}));
    }

    return opaque {
        const Self = @This();

        pub const Child = T;

        const Inner = struct {
            data: T,
            prior_hash: u64,
            allocator: Allocator,
        };

        /// Create a new Change tracker with initial data
        pub fn init(allocator: Allocator, data: T) !*Self {
            const inner = try allocator.create(Inner);
            inner.* = .{
                .data = data,
                .prior_hash = computeHash(data),
                .allocator = allocator,
            };
            return @ptrCast(inner);
        }

        /// Compute hash of all trackable fields (ignoring fields starting with `_`)
        fn computeHash(data: T) u64 {
            var hasher = std.hash.Wyhash.init(0);
            inline for (fields) |field| {
                if (field.name.len > 0 and field.name[0] != '_') {
                    const field_value = @field(data, field.name);
                    hasher.update(std.mem.asBytes(&field_value));
                }
            }
            return hasher.final();
        }

        /// Get mutable access to the data
        pub fn get(self: *Self) *T {
            const inner: *Inner = @ptrCast(@alignCast(self));
            if (self.isChanged()) {
                @panic("Previous unfinished changes");
            }
            return &inner.data;
        }

        /// Get const access to the data
        pub fn getConst(self: *const Self) *const T {
            const inner: *const Inner = @ptrCast(@alignCast(self));
            return &inner.data;
        }

        /// Check if changes have occurred by comparing current hash to prior
        pub fn isChanged(self: *const Self) bool {
            const inner: *const Inner = @ptrCast(@alignCast(self));
            const current_hash = computeHash(inner.data);
            return current_hash != inner.prior_hash;
        }

        pub fn tryFinish(self: *Self) bool {
            const inner: *Inner = @ptrCast(@alignCast(self));
            if (!self.isChanged()) return false;
            inner.prior_hash = computeHash(inner.data);
            return true;
        }

        /// Call this when you're done processing the changes
        /// Updates the prior hash to match current state
        pub fn finish(self: *Self) void {
            const inner: *Inner = @ptrCast(@alignCast(self));
            if (!self.isChanged()) @panic("No changes detected");
            inner.prior_hash = computeHash(inner.data);
        }

        /// Deinitialize and free the Change tracker
        pub fn deinit(self: *Self) void {
            const inner: *Inner = @ptrCast(@alignCast(self));
            // Call deinit if the type has one
            if (comptime reflect.hasFunc(T, "deinit")) {
                inner.data.deinit();
            }
            const allocator = inner.allocator;
            allocator.destroy(inner);
        }
    };
}

test "Change - initialization and basic operations" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const TestStruct = struct {
        id: u32,
        name: []const u8,
        active: bool,
    };

    const test_data = TestStruct{
        .id = 42,
        .name = "test",
        .active = true,
    };

    var change_tracker = try Change(TestStruct).init(allocator, test_data);
    defer change_tracker.deinit();

    // Test direct access
    const data = change_tracker.getConst();
    try testing.expectEqual(@as(u32, 42), data.id);
    try testing.expectEqualStrings("test", data.name);
    try testing.expect(data.active);

    // Initially no changes
    try testing.expect(!change_tracker.isChanged());
}

test "Change - commit and reset workflow" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const TestStruct = struct {
        score: u32,
        level: u8,
        name: []const u8,
    };

    var change_tracker = try Change(TestStruct).init(allocator, .{
        .score = 100,
        .level = 1,
        .name = "player",
    });
    defer change_tracker.deinit();

    // No changes yet
    try testing.expect(!change_tracker.isChanged());

    // Modify data directly
    var data = change_tracker.get();
    data.score = 200;
    data.level = 5;

    // Changes automatically detected via hash comparison
    try testing.expect(change_tracker.isChanged());

    // Process the changes...
    try testing.expectEqual(@as(u32, 200), change_tracker.getConst().score);

    // Finish when done with changes
    change_tracker.finish();
    try testing.expect(!change_tracker.isChanged());
}

test "Change - defer reset pattern" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const TestStruct = struct {
        x: i32,
        y: i32,
    };

    var change_tracker = try Change(TestStruct).init(allocator, .{ .x = 10, .y = 20 });
    defer change_tracker.deinit();

    {
        defer change_tracker.finish();

        var data = change_tracker.get();
        data.x = 100;
        data.y = 200;

        // Changes automatically detected
        try testing.expect(change_tracker.isChanged());
        // Process changes here...
    }

    // After defer, changes are reset
    try testing.expect(!change_tracker.isChanged());
    // But data is preserved
    try testing.expectEqual(@as(i32, 100), change_tracker.getConst().x);
}

test "Change - natural field access" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const TestStruct = struct {
        score: u32,
        name: []const u8,
    };

    var change_tracker = try Change(TestStruct).init(allocator, .{ .score = 0, .name = "hero" });
    defer change_tracker.deinit();

    // Natural field access
    var data = change_tracker.get();
    data.score = 30;
    data.name = "Hero";

    // Changes automatically detected
    try testing.expect(change_tracker.isChanged());
    try testing.expectEqual(@as(u32, 30), data.score);

    // Finish with changes
    change_tracker.finish();
    try testing.expect(!change_tracker.isChanged());
}
