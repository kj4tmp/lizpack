const std = @import("std");
const assert = std.debug.assert;
const cast = std.math.cast;

pub const Spec = @import("Specification.zig");

pub fn EncodeError(comptime T: type) type {
    if (containsSlice(T)) {
        return error{
            NoSpaceLeft,
            /// MessagePack only supports up to 32 bit lengths of arrays.
            /// If usize is 32 bits or smaller, this is unreachable.
            SliceLenTooLarge,
        };
    } else {
        return error{NoSpaceLeft};
    }
}

pub fn EncodeOptions(comptime T: type) type {
    return struct {
        format: FormatOptions(T) = FormatOptionsDefault(T),
    };
}

/// Encode the value to MessagePack bytes with format customizations.
pub fn encode(value: anytype, out: []u8, options: EncodeOptions(@TypeOf(value))) EncodeError(@TypeOf(value))![]u8 {
    var fbs = std.io.fixedBufferStream(out);
    try encodeAny(value, fbs.writer(), fbs.seekableStream(), options.format);
    if (comptime !containsSlice(@TypeOf(value))) {
        assert(largestEncodedSize(@TypeOf(value), options.format) >= fbs.getWritten().len);
    }
    return fbs.getWritten();
}

/// Encode the value to MessagePack bytes in a bounded array.
/// Unbounded size types (slices) are not supported.
/// No errors though!
pub fn encodeBounded(value: anytype, comptime options: EncodeOptions(@TypeOf(value))) std.BoundedArray(u8, largestEncodedSize(@TypeOf(value), options.format)) {
    var res = std.BoundedArray(u8, largestEncodedSize(@TypeOf(value), options.format)){};
    var fbs = std.io.fixedBufferStream(res.buffer[0..]);
    encodeAny(value, fbs.writer(), fbs.seekableStream(), options.format) catch unreachable;
    res.len = fbs.getWritten().len;
    return res;
}

pub fn DecodeOptions(comptime T: type) type {
    return struct {
        format: FormatOptions(T) = FormatOptionsDefault(T),
    };
}

/// Decode from MessagePack bytes to stack allocated value with format customizations.
pub fn decode(comptime T: type, in: []const u8, options: DecodeOptions(T)) error{Invalid}!T {
    var fbs = std.io.fixedBufferStream(in);
    const res = decodeAny(T, fbs.reader(), fbs.seekableStream(), null, options.format) catch return error.Invalid;
    if (fbs.pos != fbs.buffer.len) return error.Invalid;
    return res;
}

/// Call deinit() on this to free it.
pub fn Decoded(comptime T: type) type {
    return struct {
        arena: *std.heap.ArenaAllocator,
        value: T,
        pub fn deinit(self: @This()) void {
            const allocator = self.arena.child_allocator;
            self.arena.deinit();
            allocator.destroy(self.arena);
        }
    };
}

/// Decode from MessagePack bytes using an allocator. Allocator is required for
/// pointer types (slices, pointers, etc.)
pub fn decodeAlloc(allocator: std.mem.Allocator, comptime T: type, in: []const u8, options: DecodeOptions(T)) error{ OutOfMemory, Invalid }!Decoded(T) {
    var fbs = std.io.fixedBufferStream(in);
    const arena = try allocator.create(std.heap.ArenaAllocator);
    errdefer allocator.destroy(arena);
    arena.* = .init(allocator);
    errdefer arena.deinit();
    const res = decodeAny(T, fbs.reader(), fbs.seekableStream(), arena.allocator(), options.format) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Invalid => return error.Invalid,
        error.EndOfStream => return error.Invalid,
    };
    if (fbs.pos != fbs.buffer.len) return error.Invalid;
    return Decoded(T){ .arena = arena, .value = res };
}

/// Returns longest possible length of MessagePack encoding for type T.
/// Raises compile error for unbounded types (slices).
pub fn largestEncodedSize(comptime T: type, format_options: FormatOptions(T)) usize {
    return switch (@typeInfo(T)) {
        .bool => 1, // see Spec, bools are one byte
        .int => switch (@typeInfo(T).int.signedness) {
            .unsigned => switch (@typeInfo(T).int.bits) {
                0...7 => 1, // pos fix int
                8 => 2, // uint 8
                9...16 => 3, // uint 16
                17...32 => 5, // uint 32
                33...64 => 9, // uint 64
                else => unreachable, // message pack supports only up to 64 bit ints
            },
            .signed => switch (@typeInfo(T).int.bits) {
                0...8 => 2, // int 8 TODO: optimize using pos/neg fix int?
                9...16 => 3, // int 16,
                17...32 => 5, // int 32
                33...64 => 9, // int 64
                else => unreachable, // message pack supports only up to 64 bit ints
            },
        },
        .float => switch (@typeInfo(T).float.bits) {
            32 => 5, // f32
            64 => 9, // f64
            else => unreachable, // message pack supports only 32 and 64 bit floats
        },
        .array, .vector => blk: {
            const len = switch (@typeInfo(T)) {
                .array => @typeInfo(T).array.len,
                .vector => @typeInfo(T).vector.len,
                else => unreachable,
            };
            break :blk switch (std.meta.Child(T)) {
                u8 => switch (format_options) {
                    .bin, .str => 5 + len, // TODO: don't assume bin_32 and str_32
                    .array => 5 + 2 * len, // TODO: don't assume array_32
                },
                else => 5 + len * largestEncodedSize(std.meta.Child(T), format_options),
            };
        },
        .optional => largestEncodedSize(@typeInfo(T).optional.child, format_options),
        .@"struct" => switch (format_options.layout) {
            .map => blk: {
                var size: usize = 5; // TODO: don't assume map_32
                inline for (comptime std.meta.fields(T), comptime std.meta.fields(@TypeOf(format_options.fields))) |field, field_option| {
                    size += 5 + field.name.len; // TODO: don't assume str_32
                    size += largestEncodedSize(field.type, @field(format_options.fields, field_option.name));
                }
                break :blk size;
            },
            .array => blk: {
                var size: usize = 5; // TODO: don't assume array_32
                inline for (comptime std.meta.fields(T), comptime std.meta.fields(@TypeOf(format_options.fields))) |field, field_option| {
                    size += largestEncodedSize(field.type, @field(format_options.fields, field_option.name));
                }
                break :blk size;
            },
        },
        .@"enum" => switch (format_options) {
            .str => blk: {
                comptime assert(@typeInfo(T).@"enum".is_exhaustive); // TODO: only exhaustive enums supported
                break :blk 5 + largestFieldNameLength(T); // TODO: don't assume str_32
            },
            .int => blk: {
                const TagInt = @typeInfo(T).@"enum".tag_type;
                break :blk largestEncodedSize(TagInt, void{});
            },
        },
        .@"union" => switch (format_options.layout) {
            .map => blk: {
                const size: usize = 1; // assumes fixmap
                var largest_field_size: usize = 0;
                inline for (std.meta.fields(T), std.meta.fields(@TypeOf(format_options.fields))) |field, field_option| {
                    const field_size: usize = 5 + field.name.len + largestEncodedSize(field.type, @field(format_options.fields, field_option.name)); // TODO: don't assume str_32
                    if (field_size > largest_field_size) {
                        largest_field_size = field_size;
                    }
                }
                break :blk size + largest_field_size;
            },
            .active_field => blk: {
                var largest_field_size: usize = 0;
                inline for (std.meta.fields(T), std.meta.fields(@TypeOf(format_options.fields))) |field, field_option| {
                    const field_size = 5 + field.name.len + largestEncodedSize(field.type, @field(format_options.fields, field_option.name)); // TODO: don't assume str_32
                    if (field_size > largest_field_size) {
                        largest_field_size = field_size;
                    }
                }
                break :blk largest_field_size;
            },
        },
        .pointer => switch (@typeInfo(T).pointer.size) {
            .One => largestEncodedSize(@typeInfo(T).pointer.child),
            else => @compileError("type: " ++ @typeName(T) ++ " not supported."),
        },
        else => @compileError("type: " ++ @typeName(T) ++ " not supported."),
    };
}

test "encode bounded" {
    const expected: struct { foo: u8, bar: ?u16 } = .{ .foo = 12, .bar = null };
    const slice = encodeBounded(expected, .{}).slice();
    try std.testing.expectEqual(expected, decode(@TypeOf(expected), slice, .{}));
}

test "byte stream too long returns error" {
    try std.testing.expectError(error.Invalid, decode(bool, &.{ 0xc3, 0x00 }, .{}));
}

