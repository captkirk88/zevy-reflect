const std = @import("std");

/// A single named function entry in a DynamicVTable.
///
/// `Fn` must be a function type whose first parameter is `*anyopaque` or
/// `*const anyopaque` — the type-erased context/self pointer.
pub const VTableEntry = struct {
    name: [:0]const u8,
    Fn: type,
};

// ── internal helpers ───────────────────────────────────────────────────────

fn validateEntry(comptime entry: VTableEntry) void {
    const info = @typeInfo(entry.Fn);
    if (info != .@"fn") {
        @compileError("DynamicVTable: entry '" ++ entry.name ++
            "' — Fn must be a function type, got " ++ @typeName(entry.Fn));
    }
    const fn_info = info.@"fn";
    if (fn_info.params.len > 0) {
        const first_type = fn_info.params[0].type orelse {
            @compileError("DynamicVTable: entry '" ++ entry.name ++
                "' — first parameter must have a concrete type");
        };
        if (first_type != *anyopaque and first_type != *const anyopaque) {
            @compileError("DynamicVTable: entry '" ++ entry.name ++
                "' — first parameter must be *anyopaque or *const anyopaque, got " ++
                @typeName(first_type));
        }
    }
}

/// Build the storage struct type: one `*const entry.Fn` field per entry.
fn buildStorageType(comptime entries: []const VTableEntry) type {
    var names: [entries.len][:0]const u8 = undefined;
    var types: [entries.len]type = undefined;
    var attrs: [entries.len]std.builtin.Type.StructField.Attributes = undefined;
    for (entries, 0..) |entry, i| {
        names[i] = entry.name;
        types[i] = *const entry.Fn;
        attrs[i] = .{
            .@"comptime" = false,
            .@"align" = @alignOf(*const entry.Fn),
            .default_value_ptr = null,
        };
    }
    return @Struct(.auto, null, &names, &types, &attrs);
}

fn mergeEntries(comptime base: []const VTableEntry, comptime extra: []const VTableEntry) []const VTableEntry {
    comptime {
        var merged: []const VTableEntry = base;
        for (extra) |entry| {
            for (merged) |existing| {
                if (std.mem.eql(u8, existing.name, entry.name)) {
                    @compileError("DynamicVTable.Extend: duplicate entry name '" ++ entry.name ++ "'");
                }
            }
            merged = merged ++ &[_]VTableEntry{entry};
        }
        return merged;
    }
}

// ── public API ─────────────────────────────────────────────────────────────

