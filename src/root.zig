//! zevy_reflect
//! https://github.com/captkirk88/zevy-reflect
//!
const std = @import("std");

const reflect = @import("reflect.zig");
const change = @import("change.zig");
const interf = @import("interface.zig");

// Code generation utilities
pub const codegen = struct {
    pub const mixin_generator = @import("codegen/mixin_generator.zig");
};

pub const templates = struct {
    pub const common = struct {
        const _common = @import("common_interfaces.zig");
        pub const Equal = _common.Equal;
        pub const Hashable = _common.Hashable;
        pub const Comparable = _common.Comparable;
    };
    pub const Template = interf.Template;
    pub const Templates = interf.Templates;
};

// Types
pub const ReflectInfo = reflect.ReflectInfo;
pub const TypeInfo = reflect.TypeInfo;
pub const FieldInfo = reflect.FieldInfo;
pub const FuncInfo = reflect.FuncInfo;
pub const ParamInfo = reflect.ParamInfo;
pub const ShallowTypeInfo = reflect.ShallowTypeInfo;

pub const Change = change.Change;

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