fn containsSlice(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .bool => false,
        .int => false,
        .float => false,
        .array => false,
        .optional => containsSlice(@typeInfo(T).optional.child),
        .vector => false,
        .@"struct" => blk: inline for (@typeInfo(T).@"struct".fields) |field| {
            if (containsSlice(field.type)) break :blk true;
        } else break :blk false,
        .@"enum" => false,
        .@"union" => blk: inline for (@typeInfo(T).@"union".fields) |field| {
            if (containsSlice(field.type)) break :blk true;
        } else break :blk false,
        .pointer => switch (@typeInfo(T).pointer.size) {
            .One => containsSlice(@typeInfo(T).pointer.child),
            .Slice => true,
            else => @compileError("type: " ++ @typeName(T) ++ " not supported."),
        },
        else => @compileError("type: " ++ @typeName(T) ++ " not supported."),
    };
}

fn encodeAny(value: anytype, writer: anytype, seeker: anytype, format_options: anytype) !void {
    const T = @TypeOf(value);
    switch (@typeInfo(T)) {
        .bool => return try encodeBool(value, writer),
        .int => return try encodeInt(value, writer),
        .float => return try encodeFloat(value, writer),
        .array => return try encodeArray(value, writer, seeker, format_options),
        .optional => return try encodeOptional(value, writer, seeker, format_options),
        .vector => return try encodeVector(value, writer, seeker, format_options),
        .@"struct" => return try encodeStruct(value, writer, seeker, format_options),
        .@"enum" => return try encodeEnum(value, writer, format_options),
        .@"union" => return try encodeUnion(value, writer, seeker, format_options),
        .pointer => return try encodePointer(value, writer, seeker, format_options),
        else => @compileError("type: " ++ @typeName(T) ++ " not supported."),
    }
    unreachable;
}

fn encodePointer(value: anytype, writer: anytype, seeker: anytype, format_options: anytype) !void {
    switch (@typeInfo(@TypeOf(value)).pointer.size) {
        .One => try encodeAny(value.*, writer, seeker, format_options),
        .Slice => try encodeSlice(value, writer, seeker, format_options),
        else => @compileError("unsupported type " ++ @typeName(@TypeOf(value))),
    }
}

fn encodeSlice(value: anytype, writer: anytype, seeker: anytype, format_options: anytype) !void {
    const has_sentinel = @typeInfo(@TypeOf(value)).pointer.sentinel != null;
    const encoded_len = value.len + @as(comptime_int, @intFromBool(has_sentinel));
    const Child = @typeInfo(@TypeOf(value)).pointer.child;

    const format: Spec.Format = switch (Child) {
        u8 => switch (format_options) {
            .bin => switch (encoded_len) {
                0...std.math.maxInt(u8) => .{ .bin_8 = {} },
                std.math.maxInt(u8) + 1...std.math.maxInt(u16) => .{ .bin_16 = {} },
                std.math.maxInt(u16) + 1...std.math.maxInt(u32) => .{ .bin_32 = {} },
                else => return error.SliceLenTooLarge,
            },
            .str => switch (encoded_len) {
                0...std.math.maxInt(u5) => .{ .fixstr = .{ .len = @intCast(encoded_len) } },
                std.math.maxInt(u5) + 1...std.math.maxInt(u8) => .{ .str_8 = {} },
                std.math.maxInt(u8) + 1...std.math.maxInt(u16) => .{ .str_16 = {} },
                std.math.maxInt(u16) + 1...std.math.maxInt(u32) => .{ .str_32 = {} },
                else => return error.SliceLenTooLarge,
            },
            .array => switch (encoded_len) {
                0...std.math.maxInt(u4) => .{ .fixarray = .{ .len = @intCast(encoded_len) } },
                std.math.maxInt(u4) + 1...std.math.maxInt(u16) => .{ .array_16 = {} },
                std.math.maxInt(u16) + 1...std.math.maxInt(u32) => .{ .array_32 = {} },
                else => return error.SliceLenTooLarge,
            },
        },
        else => switch (encoded_len) {
            0...std.math.maxInt(u4) => .{ .fixarray = .{ .len = @intCast(encoded_len) } },
            std.math.maxInt(u4) + 1...std.math.maxInt(u16) => .{ .array_16 = {} },
            std.math.maxInt(u16) + 1...std.math.maxInt(u32) => .{ .array_32 = {} },
            else => return error.SliceLenTooLarge,
        },
    };

    try writer.writeByte(format.encode());
    switch (format) {
        .fixarray, .fixstr => {},
        .bin_8, .str_8 => try writer.writeInt(u8, @intCast(encoded_len), .big),
        .bin_16, .str_16, .array_16 => try writer.writeInt(u16, @intCast(encoded_len), .big),
        .bin_32, .str_32, .array_32 => try writer.writeInt(u32, @intCast(encoded_len), .big),
        else => unreachable,
    }
    switch (format) {
        .fixstr,
        .str_8,
        .str_16,
        .str_32,
        .bin_8,
        .bin_16,
        .bin_32,
        => switch (Child) {
            u8 => {
                try writer.writeAll(value[0..]);
                if (@typeInfo(@TypeOf(value)).pointer.sentinel) |sentinel| {
                    const sentinel_value: Child = @as(*const Child, @ptrCast(sentinel)).*;
                    try writer.writeByte(sentinel_value);
                }
            },
            else => unreachable,
        },
        .fixarray, .array_16, .array_32 => {
            for (value) |value_child| {
                try encodeAny(value_child, writer, seeker, format_options);
            }
            if (@typeInfo(@TypeOf(value)).pointer.sentinel) |sentinel| {
                const sentinel_value: Child = @as(*const Child, @ptrCast(sentinel)).*;
                try encodeAny(sentinel_value, writer, seeker, format_options);
            }
        },
        else => unreachable,
    }
}

test "round trip slice" {
    var out: [64]u8 = undefined;
    const expected: []const bool = &.{ true, false, true };
    const slice = try encode(expected, &out, .{});
    const decoded = try decodeAlloc(std.testing.allocator, @TypeOf(expected), slice, .{});
    defer decoded.deinit();
    try std.testing.expectEqualSlices(bool, expected, decoded.value);
}

fn encodeUnion(value: anytype, writer: anytype, seeker: anytype, format_options: anytype) !void {
    comptime assert(@typeInfo(@TypeOf(value)).@"union".tag_type != null); // unions require a tag type
    switch (value) {
        inline else => |payload, tag| {
            switch (format_options.layout) {
                .map => {
                    try encodeMapFormat(1, writer);
                    try encodeStr(@tagName(tag), writer);
                },
                .active_field => {},
            }
            try encodeAny(payload, writer, seeker, format_options);
        },
    }
}

test "round trip union" {
    var out: [1000]u8 = undefined;
    const expected: union(enum) { foo: u8, bar: u16 } = .{ .foo = 3 };
    const slice = try encode(expected, &out, .{});
    try std.testing.expectEqual(expected, decode(@TypeOf(expected), slice, .{}));
}

test "round trip union map" {
    var out: [1000]u8 = undefined;
    const expected: union(enum) { foo: u8, bar: u16, bazzz: u16 } = .{ .foo = 3 };
    const slice = try encode(expected, &out, .{ .format = .{ .layout = .map } });
    try std.testing.expectEqual(
        expected,
        decode(@TypeOf(expected), slice, .{ .format = .{ .layout = .map } }),
    );
}

fn encodeEnum(value: anytype, writer: anytype, format_options: anytype) !void {
    switch (format_options) {
        .int => {
            const TagInt = @typeInfo(@TypeOf(value)).@"enum".tag_type;
            const int: TagInt = @intFromEnum(value);
            try encodeInt(int, writer);
        },
        .str => {
            comptime assert(@typeInfo(@TypeOf(value)).@"enum".is_exhaustive); // TODO: only exhaustive enums supported
            // TODO: carefull, if you support non-exhaustive, change this for something that doesn't panic
            switch (value) {
                inline else => |tag| {
                    try encodeStr(@tagName(tag), writer);
                },
            }
        },
    }
}

test "round trip enum" {
    var out: [1000]u8 = undefined;
    const expected: enum { foo, bar } = .foo;
    const slice = try encode(expected, &out, .{});
    try std.testing.expectEqual(expected, decode(@TypeOf(expected), slice, .{}));
}

