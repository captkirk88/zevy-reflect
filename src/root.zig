//! zevy_reflect
//! https://github.com/captkirk88/zevy-reflect
//!
const std = @import("std");

const reflect = @import("reflect.zig");
const change = @import("change.zig");
const impl = @import("impl.zig");

// Code generation utilities
pub const codegen = struct {
    pub const mixin_generator = @import("codegen/mixin_generator.zig");
};

// Types
pub const ReflectInfo = reflect.ReflectInfo;
pub const TypeInfo = reflect.TypeInfo;
pub const FieldInfo = reflect.FieldInfo;
pub const FuncInfo = reflect.FuncInfo;
pub const ParamInfo = reflect.ParamInfo;
pub const ShallowTypeInfo = reflect.ShallowTypeInfo;

pub const Change = change.Change;

pub const Interface = impl.Interface;

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
pub const hashWithSeed = reflect.hashWithSeed;
pub const typeHash = reflect.typeHash;
pub const getSimpleTypeName = reflect.getSimpleTypeName;

test {
    std.testing.refAllDeclsRecursive(@This());
}
