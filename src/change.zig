const std = @import("std");
const reflect = @import("reflect.zig");

/// Recursively hash a value of any type, skipping struct fields prefixed with `_`.
fn hashValue(hasher: *std.hash.Wyhash, comptime FT: type, value: FT) void {
    switch (@typeInfo(FT)) {
        .@"struct" => |s| {
            inline for (s.fields) |f| {
                if (f.name.len > 0 and f.name[0] != '_') {
                    hashValue(hasher, f.type, @field(value, f.name));
                }
            }
        },
        .@"enum" => {
            const tag_int = @intFromEnum(value);
            hasher.update(std.mem.asBytes(&tag_int));
        },
        .@"union" => |u| {
            if (u.tag_type != null) {
                const tag = std.meta.activeTag(value);
                hasher.update(std.mem.asBytes(&tag));
                switch (value) {
                    inline else => |payload| {
                        hashValue(hasher, @TypeOf(payload), payload);
                    },
                }
            } else {
                hasher.update(std.mem.asBytes(&value));
            }
        },
        else => hasher.update(std.mem.asBytes(&value)),
    }
}

/// Change tracking container for any type T with fields (struct, enum, or tagged union).
///
/// Embeddable by value in other structs. No heap allocation.
/// Struct fields prefixed with `_` on the tracked type are ignored for change detection.
///
/// Call init() to snapshot the current state, isChanged() to detect modifications.
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
    const fields_len: usize = switch (type_info) {
        .@"struct" => |s| s.fields.len,
        .@"enum" => |e| e.fields.len,
        .@"union" => |u| u.fields.len,
        else => @compileError(std.fmt.comptimePrint("Change() requires type '{s}' to be a struct, enum, or union, got: {s}", .{ @typeName(T), @tagName(type_info) })),
    };
    if (fields_len == 0) {
        @compileError(std.fmt.comptimePrint("Change() requires type '{s}' to have fields", .{@typeName(T)}));
    }

    return struct {
        const Self = @This();

        pub const Child = T;

        _data: T,
        _prior_hash: u64,

        /// Create a new Change tracker with initial data.
        /// Comptime-evaluable; usable as a struct field default value.
        pub fn init(data: T) Self {
            return .{
                ._data = data,
                ._prior_hash = computeHash(data),
            };
        }

        /// Compute hash of all trackable fields (ignoring struct fields starting with `_`)
        fn computeHash(data: T) u64 {
            var hasher = std.hash.Wyhash.init(0);
            hashValue(&hasher, T, data);
            return hasher.final();
        }

        /// Get mutable access to the data. Panics if there are unfinished changes.
        pub fn get(self: *Self) *T {
            if (self.isChanged()) @panic("Previous unfinished changes");
            return &self._data;
        }

        /// Get const access to the data
        pub fn getConst(self: *const Self) *const T {
            return &self._data;
        }

        /// Return a copy of the current value.
        pub fn value(self: *const Self) T {
            return self._data;
        }

        /// Check if changes have occurred by comparing current hash to prior
        pub fn isChanged(self: *const Self) bool {
            return computeHash(self._data) != self._prior_hash;
        }

        pub fn tryFinish(self: *Self) bool {
            if (!self.isChanged()) return false;
            self._prior_hash = computeHash(self._data);
            return true;
        }

        /// Call this when you're done processing the changes
        /// Updates the prior hash to match current state
        pub fn finish(self: *Self) void {
            if (!self.isChanged()) @panic("No changes detected");
            self._prior_hash = computeHash(self._data);
        }

        /// Calls deinit on the tracked value if it has one.
        pub fn deinit(self: *Self) void {
            if (comptime reflect.hasFunc(T, "deinit")) {
                self._data.deinit();
            }
        }
    };
}

test "Change - initialization and basic operations" {
    const testing = std.testing;

    const TestStruct = struct {
        id: u32,
        name: []const u8,
        active: bool,
    };

    var change_tracker = Change(TestStruct).init(.{
        .id = 42,
        .name = "test",
        .active = true,
    });

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
    try testing.expect(change_tracker.isChanged());
    try testing.expectEqual(@as(u32, 30), data.score);

    // Finish with changes
    change_tracker.finish();
    try testing.expect(!change_tracker.isChanged());
}

test "Change - enum" {
    const testing = std.testing;

    const Mode = enum { windowed, fullscreen, borderless };

    var tracker = Change(Mode).init(.windowed);

    try testing.expect(!tracker.isChanged());

    tracker.get().* = .fullscreen;

    try testing.expect(tracker.isChanged());
    tracker.finish();
    try testing.expect(!tracker.isChanged());
}

test "Change - tagged union" {
    const testing = std.testing;

    const Value = union(enum) { int: i32, float: f64, flag: bool };

    var tracker = Change(Value).init(.{ .int = 0 });

    try testing.expect(!tracker.isChanged());

    tracker.get().* = .{ .int = 42 };
    try testing.expect(tracker.isChanged());
    tracker.finish();

    tracker.get().* = .{ .float = 3.14 };
    try testing.expect(tracker.isChanged());
    tracker.finish();
    try testing.expect(!tracker.isChanged());
}