test "round trip str" {
    var out: [1000]u8 = undefined;
    const expected: enum { foo, bar } = .foo;
    const slice = try encode(expected, &out, .{ .format = .str });
    try std.testing.expectEqual(expected, decode(@TypeOf(expected), slice, .{ .format = .str }));
}

test "encode enum as str" {
    var out: [1000]u8 = undefined;
    const expected: enum { foo, bar } = .foo;
    const slice = try encode(expected, &out, .{ .format = .str });
    try std.testing.expectEqualSlices(u8, &.{ 0b10100011, 'f', 'o', 'o' }, slice);
}

fn encodeStruct(value: anytype, writer: anytype, seeker: anytype, format_options: anytype) !void {
    const num_struct_fields = @typeInfo(@TypeOf(value)).@"struct".fields.len;

    if (num_struct_fields == 0) return;

    assert(num_struct_fields > 0);
    switch (format_options.layout) {
        .map => {
            try encodeMapFormat(num_struct_fields, writer);
            inline for (comptime std.meta.fieldNames(@TypeOf(value)), comptime std.meta.fieldNames(@TypeOf(format_options.fields))) |field_name, format_option_field_name| {
                try encodeStr(field_name, writer);
                try encodeAny(@field(value, field_name), writer, seeker, @field(format_options.fields, format_option_field_name));
            }
        },
        .array => {
            try encodeArrayFormat(num_struct_fields, writer);
            inline for (comptime std.meta.fieldNames(@TypeOf(value)), comptime std.meta.fieldNames(@TypeOf(format_options.fields))) |field_name, format_option_field_name| {
                try encodeAny(@field(value, field_name), writer, seeker, @field(format_options.fields, format_option_field_name));
            }
        },
    }
}

test "round trip struct" {
    var out: [1000]u8 = undefined;
    const expected: struct { foo: u8, bar: ?u16 } = .{ .foo = 12, .bar = null };
    const slice = try encode(expected, &out, .{});
    try std.testing.expectEqual(expected, decode(@TypeOf(expected), slice, .{}));
}

test "round trip struct array" {
    var out: [1000]u8 = undefined;
    const expected: struct { foo: u8, bar: ?u16 } = .{ .foo = 12, .bar = null };
    const format: FormatOptions(@TypeOf(expected)) = .{ .layout = .array };
    const slice = try encode(expected, &out, .{ .format = format });
    try std.testing.expectEqual(expected, decode(@TypeOf(expected), slice, .{ .format = format }));
}

fn encodeArrayFormat(comptime len: comptime_int, writer: anytype) !void {
    const format: Spec.Format = switch (len) {
        0 => unreachable,
        1...std.math.maxInt(u4) => .{ .fixarray = .{ .len = @intCast(len) } },
        std.math.maxInt(u4) + 1...std.math.maxInt(u16) => .{ .array_16 = {} },
        std.math.maxInt(u16) + 1...std.math.maxInt(u32) => .{ .array_32 = {} },
        else => @compileError("MessagePack only supports up to u32 len arrays."),
    };
    try writer.writeByte(format.encode());
    switch (format) {
        .fixarray => {},
        .array_16 => try writer.writeInt(u16, @intCast(len), .big),
        .array_32 => try writer.writeInt(u32, @intCast(len), .big),
        else => unreachable,
    }
}

fn encodeMapFormat(comptime len: comptime_int, writer: anytype) !void {
    const format: Spec.Format = switch (len) {
        0 => unreachable,
        1...std.math.maxInt(u4) => .{ .fixmap = .{ .n_elements = @intCast(len) } },
        std.math.maxInt(u4) + 1...std.math.maxInt(u16) => .{ .map_16 = {} },
        std.math.maxInt(u16) + 1...std.math.maxInt(u32) => .{ .map_32 = {} },
        else => @compileError("MessagePack only supports up to u32 len arrays."),
    };
    try writer.writeByte(format.encode());
    switch (format) {
        .fixmap => {},
        .map_16 => try writer.writeInt(u16, @intCast(len), .big),
        .map_32 => try writer.writeInt(u32, @intCast(len), .big),
        else => unreachable,
    }
}

fn encodeStr(comptime str: []const u8, writer: anytype) !void {
    comptime assert(str.len <= std.math.maxInt(u32));
    const format: Spec.Format = switch (str.len) {
        0...std.math.maxInt(u5) => |len| .{ .fixstr = .{ .len = @intCast(len) } },
        std.math.maxInt(u5) + 1...std.math.maxInt(u8) => .{ .str_8 = {} },
        std.math.maxInt(u8) + 1...std.math.maxInt(u16) => .{ .str_16 = {} },
        std.math.maxInt(u16) + 1...std.math.maxInt(u32) => .{ .str_32 = {} },
        else => unreachable,
    };
    try writer.writeByte(format.encode());
    switch (format) {
        .fixstr => {},
        .str_8 => try writer.writeInt(u8, @intCast(str.len), .big),
        .str_16 => try writer.writeInt(u16, @intCast(str.len), .big),
        .str_32 => try writer.writeInt(u32, @intCast(str.len), .big),
        else => unreachable,
    }
    try writer.writeAll(str);
}

fn encodeVector(value: anytype, writer: anytype, seeker: anytype, format_options: anytype) !void {
    const encoded_len = @typeInfo(@TypeOf(value)).vector.len;
    const Child = @typeInfo(@TypeOf(value)).vector.child;
    const format: Spec.Format = switch (Child) {
        u8 => switch (format_options) {
            .bin => try encodeBinStrArrayFormat(encoded_len, .bin, writer),
            .str => try encodeBinStrArrayFormat(encoded_len, .str, writer),
            .array => try encodeBinStrArrayFormat(encoded_len, .array, writer),
        },
        else => try encodeBinStrArrayFormat(encoded_len, .array, writer),
    };
    switch (format) {
        .fixstr,
        .str_8,
        .str_16,
        .str_32,
        .bin_8,
        .bin_16,
        .bin_32,
        => switch (Child) {
            u8 => {
                for (0..encoded_len) |i| {
                    try writer.writeByte(value[i]);
                }
            },
            else => unreachable,
        },
        .fixarray, .array_16, .array_32 => {
            for (0..encoded_len) |i| {
                try encodeAny(value[i], writer, seeker, format_options);
            }
        },
        else => unreachable,
    }
}

test "round trip vector" {
    var out: [356]u8 = undefined;
    const expected: @Vector(56, u8) = @splat(34);
    const slice = try encode(expected, &out, .{});
    try std.testing.expectEqual(expected, decode(@TypeOf(expected), slice, .{}));
}

fn encodeOptional(value: anytype, writer: anytype, seeker: anytype, format_options: anytype) !void {
    if (value) |non_null| {
        try encodeAny(non_null, writer, seeker, format_options);
    } else {
        const format_byte = Spec.Format{ .nil = {} };
        try writer.writeByte(format_byte.encode());
    }
}

test "round trip optional" {
    var out: [64]u8 = undefined;
    const expected: ?f64 = null;
    const slice = try encode(expected, &out, .{});
    try std.testing.expectEqual(expected, decode(@TypeOf(expected), slice, .{}));
}

test "round trip optional 2" {
    var out: [64]u8 = undefined;
    const expected: ?f64 = 12.3;
    const slice = try encode(expected, &out, .{});
    try std.testing.expectEqual(expected, decode(@TypeOf(expected), slice, .{}));
}

fn encodeArray(value: anytype, writer: anytype, seeker: anytype, format_options: anytype) !void {
    const has_sentinel = @typeInfo(@TypeOf(value)).array.sentinel != null;
    const encoded_len = @typeInfo(@TypeOf(value)).array.len + @as(comptime_int, @intFromBool(has_sentinel));
    const Child = @typeInfo(@TypeOf(value)).array.child;

    const format: Spec.Format = switch (Child) {
        u8 => switch (format_options) {
            .bin => try encodeBinStrArrayFormat(encoded_len, .bin, writer),
            .str => try encodeBinStrArrayFormat(encoded_len, .str, writer),
            .array => try encodeBinStrArrayFormat(encoded_len, .array, writer),
        },
        else => try encodeBinStrArrayFormat(encoded_len, .array, writer),
    };
    switch (format) {
        .fixstr,
        .str_8,
        .str_16,
        .str_32,
        .bin_8,
        .bin_16,
        .bin_32,
        => switch (Child) {
            u8 => {
                try writer.writeAll(value[0..]);
                if (@typeInfo(@TypeOf(value)).array.sentinel) |sentinel| {
                    const sentinel_value: Child = @as(*const Child, @ptrCast(sentinel)).*;
                    try writer.writeByte(sentinel_value);
                }
            },
            else => unreachable,
        },
        .fixarray, .array_16, .array_32 => {
            for (value) |value_child| {
                try encodeAny(value_child, writer, seeker, format_options);
            }
            if (@typeInfo(@TypeOf(value)).array.sentinel) |sentinel| {
                const sentinel_value: Child = @as(*const Child, @ptrCast(sentinel)).*;
                try encodeAny(sentinel_value, writer, seeker, format_options);
            }
        },
        else => unreachable,
    }
}