/// A compile-time vtable keyed by function name, supporting subset projection
/// and swapping between interfaces at runtime.
///
/// All function entries must use `*anyopaque` (or `*const anyopaque`) as their
/// first parameter so that vtable instances are independent of any concrete
/// implementation type.  A single instance built from one `Impl` can be
/// projected onto any subset vtable whose entries are a subset of the methods
/// present in `Impl`.
///
/// **Building a vtable from a concrete implementation**
/// ```zig
/// const FullVT = DynamicVTable(&.{
///     .{ .name = "draw",    .Fn = fn (*anyopaque) void },
///     .{ .name = "update",  .Fn = fn (*anyopaque, f32) void },
///     .{ .name = "destroy", .Fn = fn (*anyopaque) void },
/// });
///
/// var vtable: FullVT = undefined;
/// vtable.populate(Sprite); // fully comptime-evaluated
/// ```
///
/// **Calling through a vtable**
/// ```zig
/// var sprite = Sprite{};
/// vtable.vtable.draw(@ptrCast(&sprite));
/// vtable.get("update")(@ptrCast(&sprite), 0.016);
/// ```
///
/// **Projecting to a smaller subset**
/// ```zig
/// const DrawVT   = FullVT.Subset(&.{"draw"});
/// const draw_vt  = vtable.projectToSubset(&.{"draw"});
/// draw_vt.vtable.draw(@ptrCast(&sprite));
/// ```
pub fn DynamicVTable(comptime entries: []const VTableEntry) type {
    comptime for (entries) |entry| validateEntry(entry);

    const Storage = buildStorageType(entries);

    return struct {
        const Self = @This();

        fn providerType(comptime provider: anytype) type {
            const P = @TypeOf(provider);
            if (P == type) return provider;
            return switch (@typeInfo(P)) {
                .pointer => |p| p.child,
                else => P,
            };
        }

        /// Generated struct with one `*const Fn` field per entry.
        pub const VTable = Storage;

        /// The entries this vtable type was constructed from.
        pub const fn_entries: []const VTableEntry = entries;

        /// Storage holding the erased function pointers.
        vtable: Storage,

        // ── construction ──────────────────────────────────────────────────

        /// Populate this vtable instance from a provider.
        ///
        /// `provider` may be a type, a value, or a pointer to value.
        /// The provider type must expose declarations matching each entry name.
        pub fn populate(self: *Self, comptime provider: anytype) void {
            const Provider = providerType(provider);
            self.vtable = comptime blk: {
                var stor: Storage = undefined;
                for (entries) |entry| {
                    if (!@hasDecl(Provider, entry.name)) {
                        @compileError("DynamicVTable.populate: '" ++ @typeName(Provider) ++
                            "' is missing declaration '" ++ entry.name ++ "'");
                    }
                    @field(stor, entry.name) = @ptrCast(&@field(Provider, entry.name));
                }
                break :blk stor;
            };
        }

        fn createFromBase(base: anytype, comptime provider: anytype) Self {
            const BaseVTable = @TypeOf(base);
            comptime if (!Self.containsAll(BaseVTable)) {
                @compileError("DynamicVTable.create: base vtable is not a subset of destination vtable");
            };

            const Provider = providerType(provider);

            var stor: Storage = undefined;
            inline for (entries) |entry| {
                if (@hasField(BaseVTable.VTable, entry.name)) {
                    @field(stor, entry.name) = @field(base.vtable, entry.name);
                } else {
                    if (!@hasDecl(Provider, entry.name)) {
                        @compileError("DynamicVTable.create: provider is missing declaration '" ++ entry.name ++ "'");
                    }
                    @field(stor, entry.name) = @ptrCast(&@field(Provider, entry.name));
                }
            }

            return Self{ .vtable = stor };
        }

        /// Create a populated dynamic vtable in one call.
        ///
        /// Supported forms:
        /// - `create(Provider)` where Provider declares every entry in this vtable.
        /// - `create(.{ base_vtable, ExtraProvider })` where entries found in
        ///   `base_vtable` are inherited and only newly-added entries must be
        ///   declared by `ExtraProvider`.
        pub fn create(comptime provider_or_pair: anytype) Self {
            const PairType = @TypeOf(provider_or_pair);
            const pair_info = @typeInfo(PairType);

            if (pair_info == .@"struct" and pair_info.@"struct".is_tuple and pair_info.@"struct".fields.len == 2) {
                return createFromBase(provider_or_pair[0], provider_or_pair[1]);
            }

            var self: Self = undefined;
            self.populate(provider_or_pair);
            return self;
        }

        /// Create a new vtable type by appending additional entries.
        ///
        /// This enables additive interface evolution while preserving older
        /// subset interfaces. Existing entry names may not be redefined.
        pub fn Extend(comptime extra_entries: []const VTableEntry) type {
            return DynamicVTable(mergeEntries(entries, extra_entries));
        }

        // ── lookup ────────────────────────────────────────────────────────

        /// Return the typed function pointer for `name`.
        /// Compile error if `name` is not declared in this vtable.
        pub fn get(self: Self, comptime name: [:0]const u8) blk: {
            for (entries) |e| {
                if (std.mem.eql(u8, e.name, name)) break :blk *const e.Fn;
            }
            @compileError("DynamicVTable.get: no entry named '" ++ name ++ "'");
        } {
            return @field(self.vtable, name);
        }

        fn fnTypeForName(comptime name: [:0]const u8) type {
            for (entries) |e| {
                if (std.mem.eql(u8, e.name, name)) return e.Fn;
            }
            @compileError("DynamicVTable.call: no entry named '" ++ name ++ "'");
        }

        pub inline fn call(self: Self, provider: anytype, comptime name: [:0]const u8, args: anytype) blk: {
            const FnType = fnTypeForName(name);
            break :blk @typeInfo(FnType).@"fn".return_type orelse void;
        } {
            const FnPtr = self.get(name);
            const FnType = fnTypeForName(name);
            const fn_info = @typeInfo(FnType).@"fn";
            const ArgsType = @TypeOf(args);
            const args_info = @typeInfo(ArgsType);

            if (fn_info.params.len == 0) {
                if (args_info == .@"struct" and args_info.@"struct".is_tuple) {
                    return @call(.auto, FnPtr, args);
                }
                return @call(.auto, FnPtr, .{args});
            }

            const self_param = fn_info.params[0].type orelse {
                @compileError("DynamicVTable.call: first parameter for '" ++ name ++ "' must be concrete");
            };

            const erased_self = @as(self_param, @ptrCast(provider));

            if (args_info == .@"struct" and args_info.@"struct".is_tuple) {
                return @call(.auto, FnPtr, .{erased_self} ++ args);
            }

            return @call(.auto, FnPtr, .{ erased_self, args });
        }

        // ── subset / projection ───────────────────────────────────────────

        /// Returns `true` at compile time if every entry in `OtherVTable`
        /// is also declared in this vtable with the same function type.
        pub fn containsAll(comptime OtherVTable: type) bool {
            inline for (OtherVTable.fn_entries) |needed| {
                const found = comptime inner: {
                    for (entries) |have| {
                        if (std.mem.eql(u8, have.name, needed.name)) {
                            break :inner have.Fn == needed.Fn;
                        }
                    }
                    break :inner false;
                };
                if (!found) return false;
            }
            return true;
        }

        /// Derive a subset vtable type containing only the named entries.
        ///
        /// Each name must appear in `fn_entries`; compile error otherwise.
        /// The resulting type reuses the exact `Fn` types from the originals.
        pub fn Subset(comptime names: []const [:0]const u8) type {
            comptime {
                var subset: []const VTableEntry = &.{};
                for (names) |name| {
                    var found = false;
                    for (entries) |entry| {
                        if (std.mem.eql(u8, entry.name, name)) {
                            subset = subset ++ &[_]VTableEntry{entry};
                            found = true;
                            break;
                        }
                    }
                    if (!found) {
                        @compileError("DynamicVTable.Subset: no entry named '" ++ name ++ "'");
                    }
                }
                return DynamicVTable(subset);
            }
        }

        /// Project this vtable instance to `SubsetVTable`.
        ///
        /// All entries in `SubsetVTable` must be present in this vtable.
        pub fn projectTo(self: Self, comptime SubsetVTable: type) SubsetVTable {
            comptime if (!containsAll(SubsetVTable)) {
                @compileError("DynamicVTable.projectTo: SubsetVTable has entries not present in this vtable");
            };
            var sub_stor: SubsetVTable.VTable = undefined;
            inline for (SubsetVTable.fn_entries) |entry| {
                @field(sub_stor, entry.name) = @field(self.vtable, entry.name);
            }
            return SubsetVTable{ .vtable = sub_stor };
        }

        /// Project to the subset identified by `names` in a single step.
        ///
        /// Equivalent to `self.projectTo(Self.Subset(names))`.
        pub fn projectToSubset(self: Self, comptime names: []const [:0]const u8) Subset(names) {
            return self.projectTo(Subset(names));
        }
    };
}

