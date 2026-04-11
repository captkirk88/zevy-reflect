const std = @import("std");

/// A simple entity with position and health
pub const Entity = struct {
    x: f32,
    y: f32,
    health: i32,

    pub fn init(x: f32, y: f32, health: i32) Entity {
        return .{ .x = x, .y = y, .health = health };
    }

    pub fn takeDamage(self: *@This(), damage: i32) void {
        self.health -= damage;
        std.debug.print("Entity took {d} damage! Health: {d}\n", .{ damage, self.health });
    }

    pub fn heal(self: *@This(), amount: i32) void {
        self.health += amount;
        std.debug.print("Entity healed {d}! Health: {d}\n", .{ amount, self.health });
    }

    pub fn move(self: *@This(), dx: f32, dy: f32) void {
        self.x += dx;
        self.y += dy;
        std.debug.print("Entity moved to ({d:.2}, {d:.2})\n", .{ self.x, self.y });
    }

    pub fn isAlive(self: *const @This()) bool {
        return self.health > 0;
    }
};

/// Adds logging capabilities to any type
pub const Loggable = struct {
    log_prefix: []const u8 = "LOG",
    log_count: usize = 0,

    pub fn log(self: *@This(), message: []const u8) void {
        self.log_count += 1;
        std.debug.print("[{s}] {s}\n", .{ self.log_prefix, message });
    }

    pub fn logf(self: *@This(), comptime fmt: []const u8, args: anytype) void {
        self.log_count += 1;
        std.debug.print("[{s}] ", .{self.log_prefix});
        std.debug.print(fmt ++ "\n", args);
    }

    pub fn getLogCount(self: *const @This()) usize {
        return self.log_count;
    }
};

/// Adds named identification
pub const Named = struct {
    name: []const u8,

    pub fn getName(self: *const @This()) []const u8 {
        return self.name;
    }

    pub fn setName(self: *@This(), new_name: []const u8) void {
        self.name = new_name;
    }

    pub fn printName(self: *const @This()) void {
        std.debug.print("Name: {s}\n", .{self.name});
    }
};
