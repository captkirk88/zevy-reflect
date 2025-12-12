# Mixin Code Generation

> [!WARN]
> Experimental

The `codegen.mixin_generator` module provides true mixin behavior through compile-time code generation. The mixin generator creates actual Zig code where all methods are directly available.

## Comparison

### Using Mixin Generator (Code Generation)
```zig
// Generated code creates a true merged type
var player = LoggablePlayer.init(base, ext);
player.takeDamage(10);  // Direct call!
player.log("damage");   // Direct call!
```

## How It Works

1. **Compile-time Generation**: Uses reflection to inspect both types
2. **Code String Creation**: Generates valid Zig source code as a string
3. **Method Wrappers**: Creates forwarding methods for all base and extension methods
4. **Field Merging**: Documents all fields from both types

## Usage

### In Your Code

```zig
const std = @import("std");
const zevy_reflect = @import("zevy_reflect");

const Player = struct {
    name: []const u8,
    health: i32,
    
    pub fn takeDamage(self: *@This(), damage: i32) void {
        self.health -= damage;
    }
};

const Loggable = struct {
    log_count: usize = 0,
    
    pub fn log(self: *@This(), message: []const u8) void {
        _ = message;
        self.log_count += 1;
    }
};

// Generate the mixin code at compile time
const mixin_code = comptime zevy_reflect.codegen.mixin_generator.generateMixinCode(
    Player,
    Loggable,
    .{
        .type_name = "LoggablePlayer",
        .base_type_name = "Player",
        .extension_type_name = "Loggable",
        .base_import_path = "types.zig",
        .extension_import_path = "traits.zig",
        .conflict_strategy = .extension_wins,
    },
);

// The generated code can be:
// 1. Printed for inspection
// 2. Written to a file during build
// 3. Used in further build steps
```

### In build.zig

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    // ... target, optimize setup ...

    // Generate mixin files during build
    const gen_step = b.addWriteFiles();
    
    // Add your generated mixin code
    const loggable_player_file = gen_step.add(
        "LoggablePlayer.zig",
        generated_mixin_code, // From generateMixinCode()
    );
    
    // Make it available to your executable
    const exe = b.addExecutable(.{
        .name = "game",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    
    exe.root_module.addAnonymousImport("LoggablePlayer", .{
        .root_source_file = loggable_player_file,
    });
    
    b.installArtifact(exe);
}
```

## Configuration Options

### `MixinConfig`

- **`type_name`**: Name for the generated mixin struct
- **`base_type_name`**: Name of the base type (for imports/references)
- **`extension_type_name`**: Name of the extension type
- **`base_import_path`**: Module path to import base type
- **`extension_import_path`**: Module path to import extension type
- **`conflict_strategy`**: How to handle method name conflicts

### Conflict Strategies

- **`extension_wins`**: Extension methods override base methods (default)
- **`base_wins`**: Base methods take precedence over extension
- **`error_on_conflict`**: Compilation error if any method names conflict

## Generated Code Structure

```zig
pub const LoggablePlayer = struct {
    base: Player,
    extension: Loggable,
    
    pub fn init(base: Player, extension: Loggable) LoggablePlayer { ... }
    pub fn initBase(base: Player) LoggablePlayer { ... }
    
    // Forwarding methods for all base methods
    pub fn takeDamage(self: *@This(), damage: i32) void {
        self.base.takeDamage(damage);
    }
    
    // Forwarding methods for all extension methods
    pub fn log(self: *@This(), message: []const u8) void {
        self.extension.log(message);
    }
};
```

## Benefits

1. **Zero Runtime Overhead**: Just method forwarding, no dynamic dispatch
2. **Type Safety**: All methods are known at compile time
3. **IDE Support**: Auto-completion works perfectly with generated types
4. **Clean API**: Direct method calls without helper functions
5. **Composable**: Can chain multiple mixins by generating sequentially

## Example Workflow

```zig
// 1. Define types
const Player = struct { ... };
const Loggable = struct { ... };
const Serializable = struct { ... };

// 2. Generate first mixin
const LoggablePlayer = generateMixinCode(Player, Loggable, ...);

// 3. Generate second mixin (composing with previous result)
const FullPlayer = generateMixinCode(LoggablePlayer, Serializable, ...);

// 4. Use in code
var player = FullPlayer.init(...);
player.takeDamage(10);      // From Player
player.log("damage");       // From Loggable
player.serialize();         // From Serializable
```

## Running the Example

```bash
# See generated code
zig build mixin-example

# Run tests
zig build test
```

## Limitations

- Requires build-time code generation
- Cannot generate mixins at runtime
- More complex build setup
- Generated files need to be managed (or generated in zig-cache)