// ── tests ──────────────────────────────────────────────────────────────────

test "DynamicVTable - fromImpl and direct call" {
    const VT = DynamicVTable(&.{
        .{ .name = "draw", .Fn = fn (*anyopaque) void },
    });

    const Sprite = struct {
        called: bool = false,
        pub fn draw(self: *@This()) void {
            self.called = true;
        }
    };

    var vt: VT = undefined;
    vt.populate(Sprite);
    var sprite = Sprite{};
    vt.vtable.draw(@ptrCast(&sprite));
    try std.testing.expect(sprite.called);
}

test "DynamicVTable - get returns typed fn pointer" {
    const VT = DynamicVTable(&.{
        .{ .name = "draw", .Fn = fn (*anyopaque) void },
        .{ .name = "update", .Fn = fn (*anyopaque, f32) void },
    });

    const Obj = struct {
        drawn: bool = false,
        x: f32 = 0,
        pub fn draw(self: *@This()) void {
            self.drawn = true;
        }
        pub fn update(self: *@This(), dt: f32) void {
            self.x += dt;
        }
    };

    const vt = VT.create(Obj);
    var obj = Obj{};

    vt.get("draw")(@ptrCast(&obj));
    try std.testing.expect(obj.drawn);

    vt.get("update")(@ptrCast(&obj), 0.016);
    try std.testing.expectApproxEqAbs(0.016, obj.x, 0.0001);
}