fn encodeBinStrArrayFormat(len: comptime_int, family: enum { bin, str, array }, writer: anytype) !Spec.Format {
    const format: Spec.Format = switch (family) {
        .bin => switch (len) {
            0...std.math.maxInt(u8) => .{ .bin_8 = {} },
            std.math.maxInt(u8) + 1...std.math.maxInt(u16) => .{ .bin_16 = {} },
            std.math.maxInt(u16) + 1...std.math.maxInt(u32) => .{ .bin_32 = {} },
            else => @compileError("MessagePack only supports up to array length max u32."),
        },
        .str => switch (len) {
            0...std.math.maxInt(u5) => .{ .fixstr = .{ .len = @intCast(len) } },
            std.math.maxInt(u5) + 1...std.math.maxInt(u8) => .{ .str_8 = {} },
            std.math.maxInt(u8) + 1...std.math.maxInt(u16) => .{ .str_16 = {} },
            std.math.maxInt(u16) + 1...std.math.maxInt(u32) => .{ .str_32 = {} },
            else => @compileError("MessagePack only supports up to array length max u32."),
        },
        .array => switch (len) {
            0...std.math.maxInt(u4) => .{ .fixarray = .{ .len = @intCast(len) } },
            std.math.maxInt(u4) + 1...std.math.maxInt(u16) => .{ .array_16 = {} },
            std.math.maxInt(u16) + 1...std.math.maxInt(u32) => .{ .array_32 = {} },
            else => @compileError("MessagePack only supports up to array length max u32."),
        },
    };
    try writer.writeByte(format.encode());
    switch (format) {
        .fixarray, .fixstr => {},
        .bin_8, .str_8 => try writer.writeInt(u8, @intCast(len), .big),
        .bin_16, .str_16, .array_16 => try writer.writeInt(u16, @intCast(len), .big),
        .bin_32, .str_32, .array_32 => try writer.writeInt(u32, @intCast(len), .big),
        else => unreachable,
    }
    return format;
}

test "round trip array" {
    var out: [64]u8 = undefined;
    const expected: [3]bool = .{ true, false, true };
    const slice = try encode(expected, &out, .{});
    try std.testing.expectEqual(expected, decode(@TypeOf(expected), slice, .{}));
}

fn encodeFloat(value: anytype, writer: anytype) !void {
    const format: Spec.Format = switch (@typeInfo(@TypeOf(value)).float.bits) {
        32 => .{ .float_32 = {} },
        64 => .{ .float_64 = {} },
        else => @compileError("MessagePack only supports 32 or 64 bit floats."),
    };
    try writer.writeByte(format.encode());
    switch (format) {
        .float_32 => try writer.writeInt(u32, @bitCast(value), .big),
        .float_64 => try writer.writeInt(u64, @bitCast(value), .big),
        else => unreachable,
    }
}

test "round trip float 64" {
    var out: [64]u8 = undefined;
    const expected: f64 = 12.35;
    const slice = try encode(expected, &out, .{});
    try std.testing.expectEqual(expected, decode(@TypeOf(expected), slice, .{}));
}

test "round trip float 32" {
    var out: [64]u8 = undefined;
    const expected: f32 = 12.35;
    const slice = try encode(expected, &out, .{});
    try std.testing.expectEqual(expected, decode(@TypeOf(expected), slice, .{}));
}

// TODO: maybe re-think this and use the smallest possible representation
fn encodeInt(value: anytype, writer: anytype) !void {
    const T = @TypeOf(value);

    if (@typeInfo(T).int.bits > 64) @compileError("MessagePack only supports up to 64 bit integers.");

    const format: Spec.Format = switch (@typeInfo(T).int.signedness) {
        .unsigned => switch (@typeInfo(T).int.bits) {
            0...7 => .{ .positive_fixint = .{ .value = value } },
            8 => .{ .uint_8 = {} },
            9...16 => .{ .uint_16 = {} },
            17...32 => .{ .uint_32 = {} },
            33...64 => .{ .uint_64 = {} },
            else => unreachable,
        },
        .signed => switch (@typeInfo(T).int.bits) {
            0...6 => blk: {
                if (value >= 0) {
                    break :blk .{ .positive_fixint = .{ .value = @intCast(value) } };
                } else if (value >= -32) {
                    break :blk .{ .negative_fixint = .{ .value = value } };
                } else {
                    break :blk .{ .int_8 = {} };
                }
            },
            7...8 => .{ .int_8 = {} },
            9...16 => .{ .int_16 = {} },
            17...32 => .{ .int_32 = {} },
            33...64 => .{ .int_64 = {} },
            else => unreachable,
        },
    };
    try writer.writeByte(format.encode());
    switch (format) {
        .positive_fixint, .negative_fixint => {},
        .uint_8 => try writer.writeInt(u8, @intCast(value), .big),
        .uint_16 => try writer.writeInt(u16, @intCast(value), .big),
        .uint_32 => try writer.writeInt(u32, @intCast(value), .big),
        .uint_64 => try writer.writeInt(u64, @intCast(value), .big),
        .int_8 => try writer.writeInt(i8, @intCast(value), .big),
        .int_16 => try writer.writeInt(i16, @intCast(value), .big),
        .int_32 => try writer.writeInt(i32, @intCast(value), .big),
        .int_64 => try writer.writeInt(i64, @intCast(value), .big),
        else => unreachable,
    }
}

test "encode int" {
    var out1: [1]u8 = undefined;
    try std.testing.expectEqualSlices(u8, &.{0x00}, try encode(@as(u5, 0), &out1, .{}));
    try std.testing.expectEqualSlices(u8, &.{0xFF}, try encode(@as(i5, -1), &out1, .{}));
    try std.testing.expectEqualSlices(u8, &.{0xE0}, try encode(@as(i6, -32), &out1, .{}));
}

fn encodeBool(value: anytype, writer: anytype) !void {
    switch (value) {
        true => try writer.writeByte((Spec.Format{ .true = {} }).encode()),
        false => try writer.writeByte((Spec.Format{ .false = {} }).encode()),
    }
}

test "encode bool" {
    var out: [1]u8 = undefined;
    try std.testing.expectEqualSlices(u8, &.{0xc3}, try encode(true, &out, .{}));
    try std.testing.expectEqualSlices(u8, &.{0xc2}, try encode(false, &out, .{}));
}

test "roundtrip bool" {
    var out: [64]u8 = undefined;
    const expected = true;
    const slice = try encode(expected, &out, .{});
    try std.testing.expectEqual(expected, decode(@TypeOf(expected), slice, .{}));
}

fn decodeAny(comptime T: type, reader: anytype, seeker: anytype, maybe_alloc: anytype, format_options: anytype) !T {
    switch (@typeInfo(T)) {
        .bool => return try decodeBool(reader),
        .int => return try decodeInt(T, reader),
        .float => return try decodeFloat(T, reader),
        .array => return try decodeArray(T, reader, seeker, maybe_alloc, format_options),
        .optional => return try decodeOptional(T, reader, seeker, maybe_alloc, format_options),
        .vector => return try decodeVector(T, reader, seeker, maybe_alloc, format_options),
        .@"struct" => return try decodeStruct(T, reader, seeker, maybe_alloc, format_options),
        .@"enum" => return try decodeEnum(T, reader, format_options),
        .@"union" => return try decodeUnion(T, reader, seeker, maybe_alloc, format_options),
        .pointer => return try decodePointer(T, reader, seeker, maybe_alloc, format_options),

        else => @compileError("type: " ++ @typeName(T) ++ " not supported."),
    }
    unreachable;
}

fn decodePointer(comptime T: type, reader: anytype, seeker: anytype, alloc: anytype, format_options: anytype) !T {
    switch (@typeInfo(T).pointer.size) {
        .One => {
            const Child = @typeInfo(T).pointer.child;
            const res = try alloc.create(Child);
            errdefer alloc.destroy(res);
            res.* = try decodeAny(Child, reader, seeker, alloc, format_options);
            return res;
        },
        .Slice => return try decodeSlice(T, reader, seeker, alloc, format_options),
        else => @compileError("unsupported type " ++ @typeName(T)),
    }
}

