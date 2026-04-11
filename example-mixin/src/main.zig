const std = @import("std");
const example_mixin = @import("example_mixin");

pub fn main() !void {
    std.debug.print("\n=== Mixin Code Generation Example ===\n\n", .{});

    // Create a LoggableEntity (Entity + Loggable mixin)
    var loggable_entity = example_mixin.mixins.LoggableEntity.init(
        example_mixin.Entity.init(10.0, 20.0, 100),
        example_mixin.Loggable{ .log_prefix = "ENTITY", .log_count = 0 },
    );

    std.debug.print("Created LoggableEntity at ({d:.1}, {d:.1}) with {d} health\n", .{
        loggable_entity.base.x,
        loggable_entity.base.y,
        loggable_entity.base.health,
    });

    // Use methods from base Entity
    loggable_entity.move(5.0, 10.0);
    loggable_entity.takeDamage(25);
    loggable_entity.heal(10);

    // Use methods from Loggable extension
    loggable_entity.log("Entity is operational");
    loggable_entity.log("All systems nominal");

    std.debug.print("Entity alive: {}\n", .{loggable_entity.isAlive()});
    std.debug.print("Log count: {d}\n\n", .{loggable_entity.getLogCount()});

    // Create a NamedEntity (Entity + Named mixin)
    var named_entity = example_mixin.mixins.NamedEntity.init(
        example_mixin.Entity.init(0.0, 0.0, 150),
        example_mixin.Named{ .name = "Hero" },
    );

    std.debug.print("Created NamedEntity: {s}\n", .{named_entity.getName()});
    named_entity.takeDamage(50);
    std.debug.print("{s} health: {d}\n", .{ named_entity.getName(), named_entity.base.health });

    std.debug.print("\n=== Mixin generation successful! ===\n", .{});
}

test "loggable entity mixin" {
    var entity = example_mixin.mixins.LoggableEntity.initBase(
        example_mixin.Entity.init(0, 0, 100),
    );

    try std.testing.expect(entity.isAlive());
    entity.takeDamage(50);
    try std.testing.expectEqual(@as(i32, 50), entity.base.health);

    entity.log("test message");
    try std.testing.expectEqual(@as(usize, 1), entity.getLogCount());
}

test "named entity mixin" {
    var entity = example_mixin.mixins.NamedEntity.init(
        example_mixin.Entity.init(10, 20, 100),
        example_mixin.Named{ .name = "TestEntity" },
    );

    try std.testing.expectEqualStrings("TestEntity", entity.getName());
    try std.testing.expect(entity.isAlive());

    entity.setName("NewName");
    try std.testing.expectEqualStrings("NewName", entity.getName());
}