test "DynamicVTable - call injects self pointer" {
    const VT = DynamicVTable(&.{
        .{ .name = "set", .Fn = fn (*anyopaque, u32) void },
    });

    const Obj = struct {
        value: u32 = 0,
        pub fn set(self: *@This(), value: u32) void {
            self.value = value;
        }
    };

    const vt = VT.create(Obj);
    var obj = Obj{};
    vt.call(&obj, "set", .{@as(u32, 99)});
    try std.testing.expectEqual(@as(u32, 99), obj.value);
}

test "DynamicVTable - projectTo subset" {
    const FullVT = DynamicVTable(&.{
        .{ .name = "draw", .Fn = fn (*anyopaque) void },
        .{ .name = "update", .Fn = fn (*anyopaque, f32) void },
        .{ .name = "destroy", .Fn = fn (*anyopaque) void },
    });

    const DrawVT = DynamicVTable(&.{
        .{ .name = "draw", .Fn = fn (*anyopaque) void },
    });

    const Obj = struct {
        drawn: bool = false,
        updated: bool = false,
        destroyed: bool = false,
        pub fn draw(self: *@This()) void {
            self.drawn = true;
        }
        pub fn update(self: *@This(), _: f32) void {
            self.updated = true;
        }
        pub fn destroy(self: *@This()) void {
            self.destroyed = true;
        }
    };

    const full_vt = FullVT.create(Obj);
    const draw_vt = full_vt.projectTo(DrawVT);

    var obj = Obj{};
    draw_vt.vtable.draw(@ptrCast(&obj));
    try std.testing.expect(obj.drawn);
    try std.testing.expect(!obj.updated);
    try std.testing.expect(!obj.destroyed);
}

test "DynamicVTable - Subset type and projectToSubset" {
    const FullVT = DynamicVTable(&.{
        .{ .name = "draw", .Fn = fn (*anyopaque) void },
        .{ .name = "update", .Fn = fn (*anyopaque, f32) void },
        .{ .name = "destroy", .Fn = fn (*anyopaque) void },
    });

    const Obj = struct {
        drawn: bool = false,
        updated: bool = false,
        pub fn draw(self: *@This()) void {
            self.drawn = true;
        }
        pub fn update(self: *@This(), _: f32) void {
            self.updated = true;
        }
        pub fn destroy(_: *@This()) void {}
    };

    const full_vt = FullVT.create(Obj);
    const subset_vt = full_vt.projectToSubset(&.{ "draw", "update" });

    var obj = Obj{};
    subset_vt.vtable.draw(@ptrCast(&obj));
    subset_vt.vtable.update(@ptrCast(&obj), 1.0);
    try std.testing.expect(obj.drawn);
    try std.testing.expect(obj.updated);
}

test "DynamicVTable - containsAll" {
    const FullVT = DynamicVTable(&.{
        .{ .name = "draw", .Fn = fn (*anyopaque) void },
        .{ .name = "update", .Fn = fn (*anyopaque, f32) void },
        .{ .name = "destroy", .Fn = fn (*anyopaque) void },
    });

    const DrawVT = DynamicVTable(&.{
        .{ .name = "draw", .Fn = fn (*anyopaque) void },
    });

    const ExtraVT = DynamicVTable(&.{
        .{ .name = "serialize", .Fn = fn (*anyopaque) void },
    });

    try std.testing.expect(FullVT.containsAll(DrawVT));
    try std.testing.expect(!FullVT.containsAll(ExtraVT));
}

