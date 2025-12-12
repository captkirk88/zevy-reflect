# zevy-reflect

A lightweight reflection and change detection library for Zig.

[![Zig Version](https://img.shields.io/badge/zig-0.15.1+-blue.svg)](https://ziglang.org/)

## Features

- **Runtime Type Information**: Get detailed type information at runtime including fields, functions, and nested types
- **Automatic Change Detection**: Track changes to struct fields with minimal memory overhead (8 bytes)
- **Zero Dependencies**: Pure Zig implementation with no external dependencies
- **Compile-time Safety**: Type-safe reflection with compile-time validation
- **Memory Efficient**: Shallow type information to avoid compile-time explosion

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

```zig
const reflect = @import("zevy_reflect");

const MyStruct = struct {
    id: u32,
    name: []const u8,
    active: bool,

    pub fn getId(self: @This()) u32 {
        return self.id;
    }
};

// Get type information
const type_info = reflect.getTypeInfo(MyStruct);
std.debug.print("Type: {s}, Size: {}\n", .{ type_info.name, type_info.size });

// Check for fields and functions
if (reflect.hasField(MyStruct, "name")) {
    std.debug.print("Has 'name' field\n", .{});
}

if (reflect.hasFunc(MyStruct, "getId")) {
    std.debug.print("Has 'getId' method\n", .{});
}
```

### Implements Interface Validation

```zig
const reflect = @import("zevy_reflect");
const Drawable = struct {
    pub fn draw(_: *@This()) void {};
};

const Circle = struct {
    radius: f32,
    pub fn draw(_: *@This()) void {
        // draw..
    }
}

pub fn draw(comptime DrawableImpl: Implements(Drawable), drawable: anytype) {
    DrawableImpl.satisfies(drawable); // If not satisfied, a nice compile error will occur.
}
```

### Change Detection

```zig
const reflect = @import("zevy_reflect");

const Player = struct {
    health: i32,
    score: u32,
    _internal_id: u64, // Ignored for change tracking
};

var player = Player{ .health = 100, .score = 0, ._internal_id = 123 };
var tracker = reflect.Change(Player).init(player);

// Modify data
var data = tracker.get();
data.health = 80;
data.score = 100;

// Changes automatically detected
if (tracker.isChanged()) {
    std.debug.print("Player data changed!\n", .{});
    // Process changes...

    // Mark as processed
    tracker.finish();
}
```

### Mixins (Experimental!)

See [Mixin Codegen](MIXIN_CODEGEN.md)

## API Reference

### Reflection

#### Types
- `TypeInfo`: Complete type information including fields, functions, and nested types
- `FieldInfo`: Information about a specific field (name, offset, type)
- `FuncInfo`: Information about a function (name, parameters, return type)
- `ShallowTypeInfo`: Lightweight type info without recursion

#### Functions
- `getTypeInfo(comptime T: type) TypeInfo`: Get complete type information
- `hasField(comptime T: type, field_name: []const u8) bool`: Check if type has a field
- `hasFunc(comptime T: type, func_name: []const u8) bool`: Check if type has a function
- `hasFuncWithArgs(comptime T: type, func_name: []const u8, arg_types: []const type) bool`: Check function signature
- `getFieldType(comptime T: type, field_name: []const u8) ?type`: Get field type
- `getFieldNames(comptime T: type) []const []const u8`: Get all field names

### Change Detection

#### `Change(T)` - Generic change tracker for struct type T

- `init(data: T) Change(T)`: Create a change tracker with initial data
- `get() *T`: Get mutable access to data (panics if unprocessed changes exist)
- `getConst() *const T`: Get const access to data
- `isChanged() bool`: Check if data has changed since last `finish()`
- `finish()`: Mark changes as processed and update baseline

#### Behavior
- **Automatic Detection**: Uses hash-based comparison, no manual marking required
- **Memory Efficient**: Only 8 bytes overhead per tracker
- **Field Filtering**: Fields starting with `_` are ignored for change detection
- **Type Safety**: Compile-time validation ensures T is a struct

## Examples

### Advanced Reflection

```zig
const reflect = @import("zevy_reflect");

const ComplexType = struct {
    simple_field: i32,
    array_field: [4]f32,
    optional_field: ?[]const u8,
    nested: struct {
        inner_field: bool,
    },

    pub fn method(self: @This(), param: i32) []const u8 {
        _ = self;
        _ = param;
        return "result";
    }
};

const info = reflect.getTypeInfo(ComplexType);
std.debug.print("Fields: {d}\n", .{info.fields.len});
std.debug.print("Functions: {d}\n", .{info.functions.len});

// Iterate through fields
for (info.fields) |field| {
    std.debug.print("Field: {s} ({s})\n", .{ field.name, field.type.name });
}
```

### Change Tracking with Multiple Fields

```zig
const reflect = @import("zevy_reflect");

const Config = struct {
    volume: f32,
    fullscreen: bool,
    resolution: struct { width: u32, height: u32 },
    _last_modified: u64, // Ignored for change tracking
};

var config = Config{
    .volume = 0.8,
    .fullscreen = false,
    .resolution = .{ .width = 1920, .height = 1080 },
    ._last_modified = 0,
};

var tracker = reflect.Change(Config).init(config);

// Simulate user changing settings
{
    var data = tracker.get();
    data.volume = 1.0;
    data.fullscreen = true;
}

if (tracker.isChanged()) {
    std.debug.print("Settings changed, saving...\n", .{});
    // Save to disk...
    tracker.finish();
}
```

## Performance

- **Reflection**: Compile-time heavy but zero runtime cost
- **Change Detection**: O(n) where n is the size of tracked fields, using efficient Wyhash
- **Memory**: 8 bytes per change tracker instance
- **No Allocations**: All operations are allocation-free

## Limitations

- **Structs Only**: Change detection only works with struct types
- **Hash Collisions**: Extremely unlikely but possible with Wyhash
- **Pointer Fields**: Hash includes pointer values, not pointed-to data
- **Compile Time**: Complex reflection can increase compile times

## Contributing

1. Fork the repository
2. Create a feature branch
3. Add tests for new functionality
4. Ensure all tests pass: `zig build test`
5. Submit a pull request

## Related Projects

- [zevy-ecs](https://github.com/captkirk88/zevy-ecs) - Entity Component System framework that uses zevy-reflect for serialization