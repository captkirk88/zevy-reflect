const std = @import("std");

/// Change tracking container for any struct type T
///
/// Automatically detects changes by comparing a hash of the current data
/// against a stored prior hash. Only uses 8 bytes of additional memory.
/// Fields with names starting with `_` are ignored for change tracking.
///
/// Call mark() to snapshot the current state, isChanged() to detect modifications.
///
/// Example:
/// const MyStruct = struct {
///    a: i32,
///   b: f32,
///   _internal: bool, // ignored for change tracking
/// };
/// var changeable = Change(MyStruct).init(.{ .a = 0, .b = 0.0, ._internal = false });
/// var data = changeable.get();
/// data.a = 42;
/// if (changeable.isChanged()) {
///   // process changes
///   changeable.finish(); // update prior hash to current state
/// }
pub fn Change(comptime T: type) type {
    const type_info = @typeInfo(T);
    if (type_info != .@"struct") {
        @compileError("Change() requires a struct type");
    }

    return struct {
        _data: T,
        _prior_hash: u64,

        const Self = @This();

        pub fn init(data: T) Self {
            return .{
                ._data = data,
                ._prior_hash = computeHash(data),
            };
        }

        /// Compute hash of all trackable fields (ignoring fields starting with `_`)
        fn computeHash(data: T) u64 {
            var hasher = std.hash.Wyhash.init(0);
            inline for (type_info.@"struct".fields) |field| {
                if (field.name.len > 0 and field.name[0] != '_') {
                    const field_value = @field(data, field.name);
                    hasher.update(std.mem.asBytes(&field_value));
                }
            }
            return hasher.final();
        }

        /// Get mutable access to the data
        pub fn get(self: *Self) *T {
            if (self.isChanged()) {
                @panic("Previous unfinished changes");
            }
            return &self._data;
        }

        /// Get const access to the data
        pub fn getConst(self: *const Self) *const T {
            return &self._data;
        }

        /// Check if changes have occurred by comparing current hash to prior
        pub fn isChanged(self: *const Self) bool {
            const current_hash = computeHash(self._data);
            return current_hash != self._prior_hash;
        }

        /// Call this when you're done processing the changes
        /// Updates the prior hash to match current state
        pub fn finish(self: *Self) void {
            if (!self.isChanged()) @panic("No changes detected");
            self._prior_hash = computeHash(self._data);
        }
    };
}

test "Change - initialization and basic operations" {
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

    var change_tracker = Change(TestStruct).init(test_data);

    // Test direct access
    const data = change_tracker.getConst();
    try std.testing.expectEqual(@as(u32, 42), data.id);
    try std.testing.expectEqualStrings("test", data.name);
    try std.testing.expect(data.active);

    // Initially no changes
    try std.testing.expect(!change_tracker.isChanged());
}

test "Change - commit and reset workflow" {
    const TestStruct = struct {
        score: u32,
        level: u8,
        name: []const u8,
    };

    var change_tracker = Change(TestStruct).init(.{
        .score = 100,
        .level = 1,
        .name = "player",
    });

    // No changes yet
    try std.testing.expect(!change_tracker.isChanged());

    // Modify data directly
    var data = change_tracker.get();
    data.score = 200;
    data.level = 5;

    // Changes automatically detected via hash comparison
    try std.testing.expect(change_tracker.isChanged());

    // Process the changes...
    try std.testing.expectEqual(@as(u32, 200), change_tracker.getConst().score);

    // Finish when done with changes
    change_tracker.finish();
    try std.testing.expect(!change_tracker.isChanged());
}

test "Change - defer reset pattern" {
    const TestStruct = struct {
        x: i32,
        y: i32,
    };

    var change_tracker = Change(TestStruct).init(.{ .x = 10, .y = 20 });

    {
        defer change_tracker.finish();

        var data = change_tracker.get();
        data.x = 100;
        data.y = 200;

        // Changes automatically detected
        try std.testing.expect(change_tracker.isChanged());
        // Process changes here...
    }

    // After defer, changes are reset
    try std.testing.expect(!change_tracker.isChanged());
    // But data is preserved
    try std.testing.expectEqual(@as(i32, 100), change_tracker.getConst().x);
}

test "Change - natural field access" {
    const TestStruct = struct {
        score: u32,
        name: []const u8,
    };

    var change_tracker = Change(TestStruct).init(.{ .score = 0, .name = "hero" });

    // Natural field access
    var data = change_tracker.get();
    data.score = 30;
    data.name = "Hero";

    // Changes automatically detected
    try std.testing.expect(change_tracker.isChanged());
    try std.testing.expectEqual(@as(u32, 30), data.score);

    // Finish with changes
    change_tracker.finish();
    try std.testing.expect(!change_tracker.isChanged());
}