test "DynamicVTable - containsAll requires matching Fn type" {
    const VT1 = DynamicVTable(&.{
        .{ .name = "draw", .Fn = fn (*anyopaque) void },
    });

    const VT2 = DynamicVTable(&.{
        .{ .name = "draw", .Fn = fn (*anyopaque, f32) void },
    });

    try std.testing.expect(!VT1.containsAll(VT2));
}

test "DynamicVTable - Extend preserves legacy subset interfaces" {
    const BaseVT = DynamicVTable(&.{
        .{ .name = "draw", .Fn = fn (*anyopaque) void },
        .{ .name = "update", .Fn = fn (*anyopaque, f32) void },
    });

    const ExtendedVT = BaseVT.Extend(&.{
        .{ .name = "destroy", .Fn = fn (*anyopaque) void },
    });

    const LegacyDrawVT = BaseVT.Subset(&.{"draw"});

    const Obj = struct {
        drawn: bool = false,
        destroyed: bool = false,
        pub fn draw(self: *@This()) void {
            self.drawn = true;
        }
        pub fn update(_: *@This(), _: f32) void {}
        pub fn destroy(self: *@This()) void {
            self.destroyed = true;
        }
    };

    const extended_vt = ExtendedVT.create(Obj);
    const legacy_draw_vt = extended_vt.projectTo(LegacyDrawVT);

    var obj = Obj{};
    legacy_draw_vt.vtable.draw(@ptrCast(&obj));
    try std.testing.expect(obj.drawn);
    obj.drawn = false;
    extended_vt.vtable.draw(@ptrCast(&obj));
    try std.testing.expect(obj.drawn);
    extended_vt.vtable.destroy(@ptrCast(&obj));
    try std.testing.expect(obj.destroyed);
}

test "DynamicVTable - const self pointer" {
    const VT = DynamicVTable(&.{
        .{ .name = "read", .Fn = fn (*const anyopaque) u32 },
    });

    const Buffer = struct {
        value: u32 = 42,
        pub fn read(self: *const @This()) u32 {
            return self.value;
        }
    };

    const vt = VT.create(Buffer);
    const buf = Buffer{};
    const result = vt.vtable.read(@ptrCast(&buf));
    try std.testing.expectEqual(@as(u32, 42), result);
}

test "DynamicVTable - Subset preserves Fn types" {
    const FullVT = DynamicVTable(&.{
        .{ .name = "draw", .Fn = fn (*anyopaque) void },
        .{ .name = "update", .Fn = fn (*anyopaque, f32) void },
    });

    const DrawSubset = FullVT.Subset(&.{"draw"});

    // Subset should only contain the "draw" entry
    try std.testing.expectEqual(1, DrawSubset.fn_entries.len);
    try std.testing.expectEqualStrings("draw", DrawSubset.fn_entries[0].name);
    try std.testing.expect(DrawSubset.fn_entries[0].Fn == fn (*anyopaque) void);
}

test "DynamicVTable - swap vtable at runtime" {
    // Demonstrates swapping which vtable is active for a given ptr
    const VT = DynamicVTable(&.{
        .{ .name = "tick", .Fn = fn (*anyopaque) void },
    });

    const A = struct {
        ticked: bool = false,
        pub fn tick(self: *@This()) void {
            self.ticked = true;
        }
    };

    const B = struct {
        ticked: bool = false,
        pub fn tick(self: *@This()) void {
            self.ticked = true;
        }
    };

    const vt_a = VT.create(A);
    const vt_b = VT.create(B);

    var a = A{};
    var b = B{};

    // Use vt_a to drive `a`, then swap to vt_b for `b`
    var active = vt_a;
    active.vtable.tick(@ptrCast(&a));
    active = vt_b;
    active.vtable.tick(@ptrCast(&b));

    try std.testing.expect(a.ticked);
    try std.testing.expect(b.ticked);
}