test "decode pointer one" {
    const decoded = try decodeAlloc(std.testing.allocator, *bool, &.{0xc3}, .{});
    defer decoded.deinit();
    try std.testing.expectEqual(true, decoded.value.*);
}

fn decodeSlice(comptime T: type, reader: anytype, seeker: anytype, alloc: anytype, format_options: anytype) !T {
    const has_sentinel = @typeInfo(T).pointer.sentinel != null;
    const Child = @typeInfo(T).pointer.child;
    const format = Spec.Format.decode(try reader.readByte());
    if (Child == u8) {
        switch (format_options) {
            .bin => switch (format) {
                .bin_8, .bin_16, .bin_32 => {},
                else => return error.Invalid,
            },
            .str => switch (format) {
                .fixstr, .str_8, .str_16, .str_32 => {},
                else => return error.Invalid,
            },
            .array => switch (format) {
                .fixarray, .array_16, .array_32 => {},
                else => return error.Invalid,
            },
        }
    } else {
        switch (format) {
            .fixarray, .array_16, .array_32 => {},
            else => return error.Invalid,
        }
    }

    const len = switch (format) {
        .fixarray => |fmt| fmt.len,
        .array_16 => try reader.readInt(u16, .big),
        .array_32 => try reader.readInt(u32, .big),
        .fixstr => |fmt| fmt.len,
        .bin_8, .str_8 => try reader.readInt(u8, .big),
        .bin_16, .str_16 => try reader.readInt(u16, .big),
        .bin_32, .str_32 => try reader.readInt(u32, .big),
        else => unreachable,
    };
    if (len == 0 and has_sentinel) return error.Invalid;
    const res = switch (has_sentinel) {
        true => blk: {
            const sentinel_value: Child = @as(*const Child, @ptrCast(@typeInfo(T).pointer.sentinel.?)).*;
            break :blk try alloc.allocSentinel(Child, len - @as(comptime_int, @intFromBool(has_sentinel)), sentinel_value);
        },
        false => try alloc.alloc(Child, len),
    };
    errdefer alloc.free(res);

    const decode_len = len - @as(comptime_int, @intFromBool(has_sentinel));

    switch (Child) {
        u8 => switch (format) {
            .fixarray, .array_16, .array_32 => {
                for (0..decode_len) |i| {
                    res[i] = try decodeAny(Child, reader, seeker, alloc, format_options);
                }
            },
            .fixstr, .bin_8, .bin_16, .bin_32, .str_8, .str_16, .str_32 => {
                for (0..decode_len) |i| {
                    res[i] = try reader.readByte();
                }
                if (@typeInfo(T).pointer.sentinel) |sentinel| {
                    const sentinel_value: Child = @as(*const Child, @ptrCast(sentinel)).*;
                    if (try reader.readByte() != sentinel_value) return error.Invalid;
                }
            },
            else => unreachable,
        },
        else => switch (format) {
            .fixarray, .array_16, .array_32 => {
                for (0..decode_len) |i| {
                    res[i] = try decodeAny(Child, reader, seeker, alloc, format_options);
                }
                if (@typeInfo(T).pointer.sentinel) |sentinel| {
                    const sentinel_value: Child = @as(*const Child, @ptrCast(sentinel)).*;
                    if (try decodeAny(Child, reader, seeker, alloc, format_options) != sentinel_value) return error.Invalid;
                }
            },
            else => unreachable,
        },
    }
    return res;
}

test "decode slice bools" {
    const decoded = try decodeAlloc(std.testing.allocator, []bool, &.{ 0b10010011, 0xc3, 0xc2, 0xc3 }, .{});
    defer decoded.deinit();
    const expected: []const bool = &.{ true, false, true };
    try std.testing.expectEqualSlices(bool, expected, decoded.value);
}

test "decode slice str" {
    const decoded = try decodeAlloc(std.testing.allocator, []const u8, &.{ 0xd9, 0x03, 'f', 'o', 'o' }, .{ .format = .str });
    defer decoded.deinit();
    const expected: []const u8 = "foo";
    try std.testing.expectEqualSlices(u8, expected, decoded.value);
}

test "decode slice bin" {
    const decoded = try decodeAlloc(std.testing.allocator, []const u8, &.{ 0xc4, 0x03, 'f', 'o', 'o' }, .{ .format = .bin });
    defer decoded.deinit();
    const expected: []const u8 = "foo";
    try std.testing.expectEqualSlices(u8, expected, decoded.value);
}

test "decode slice fixstr" {
    const decoded = try decodeAlloc(std.testing.allocator, []const u8, &.{ 0b10100011, 'f', 'o', 'o' }, .{ .format = .str });
    defer decoded.deinit();
    const expected: []const u8 = "foo";
    try std.testing.expectEqualSlices(u8, expected, decoded.value);
}

test "decode slice invalid" {
    try std.testing.expectError(error.Invalid, decodeAlloc(std.testing.allocator, []const u8, &.{ 0b10100010, 'f', 'o', 'o' }, .{}));
}

test "decode slice sentinel invalid" {
    try std.testing.expectError(error.Invalid, decodeAlloc(std.testing.allocator, [:0]const u8, &.{ 0b10100100, 'f', 'o', 'o', 1 }, .{}));
}

test "decode slice sentinel" {
    const decoded = try decodeAlloc(std.testing.allocator, [:0]const u8, &.{ 0b10100100, 'f', 'o', 'o', 0 }, .{ .format = .str });
    defer decoded.deinit();
    const expected: [:0]const u8 = "foo";
    try std.testing.expectEqualSlices(u8, expected, decoded.value);
}

// TODO: refactor this to make it less garbage when inline for loops can have continue.
// https://github.com/ziglang/zig/issues/9524
fn decodeUnion(comptime T: type, reader: anytype, seeker: anytype, maybe_alloc: anytype, format_options: anytype) !T {
    comptime assert(@typeInfo(T).@"union".tag_type != null); // Unions require a tag type
    switch (format_options.layout) {
        .map => {
            const format_byte = try reader.readByte();
            if (format_byte != (Spec.Format{ .fixmap = .{ .n_elements = 1 } }).encode()) {
                return error.Invalid;
            }
            var field_name_buffer: [largestFieldNameLength(T)]u8 = undefined;
            const format_key = Spec.Format.decode(try reader.readByte());
            const name_len = switch (format_key) {
                .bin_8, .str_8 => try reader.readInt(u8, .big),
                .bin_16, .str_16 => try reader.readInt(u16, .big),
                .bin_32, .str_32 => try reader.readInt(u32, .big),
                .fixstr => |val| val.len,
                else => return error.Invalid,
            };
            if (name_len > largestFieldNameLength(T)) return error.Invalid;
            assert(name_len <= largestFieldNameLength(T));
            try reader.readNoEof(field_name_buffer[0..name_len]);

            inline for (comptime std.meta.fieldNames(T), comptime std.meta.fieldNames(@TypeOf(format_options.fields))) |field_name, format_option_field_name| {
                if (std.mem.eql(u8, field_name, field_name_buffer[0..name_len])) {
                    const field_value = try decodeAny(
                        @FieldType(T, field_name),
                        reader,
                        seeker,
                        maybe_alloc,
                        @field(format_options.fields, format_option_field_name),
                    );
                    return @unionInit(T, field_name, field_value);
                }
            } else {
                return error.Invalid;
            }
            unreachable;
        },
        .active_field => {
            const starting_position = try seeker.getPos();
            inline for (comptime std.meta.fields(T), comptime std.meta.fieldNames(@TypeOf(format_options.fields))) |union_field, union_field_format_name| inlinecont: {
                const res = decodeAny(union_field.type, reader, seeker, maybe_alloc, @field(format_options.fields, union_field_format_name)) catch |err| switch (err) {
                    error.Invalid, error.EndOfStream => {
                        try seeker.seekTo(starting_position);
                        break :inlinecont;
                    },
                };
                return @unionInit(T, union_field.name, res);
            } else {
                return error.Invalid;
            }
        },
    }
    unreachable;
}

