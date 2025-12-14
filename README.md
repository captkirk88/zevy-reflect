# zevy-reflect

A lightweight reflection and change detection library for Zig.

[![Zig Version](https://img.shields.io/badge/zig-0.15.1+-blue.svg)](https://ziglang.org/)

## Features

- **Runtime Type Information**: Get detailed type information at runtime including fields, functions, and nested types
- **Interface Validation**: Compile-time validation of interface implementations with clear error messages
    - **VTable Generation**: Create vtables for dynamic dispatch based on interfaces, with support for interface extension. Tested using std.mem.Allocation.VTable interface.
- **Change Detection**: Track changes to struct fields with minimal memory overhead (8 bytes)
- **Zero Dependencies**: Pure Zig implementation with no external dependencies
- **Branch Quota Efficient**: Reduced comptime branch quota usage for better compile-time performance.

## Installation

Add to your `build.zig.zon`:

```bash
zig fetch --save git+https://github.com/captkirk88/zevy-reflect
```

Then in your `build.zig`:

```zig
const zevy_reflect = b.dependency("zevy_reflect", .{});
exe.root_module.addImport("zevy_reflect", zevy_reflect.module("zevy_reflect"));
```

## Quick Start

### Reflection

This library provides both lightweight (shallow) runtime `TypeInfo` and a small set of helpers to query type structure without blowing up comptime.

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
    const info = reflect.getTypeInfo(MyStruct);
    std.debug.print("Name: {s}, Size: {d}\n", .{ info.name, info.size });

    // Field checks (comptime-safe helpers):
    try std.testing.expect(comptime reflect.hasField(MyStruct, "id"));
    try std.testing.expect(comptime reflect.hasFunc(MyStruct, "getId"));

    // List field names at comptime
    const fields = reflect.getFields(MyStruct);
    inline for (fields) |f| std.debug.print("field: {s}\n", .{ f });
}

// Runtime: use TypeInfo to introspect dynamic metadata (shallow info avoids recursion)
const ti = reflect.getTypeInfo(MyStruct);
std.debug.print("Runtime fields: {d}\n", .{ ti.fields.len });

// Construct a value using `TypeInfo.new` from a tuple literal (comptime API)
comptime {
    const ti_comp = reflect.getTypeInfo(MyStruct);
    const instance_default = ti_comp.new(.{});
    const instance_override = ti_comp.new(.{ .id = 10, .name = "bob" });
    try std.testing.expectEqual(@as(u32, 10), instance_override.id);
}
```

Notes:
- `getTypeInfo` returns shallow field and function metadata suitable for runtime use.
- `TypeInfo.new` is a comptime helper that constructs values from tuple literals; useful for code generation and tests.

### Interface Validation and VTable

`Interface(Template)` provides a compile-time validator and a typed vtable generator. Useful when you want an explicit interface and a vtable for dynamic dispatch.

```zig
const VTable = struct {
    doThing: *const fn (self: *anyopaque, value: u32) u32,
};

const Impl = struct {
    pub fn doThing(_: *@This(), value: u32) u32 {
        return value * 2;
    }
};

const TraitImpl = Interface(VTable);
var inst = Impl{};
var vt = TraitImpl.vTableAsTemplate(Impl);

const result = vt.doThing(&inst, 21);
std.debug.assert(result == 42); // The answer to life, the universe, and everything
```

Notes:
- `validate` checks method names and signatures (including handling `self`), emitting clear compile-time errors when mismatched.
- `vTable` returns a compile-time constructed struct of function pointers matching the template methods.
- `extend` allows adding another interface to create composite interfaces.

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

Caveats:
- The tracker compares raw bytes for tracked fields; pointer/slice/array contents are hashed as their pointer/length/contents as appropriate. Be cautious with non-stable data (e.g., transient pointers).

## Contributing

1. Fork the repository
2. Create a feature branch
3. Add tests for any new functionality
4. Ensure all tests pass: `zig build test`
5. Submit a pull request

## Related Projects

- [zevy-ecs](https://github.com/captkirk88/zevy-ecs) - Entity Component System framework that uses zevy-reflect.