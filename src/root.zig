//! zevy_reflect
//! A reflection and change detection library for Zig
//!
//! Provides runtime type information and change tracking for Zig types.
//!
//! Example:
//! ```zig
//! const reflect = @import("zevy_reflect");
//! const info = reflect.getTypeInfo(MyStruct);
//! if (reflect.hasField(MyStruct, "myField")) {
//!     const fieldType = reflect.getFieldType(MyStruct, "myField");
//! }
//! var changeable = reflect.Change(MyStruct).init(myStructInstance);
//! var data = changeable.get();
//! data.myField = 42;
//! if (changeable.isChanged()) {
//!     // process changes
//!     changeable.finish(); // update prior hash to current state
//! }
//! ```
const std = @import("std");

const reflect = @import("reflect.zig");
const change = @import("change.zig");
const impl = @import("impl.zig");

// Types
pub const ReflectInfo = reflect.ReflectInfo;
pub const TypeInfo = reflect.TypeInfo;
pub const FieldInfo = reflect.FieldInfo;
pub const FuncInfo = reflect.FuncInfo;
pub const ShallowTypeInfo = reflect.ShallowTypeInfo;

pub const Change = change.Change;

/// A utility to verify that a type implements a given interface (or trait in a way).
pub const Implements = impl.Implements;

// Funcs
pub const getTypeInfo = reflect.getTypeInfo;
pub const getReflectInfo = reflect.getInfo;
pub const getFieldType = reflect.getField;
pub const getFieldNames = reflect.getFields;
pub const hasField = reflect.hasField;
pub const hasFunc = reflect.hasFunc;
pub const hasFuncWithArgs = reflect.hasFuncWithArgs;
pub const verifyFuncWithArgs = reflect.verifyFuncWithArgs;
pub const hasStruct = reflect.hasStruct;
pub const hash = reflect.hash;
pub const typeHash = reflect.typeHash;
pub const getSimpleTypeName = reflect.getSimpleTypeName;

test {
    std.testing.refAllDeclsRecursive(@This());
}