test "decode union" {
    const MyUnion = union(enum) {
        my_u8: u8,
        my_bool: bool,
    };

    try std.testing.expectEqual(MyUnion{ .my_bool = false }, try decode(MyUnion, &.{0xc2}, .{ .format = .{ .layout = .active_field } }));
    try std.testing.expectEqual(MyUnion{ .my_u8 = 0 }, try decode(MyUnion, &.{0x00}, .{ .format = .{ .layout = .active_field } }));
    try std.testing.expectError(error.Invalid, decode(MyUnion, &.{0xc4}, .{ .format = .{ .layout = .active_field } }));
}

fn decodeEnum(comptime T: type, reader: anytype, format_options: anytype) !T {
    switch (format_options) {
        .int => {
            const TagInt = @typeInfo(T).@"enum".tag_type;
            const int: TagInt = try decodeInt(TagInt, reader);
            const res = std.meta.intToEnum(T, int) catch |err| switch (err) {
                error.InvalidEnumTag => return error.Invalid,
            };
            return res;
        },
        .str => {
            var field_name_buffer: [largestFieldNameLength(T)]u8 = undefined;
            const format_key = Spec.Format.decode(try reader.readByte());
            const name_len = switch (format_key) {
                .bin_8, .str_8 => try reader.readInt(u8, .big),
                .bin_16, .str_16 => try reader.readInt(u16, .big),
                .bin_32, .str_32 => try reader.readInt(u32, .big),
                .fixstr => |val| val.len,
                else => return error.Invalid,
            };
            if (name_len > largestFieldNameLength(T)) return error.Invalid;
            assert(name_len <= largestFieldNameLength(T));
            try reader.readNoEof(field_name_buffer[0..name_len]);

            inline for (comptime std.enums.values(T)) |enum_value| {
                if (std.mem.eql(u8, @tagName(enum_value), field_name_buffer[0..name_len])) {
                    return enum_value;
                }
            } else return error.Invalid;
        },
    }
}

test "decode enum" {
    const TestEnum = enum {
        foo,
        bar,
    };
    try std.testing.expectEqual(TestEnum.foo, decode(TestEnum, &.{0x00}, .{}));
    try std.testing.expectEqual(TestEnum.bar, decode(TestEnum, &.{0x01}, .{}));
}

test "decode enum str" {
    const TestEnum = enum {
        foo,
        bars,
    };
    try std.testing.expectEqual(TestEnum.foo, decode(TestEnum, &.{ 0b10100011, 'f', 'o', 'o' }, .{ .format = .str }));
    try std.testing.expectEqual(TestEnum.bars, decode(TestEnum, &.{ 0b10100100, 'b', 'a', 'r', 's' }, .{ .format = .str }));
    try std.testing.expectError(error.Invalid, decode(TestEnum, &.{ 0b10100101, 'b', 'a', 'z', 'z', 'z' }, .{ .format = .str }));
}

fn largestFieldNameLength(comptime T: type) comptime_int {
    const field_names = std.meta.fieldNames(T);
    if (field_names.len == 0) return 0;
    comptime var biggest_len = 0;
    for (field_names, 0..) |field_name, i| {
        if (i == 0) {
            biggest_len = field_name.len;
            continue;
        }
        if (field_name.len > biggest_len) {
            biggest_len = field_name.len;
        }
    }
    return biggest_len;
}

test "largest field name length" {
    const Foo = struct {
        bar: u8,
        bar2: u8,
    };
    try std.testing.expectEqual(4, largestFieldNameLength(Foo));
}

fn decodeStruct(comptime T: type, reader: anytype, seeker: anytype, maybe_alloc: anytype, format_options: anytype) !T {
    switch (format_options.layout) {
        .map => {
            const format = Spec.Format.decode(try reader.readByte());
            const num_struct_fields = @typeInfo(T).@"struct".fields.len;

            switch (format) {
                .fixmap => |fixmap| if (fixmap.n_elements != num_struct_fields) return error.Invalid,
                .map_16 => if (try reader.readInt(u16, .big) != num_struct_fields) return error.Invalid,
                .map_32 => if (try reader.readInt(u32, .big) != num_struct_fields) return error.Invalid,
                else => return error.Invalid,
            }

            if (num_struct_fields == 0) return T{};

            assert(num_struct_fields > 0);

            var got_field: [num_struct_fields]bool = @splat(false);
            var res: T = undefined;
            // TODO: yes is this O(n2) ... i don't care.
            for (0..num_struct_fields) |_| {
                var field_name_buffer: [largestFieldNameLength(T)]u8 = undefined;
                const format_key = Spec.Format.decode(try reader.readByte());
                const name_len = switch (format_key) {
                    .bin_8, .str_8 => try reader.readInt(u8, .big),
                    .bin_16, .str_16 => try reader.readInt(u16, .big),
                    .bin_32, .str_32 => try reader.readInt(u32, .big),
                    .fixstr => |val| val.len,
                    else => return error.Invalid,
                };
                if (name_len > largestFieldNameLength(T)) return error.Invalid;
                assert(name_len <= largestFieldNameLength(T));
                try reader.readNoEof(field_name_buffer[0..name_len]);
                inline for (comptime std.meta.fieldNames(T), 0.., comptime std.meta.fieldNames(@TypeOf(format_options.fields))) |field_name, i, format_option_field_name| {
                    if (std.mem.eql(u8, field_name, field_name_buffer[0..name_len])) {
                        @field(res, field_name) = try decodeAny(
                            @FieldType(T, field_name),
                            reader,
                            seeker,
                            maybe_alloc,
                            @field(format_options.fields, format_option_field_name),
                        );
                        got_field[i] = true;
                    }
                }
            }
            if (!std.mem.allEqual(bool, &got_field, true)) return error.Invalid;
            return res;
        },
        .array => {
            const format = Spec.Format.decode(try reader.readByte());
            const num_struct_fields = @typeInfo(T).@"struct".fields.len;

            switch (format) {
                .fixarray => |fixarray| if (fixarray.len != num_struct_fields) return error.Invalid,
                .array_16 => if (try reader.readInt(u16, .big) != num_struct_fields) return error.Invalid,
                .array_32 => if (try reader.readInt(u32, .big) != num_struct_fields) return error.Invalid,
                else => return error.Invalid,
            }

            if (num_struct_fields == 0) return T{};

            assert(num_struct_fields > 0);

            var res: T = undefined;
            inline for (comptime std.meta.fieldNames(T), comptime std.meta.fieldNames(@TypeOf(format_options.fields))) |field_name, format_option_field_name| {
                @field(res, field_name) = try decodeAny(@FieldType(T, field_name), reader, seeker, maybe_alloc, @field(format_options.fields, format_option_field_name));
            }
            return res;
        },
    }
}

test "decode struct map" {
    const Foo = struct {
        foo: u8 = 3,
        bar: u16 = 2,
    };
    const Foo2 = struct {
        bar: u8 = 2,
        foo: u16 = 3,
    };

    const bytes: []const u8 = &.{
        0b10000010, // map with two KV pairs
        0b10100011, // fix str 3 char
        'f',
        'o',
        'o',
        0x03,
        0b10100011, // fix str 3 char
        'b',
        'a',
        'r',
        0x02,
    };

    const bad_bytes: []const u8 = &.{
        0b10000010, // map with two KV pairs
        0b10100011, // fix str 3 char
        'f',
        'o',
        'o',
        0x03,
        0b10100011, // fix str 3 char
        'b',
        'a',
        'z',
        0x02,
    };

    const bad_bytes2: []const u8 = &.{
        0b10000010, // map with two KV pairs
        0b10100011, // fix str 3 char
        'f',
        'o',
        'o',
        0x03,
        0b10100101, // fix str 5 char
        'b',
        'a',
        'z',
        'z',
        'z',
        0x02,
    };

    try std.testing.expectEqualDeep(Foo{}, try decode(Foo, bytes, .{}));
    try std.testing.expectEqualDeep(Foo2{}, try decode(Foo2, bytes, .{}));
    try std.testing.expectError(error.Invalid, decode(Foo2, bad_bytes, .{}));
    try std.testing.expectError(error.Invalid, decode(Foo2, bad_bytes2, .{}));
}

test "decode struct array" {
    const Foo = struct {
        foo: u8 = 3,
        bar: u16 = 2,
    };

    const bytes: []const u8 = &.{
        (Spec.Format{ .fixarray = .{ .len = 2 } }).encode(),
        0x03,
        0x02,
    };

    const bad_bytes: []const u8 = &.{
        (Spec.Format{ .fixarray = .{ .len = 3 } }).encode(),
        0x03,
        0x02,
        0x03,
    };

    try std.testing.expectEqualDeep(Foo{}, try decode(Foo, bytes, .{ .format = .{ .layout = .array } }));
    try std.testing.expectError(error.Invalid, decode(Foo, bad_bytes, .{ .format = .{ .layout = .array } }));
}

