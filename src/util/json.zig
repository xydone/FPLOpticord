//! Workaround for `std.json.stringify(...)` writing floats as scientific notation
//!
//! https://github.com/ziglang/zig/pull/22971
//!
//! Credits to https://github.com/InKryption for the implementation
const std = @import("std");
pub fn decimalStringifier(value: anytype, options: std.json.StringifyOptions) DecimalStringifier(@TypeOf(value)) {
    return .{
        .value = value,
        .options = options,
    };
}

/// Caller is responsible for memory
pub fn jsonStringify(allocator: std.mem.Allocator, value: std.json.Value, options: std.json.StringifyOptions) ![]u8 {
    var list = std.ArrayList(u8).init(allocator);
    errdefer list.deinit();
    var jw = std.json.writeStream(list.writer(), .{ .whitespace = .indent_tab });
    defer jw.deinit();

    try decimalStringifier(value, options).jsonStringify(&jw);
    return list.toOwnedSlice();
}

pub fn DecimalStringifier(comptime T: type) type {
    return struct {
        value: T,
        options: std.json.StringifyOptions,
        const Self = @This();

        pub fn jsonStringify(self: Self, jw: anytype) !void {
            switch (@typeInfo(T)) {
                else => return std.json.stringify(self.value, self.options, jw),

                .float,
                .comptime_float,
                => {
                    if (@as(f64, @floatCast(self.value)) == self.value) {
                        try jw.print("{d}", .{self.value});
                        return;
                    }
                    try jw.print("\"{d}\"", .{self.value});
                    return;
                },

                .optional => {
                    if (self.value) |payload| {
                        try decimalStringifier(payload, self.options).jsonStringify(jw);
                    } else {
                        try jw.write(null);
                    }
                    return;
                },

                .@"union" => |info| {
                    if (@hasDecl(T, "jsonStringify")) {
                        return self.value.jsonStringify(jw);
                    }

                    if (info.tag_type == null) @compileError("Unable to stringify untagged union '" ++ @typeName(T) ++ "'");
                    try jw.beginObject();
                    switch (self.value) {
                        inline else => |payload, tag| {
                            try jw.objectField(@tagName(tag));
                            if (@TypeOf(payload) == void) {
                                try jw.beginObject();
                                try jw.endObject();
                            } else {
                                try decimalStringifier(payload, self.options).jsonStringify(jw);
                            }
                        },
                    }
                    try jw.endObject();
                    return;
                },

                .@"struct" => |info| {
                    if (@hasDecl(T, "jsonStringify")) {
                        return self.value.jsonStringify(jw);
                    }

                    if (info.is_tuple) {
                        try jw.beginArray();
                    } else {
                        try jw.beginObject();
                    }

                    inline for (info.fields) |field| {
                        if (field.type == void) continue;
                        var emit_field = true;

                        // don't include optional fields that are null when emit_null_optional_fields is set to false
                        if (@typeInfo(field.type) == .optional) {
                            if (self.options.emit_null_optional_fields == false) {
                                if (@field(self.value, field.name) == null) {
                                    emit_field = false;
                                }
                            }
                        }

                        if (emit_field) {
                            if (!info.is_tuple) {
                                try jw.objectField(field.name);
                            }
                            try decimalStringifier(@field(self.value, field.name), self.options).jsonStringify(jw);
                        }
                    }

                    if (info.is_tuple) {
                        try jw.endArray();
                    } else {
                        try jw.endObject();
                    }

                    return;
                },

                .pointer => |ptr_info| switch (ptr_info.size) {
                    .one => switch (@typeInfo(ptr_info.child)) {
                        .array => {
                            try decimalStringifier(@as([]const ptr_info.child, self.value), self.options).jsonStringify(jw);
                            return;
                        },
                        else => {
                            try decimalStringifier(self.value.*, self.options).jsonStringify(jw);
                            return;
                        },
                    },
                    .many, .slice => {
                        if (ptr_info.size == .many and ptr_info.sentinel() == null)
                            @compileError("unable to stringify type '" ++ @typeName(T) ++ "' without sentinel");
                        const slice = if (ptr_info.size == .many) std.mem.span(self.value) else self.value;

                        if (ptr_info.child == u8) {
                            try std.json.stringify(self.value, self.options, jw);
                            return;
                        }

                        try jw.beginArray();
                        for (slice) |elem| try decimalStringifier(elem, self.options).jsonStringify(jw);
                        try jw.endArray();
                        return;
                    },
                },

                .array => {
                    try decimalStringifier(&self.value, self.options).jsonStringify(jw);
                    return;
                },

                .vector => |info| {
                    const array: [info.len]info.child = self.value;
                    try decimalStringifier(&array, self.options).jsonStringify(jw);
                    return;
                },
            }
            unreachable;
        }
    };
}
