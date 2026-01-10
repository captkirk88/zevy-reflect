# zevy-reflect

A lightweight reflection and change detection library for Zig.

[![Zig Version](https://img.shields.io/badge/zig-0.15.1+-blue.svg)](https://ziglang.org/)

## Features

- **Runtime Type Information**: Get detailed type information at runtime including fields, functions, and nested types
- **Interface Validation**: Compile-time validation of interface implementations with clear error messages
    - **VTable Generation**: Create vtables for dynamic dispatch based on interfaces, with support for interface extension. Tested using std.mem.Allocation.VTable interface.
- **Function Verification**: Compile-time validation of function signatures with dynamic error reporting for type mismatches
- **Dynamic Error Types**: Utilities for creating error sets with dynamic names at comptime
- **Change Detection**: Track changes to struct fields with minimal memory overhead (8 bytes)
- **Zero Dependencies**: Pure Zig implementation with no external dependencies

## Installation

Add to your `build.zig.zon`:

```bash
zig fetch --save git+https://github.com/captkirk88/zevy-reflect
```

Then in your `build.zig`:

```zig
const zevy_reflect = b.dependency("zevy_reflect", .{
    .branch_quota = 1_000_000, // adjust as needed
});
exe.root_module.addImport("zevy_reflect", zevy_reflect.module("zevy_reflect"));
```

## Quick Start

### Reflection

This library provides both lightweight (shallow) runtime `ReflectInfo` and a small set of helpers to query type structure.

```zig
const reflect = @import("zevy_reflect");
const std = @import("std");

const MyStruct = struct {
    id: u32,
    name: []const u8,
    active: bool,

    pub fn getId(self: @This()) u32 { return self.id; }
};

comptime {
    const info = reflect.getReflectInfo(MyStruct);
    std.debug.print("Name: {s}, Size: {d}\n", .{ info.name, info.size });

    // Field checks (comptime-safe helpers):
    try std.testing.expect(comptime reflect.hasField(MyStruct, "id"));
    try std.testing.expect(comptime reflect.hasFunc(MyStruct, "getId"));

    // List field names at comptime
    const fields = reflect.getFields(MyStruct);
    inline for (fields) |f| std.debug.print("field: {s}\n", .{ f });
}

// Runtime: use ReflectInfo to introspect dynamic metadata
const ti = reflect.getReflectInfo(MyStruct);
std.debug.print("Runtime fields: {d}\n", .{ ti.fields.len });
```

Notes:
- `getReflectInfo` returns shallow field and function metadata suitable for runtime use.

### Utilities

The library provides various utility functions for advanced reflection and error handling:

```zig
const reflect = @import("zevy_reflect");

// Create dynamic error sets
const MyError = reflect.utils.DynamicError("CustomError");
const err = MyError.CustomError;

// Append errors to existing sets
const ExtendedError = reflect.utils.MergeDynamicError(error{ Base }, "Dynamic");

// Verify function signatures with detailed type mismatch errors
comptime {
    try std.testing.expect(comptime reflect.verifyFuncWithArgs(MyStruct, "getId", &[_]type{}, null) catch false);
    // Type mismatches generate specific errors like "IncorrectArgAt_0_Expected_i32_Got_f32"
}
```

### Interface Validation and VTable

`Template(...)` provides a compile-time validator and a typed vtable generator. Useful when you want an explicit interface and a vtable for dynamic dispatch. You can also obtain a convenience bound interface instance with `Template.interface(ImplType, &instance)`.

This is a different approach to interfaces in Zig.  Hopefully more useful and generally easier to integrate.

See [common_interfaces.zig](src/common_interfaces.zig) for a examples.

### Change Detection

`Change(T)` is a tiny tracker that hashes trackable fields and detects modifications. Fields beginning with `_` are ignored.

```zig
const reflect = @import("zevy_reflect");
const std = @import("std");

const Player = struct {
    health: i32,
    score: u32,
    _internal_id: u64, // ignored by Change
};

var player = Player{ .health = 100, .score = 0, ._internal_id = 123 };
var tracker = reflect.Change(Player).init(player);

// Mutate through `get()` (mutable) and finish when processed
var data = tracker.get();
data.health = 80;
data.score = 100;

if (tracker.isChanged()) {
    std.debug.print("Player changed: {d}\n", .{ tracker.getConst().score });
    tracker.finish();
}
```

> [!WARNING]
> The tracker compares raw bytes for tracked fields; pointer/slice/array contents are hashed as their pointer/length/contents as appropriate. Be cautious with non-stable data (e.g., transient pointers).

## Contributing

1. Fork the repository
2. Create a feature branch
3. Add tests for any new functionality
4. Ensure all tests pass: `zig build test`
5. Submit a pull request

## Related Projects

- [zevy-ecs](https://github.com/captkirk88/zevy-ecs) - Entity Component System framework that uses zevy-reflect.