fn decodeOptional(comptime T: type, reader: anytype, seeker: anytype, maybe_alloc: anytype, format_options: anytype) !T {
    const format = Spec.Format.decode(try reader.readByte());

    const Child = @typeInfo(T).optional.child;
    switch (format) {
        .nil => return null,
        else => {
            // need to recover last byte we just consumed parsing the format.
            try seeker.seekBy(-1);
            return try decodeAny(Child, reader, seeker, maybe_alloc, format_options);
        },
    }
}

test "decode optional" {
    try std.testing.expectEqual(null, decode(?u8, &.{0xc0}, .{}));
    try std.testing.expectEqual(@as(u8, 1), decode(?u8, &.{0x01}, .{}));
}

fn decodeVector(comptime T: type, reader: anytype, seeker: anytype, maybe_alloc: anytype, format_options: anytype) error{ Invalid, EndOfStream }!T {
    const format = Spec.Format.decode(try reader.readByte());
    const expected_format_len = @typeInfo(T).vector.len;
    const Child = @typeInfo(T).vector.child;
    if (Child == u8) {
        switch (format_options) {
            .bin => switch (format) {
                .bin_8, .bin_16, .bin_32 => {},
                else => return error.Invalid,
            },
            .str => switch (format) {
                .fixstr, .str_8, .str_16, .str_32 => {},
                else => return error.Invalid,
            },
            .array => switch (format) {
                .fixarray, .array_16, .array_32 => {},
                else => return error.Invalid,
            },
        }
    } else {
        switch (format) {
            .fixarray, .array_16, .array_32 => {},
            else => return error.Invalid,
        }
    }
    const len = switch (format) {
        .fixarray => |fmt| fmt.len,
        .array_16 => try reader.readInt(u16, .big),
        .array_32 => try reader.readInt(u32, .big),
        .fixstr => |fmt| fmt.len,
        .bin_8, .str_8 => try reader.readInt(u8, .big),
        .bin_16, .str_16 => try reader.readInt(u16, .big),
        .bin_32, .str_32 => try reader.readInt(u32, .big),
        else => unreachable,
    };
    if (len != expected_format_len) return error.Invalid;
    var res: T = undefined;
    switch (Child) {
        u8 => switch (format) {
            .fixarray, .array_16, .array_32 => {
                for (0..expected_format_len) |i| {
                    res[i] = try decodeAny(Child, reader, seeker, maybe_alloc, format_options);
                }
            },
            .fixstr, .bin_8, .bin_16, .bin_32, .str_8, .str_16, .str_32 => {
                for (0..expected_format_len) |i| {
                    res[i] = try reader.readByte();
                }
            },
            else => unreachable,
        },
        else => switch (format) {
            .fixarray, .array_16, .array_32 => {
                for (0..expected_format_len) |i| {
                    res[i] = try decodeAny(Child, reader, seeker, maybe_alloc, format_options);
                }
            },
            else => unreachable,
        },
    }
    return res;
}

test "decode vector" {
    try std.testing.expectEqual(@Vector(3, bool){ true, false, true }, decode(@Vector(3, bool), &.{ 0b10010011, 0xc3, 0xc2, 0xc3 }, .{}));
}

fn decodeArray(comptime T: type, reader: anytype, seeker: anytype, maybe_alloc: anytype, format_options: anytype) error{ Invalid, EndOfStream }!T {
    const has_sentinel = @typeInfo(T).array.sentinel != null;
    const Child = @typeInfo(T).array.child;
    const format = Spec.Format.decode(try reader.readByte());
    comptime var expected_format_len = @typeInfo(T).array.len;
    if (@typeInfo(T).array.sentinel) |_| expected_format_len += 1;
    if (Child == u8) {
        switch (format_options) {
            .bin => switch (format) {
                .bin_8, .bin_16, .bin_32 => {},
                else => return error.Invalid,
            },
            .str => switch (format) {
                .fixstr, .str_8, .str_16, .str_32 => {},
                else => return error.Invalid,
            },
            .array => switch (format) {
                .fixarray, .array_16, .array_32 => {},
                else => return error.Invalid,
            },
        }
    } else {
        switch (format) {
            .fixarray, .array_16, .array_32 => {},
            else => return error.Invalid,
        }
    }
    const len = switch (format) {
        .fixarray => |fmt| fmt.len,
        .array_16 => try reader.readInt(u16, .big),
        .array_32 => try reader.readInt(u32, .big),
        .fixstr => |fmt| fmt.len,
        .bin_8, .str_8 => try reader.readInt(u8, .big),
        .bin_16, .str_16 => try reader.readInt(u16, .big),
        .bin_32, .str_32 => try reader.readInt(u32, .big),
        else => unreachable,
    };
    if (len != expected_format_len) return error.Invalid;
    var res: T = undefined;
    const decode_len = len - @as(comptime_int, @intFromBool(has_sentinel));

    switch (Child) {
        u8 => switch (format) {
            .fixarray, .array_16, .array_32 => {
                for (0..decode_len) |i| {
                    res[i] = try decodeAny(Child, reader, seeker, maybe_alloc, format_options);
                }
            },
            .fixstr, .bin_8, .bin_16, .bin_32, .str_8, .str_16, .str_32 => {
                for (0..decode_len) |i| {
                    res[i] = try reader.readByte();
                }
                if (@typeInfo(T).array.sentinel) |sentinel| {
                    const sentinel_value: Child = @as(*const Child, @ptrCast(sentinel)).*;
                    if (try reader.readByte() != sentinel_value) return error.Invalid;
                }
            },
            else => unreachable,
        },
        else => switch (format) {
            .fixarray, .array_16, .array_32 => {
                for (0..decode_len) |i| {
                    res[i] = try decodeAny(Child, reader, seeker, maybe_alloc, format_options);
                }
                if (@typeInfo(T).array.sentinel) |sentinel| {
                    const sentinel_value: Child = @as(*const Child, @ptrCast(sentinel)).*;
                    if (try decodeAny(Child, reader, seeker, maybe_alloc, format_options) != sentinel_value) return error.Invalid;
                }
            },
            else => unreachable,
        },
    }
    return res;
}

test "decode array" {
    try std.testing.expectEqual([3]bool{ true, false, true }, decode([3]bool, &.{ 0b10010011, 0xc3, 0xc2, 0xc3 }, .{}));
    try std.testing.expectEqual([4]u8{ 0, 1, 2, 3 }, decode([4]u8, &.{ 0b10010100, 0x00, 0x01, 0x02, 0x03 }, .{ .format = .array }));
}

test "decode array sentinel" {
    try std.testing.expectEqual([3:false]bool{ true, false, true }, decode([3:false]bool, &.{ 0b10010100, 0xc3, 0xc2, 0xc3, 0xc2 }, .{}));
}

test "decode array sentinel invalid" {
    try std.testing.expectError(error.Invalid, decode([3:false]bool, &.{ 0b10010100, 0xc3, 0xc2, 0xc3, 0xc3 }, .{}));
}

fn decodeBool(reader: anytype) error{ Invalid, EndOfStream }!bool {
    const format = Spec.Format.decode(try reader.readByte());
    return switch (format) {
        .true => true,
        .false => false,
        else => error.Invalid,
    };
}

test "decode bool" {
    try std.testing.expectEqual(true, decode(bool, &.{0xc3}, .{}));
    try std.testing.expectEqual(false, decode(bool, &.{0xc2}, .{}));
    try std.testing.expectError(error.Invalid, decode(bool, &.{0xe3}, .{}));
}

