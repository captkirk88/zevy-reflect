//! By convention, root.zig is the root source file when making a library.
const std = @import("std");
const types = @import("types");

// Re-export the base types for use in generated code
pub const Entity = types.Entity;
pub const Loggable = types.Loggable;
pub const Named = types.Named;

// Import and re-export generated mixins
pub const mixins = @import("generated_mixin");

test "verify types are exported" {
    const entity = Entity.init(0, 0, 100);
    try std.testing.expect(entity.isAlive());
}