fn decodeInt(comptime T: type, reader: anytype) error{ Invalid, EndOfStream }!T {
    const format = Spec.Format.decode(try reader.readByte());
    if (@typeInfo(T).int.bits > 64) @compileError("message pack does not support integers larger than 64 bits.");
    switch (format) {
        .positive_fixint => |val| return std.math.cast(T, val.value) orelse return error.Invalid,
        .uint_8 => return cast(T, try reader.readInt(u8, .big)) orelse return error.Invalid,
        .uint_16 => return cast(T, try reader.readInt(u16, .big)) orelse return error.Invalid,
        .uint_32 => return cast(T, try reader.readInt(u32, .big)) orelse return error.Invalid,
        .uint_64 => return cast(T, try reader.readInt(u64, .big)) orelse return error.Invalid,
        .int_8 => return cast(T, try reader.readInt(i8, .big)) orelse return error.Invalid,
        .int_16 => return cast(T, try reader.readInt(i16, .big)) orelse return error.Invalid,
        .int_32 => return cast(T, try reader.readInt(i32, .big)) orelse return error.Invalid,
        .int_64 => return cast(T, try reader.readInt(i64, .big)) orelse return error.Invalid,
        .negative_fixint => |val| return std.math.cast(T, val.value) orelse return error.Invalid,
        else => return error.Invalid,
    }
    unreachable;
}

test "decode int" {
    try std.testing.expectEqual(@as(u5, 0), decode(u5, &.{ 0xcc, 0x00 }, .{}));
    try std.testing.expectEqual(@as(u5, 3), decode(u5, &.{ 0xcc, 0x03 }, .{}));
    try std.testing.expectEqual(@as(u5, 0), decode(u5, &.{0x00}, .{}));
    try std.testing.expectEqual(@as(u5, 3), decode(u5, &.{0x03}, .{}));
    try std.testing.expectEqual(@as(i5, 0), decode(i5, &.{0x00}, .{}));
    try std.testing.expectEqual(@as(i5, -1), decode(i5, &.{0xff}, .{}));
    try std.testing.expectError(error.Invalid, decode(i5, &.{0xb3}, .{}));
}

fn decodeFloat(comptime T: type, reader: anytype) error{ Invalid, EndOfStream }!T {
    const format = Spec.Format.decode(try reader.readByte());
    return switch (@typeInfo(T).float.bits) {
        32 => switch (format) {
            .float_32 => @bitCast(try reader.readInt(u32, .big)),
            else => error.Invalid,
        },
        64 => switch (format) {
            .float_64 => @bitCast(try reader.readInt(u64, .big)),
            else => error.Invalid,
        },
        else => @compileError("Unsupported float type: " ++ @typeName(T)),
    };
}

test "decode float" {
    try std.testing.expectEqual(@as(f32, 1.23), try decode(f32, &.{ 0xca, 0x3f, 0x9d, 0x70, 0xa4 }, .{}));
    try std.testing.expectEqual(@as(f64, 1.23), try decode(f64, &.{ 0xcb, 0x3f, 0xf3, 0xae, 0x14, 0x7a, 0xe1, 0x47, 0xae }, .{}));
}

fn FieldStructStrategy(comptime S: type, comptime DataStrategy: fn (comptime T: type) type, comptime field_default_strategy: ?fn (comptime T: type) type) type {
    var new_struct_fields: [@typeInfo(S).@"struct".fields.len]std.builtin.Type.StructField = undefined;
    for (&new_struct_fields, @typeInfo(S).@"struct".fields) |*new_struct_field, old_struct_field| {
        new_struct_field.* = .{
            .name = old_struct_field.name ++ "",
            .type = DataStrategy(old_struct_field.type),
            .default_value = if (field_default_strategy) |d| @as(?*const anyopaque, @ptrCast(&d(old_struct_field.type))) else null,
            .is_comptime = false,
            .alignment = if (@sizeOf(DataStrategy(old_struct_field.type)) > 0) @alignOf(DataStrategy(old_struct_field.type)) else 0,
        };
    }
    return @Type(.{ .@"struct" = .{
        .layout = .auto,
        .fields = &new_struct_fields,
        .decls = &.{},
        .is_tuple = false,
    } });
}

fn UnionFieldStructStrategy(comptime U: type, comptime DataStrategy: fn (comptime T: type) type, comptime field_default_strategy: ?fn (comptime T: type) type) type {
    var new_struct_fields: [@typeInfo(U).@"union".fields.len]std.builtin.Type.StructField = undefined;
    for (&new_struct_fields, @typeInfo(U).@"union".fields) |*new_struct_field, old_union_field| {
        new_struct_field.* = .{
            .name = old_union_field.name ++ "",
            .type = DataStrategy(old_union_field.type),
            .default_value = if (field_default_strategy) |d| @as(?*const anyopaque, @ptrCast(&d(old_union_field.type))) else null,
            .is_comptime = false,
            .alignment = if (@sizeOf(DataStrategy(old_union_field.type)) > 0) @alignOf(DataStrategy(old_union_field.type)) else 0,
        };
    }
    return @Type(.{ .@"struct" = .{
        .layout = .auto,
        .fields = &new_struct_fields,
        .decls = &.{},
        .is_tuple = false,
    } });
}

pub fn FormatOptionsDefault(comptime T: type) FormatOptions(T) {
    return switch (@typeInfo(T)) {
        .bool => void{},
        .int => void{},
        .float => void{},
        .array, .vector => switch (std.meta.Child(T)) {
            u8 => .str,
            else => FormatOptionsDefault(std.meta.Child(T)),
        },
        .optional => FormatOptionsDefault(@typeInfo(T).optional.child),
        .@"struct", .@"union" => .{},
        .@"enum" => .int,
        .pointer => switch (@typeInfo(T).pointer.size) {
            .One => FormatOptionsDefault(@typeInfo(T).pointer.child),
            .Slice => switch (@typeInfo(T).pointer.child) {
                u8 => .str,
                else => FormatOptionsDefault(@typeInfo(T).pointer.child),
            },
            else => @compileError("type: " ++ @typeName(T) ++ " not supported."),
        },
        else => @compileError("type: " ++ @typeName(T) ++ " not supported."),
    };
}

pub fn FormatOptions(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .bool => void,
        .int => void,
        .float => void,
        .array, .vector => switch (std.meta.Child(T)) {
            u8 => enum {
                bin,
                str,
                array,
            },
            else => FormatOptions(std.meta.Child(T)),
        },
        .optional => FormatOptions(@typeInfo(T).optional.child),
        .@"struct" => struct {
            layout: enum { map, array } = .map,
            fields: FieldStructStrategy(T, FormatOptions, FormatOptionsDefault) = .{},
        },
        .@"union" => struct {
            layout: enum { map, active_field } = .map,
            fields: UnionFieldStructStrategy(T, FormatOptions, FormatOptionsDefault) = .{},
        },
        .@"enum" => enum {
            int,
            str,
        },
        .pointer => switch (@typeInfo(T).pointer.size) {
            .One => FormatOptions(@typeInfo(T).pointer.child),
            .Slice => switch (@typeInfo(T).pointer.child) {
                u8 => enum {
                    str,
                    bin,
                    array,
                },
                else => FormatOptions(@typeInfo(T).pointer.child),
            },
            else => @compileError("type: " ++ @typeName(T) ++ " not supported."),
        },
        else => @compileError("type: " ++ @typeName(T) ++ " not supported."),
    };
}

test "encode options" {
    const Foo = struct {
        foo: u8,
        bar: []const u8,
    };
    const encode_options: EncodeOptions(Foo) = .{};
    try std.testing.expectEqual(encode_options, @as(EncodeOptions(Foo), .{
        .format = .{
            .layout = .map,
            .fields = .{ .foo = void{}, .bar = .str },
        },
    }));
}

test "encode options 2" {
    const Foo = struct {
        foo: u8,
        bar: *[]?[][]const u8,
    };
    const encode_options: EncodeOptions(Foo) = .{};
    try std.testing.expectEqual(encode_options, @as(EncodeOptions(Foo), .{
        .format = .{
            .layout = .map,
            .fields = .{ .foo = void{}, .bar = .str },
        },
    }));
}

test {
    _ = std.testing.refAllDecls(@This());
}

test "all the integers" {
    inline for (0..64) |bits| {
        const signs = &.{ .signed, .unsigned };
        inline for (signs) |sign| {
            const int: type = @Type(.{ .int = .{ .bits = bits, .signedness = sign } });
            if (bits < 22) {
                for (0..std.math.maxInt(int) + 1) |value| {
                    const expected: int = @intCast(value);
                    const encoded: []const u8 = encodeBounded(expected, .{}).slice();
                    try std.testing.expectEqual(expected, decode(@TypeOf(expected), encoded, .{}));
                }
            } else {
                for (0..1000) |_| {
                    const expected: int = std.crypto.random.int(int);
                    const encoded: []const u8 = encodeBounded(expected, .{}).slice();
                    try std.testing.expectEqual(expected, decode(@TypeOf(expected), encoded, .{}));
                }
            }
        }
    }
}
