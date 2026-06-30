// SPDX-License-Identifier: GPL-3.0-or-later

const std = @import("std");
const endian = @import("endian.zig");

pub const Error = error{
    BufferTooSmall,
    InvalidAssignment,
    InvalidValue,
    InvalidWordSize,
    MissingValue,
    OutOfMemory,
    ValueTooLarge,
};

pub const ConfigItem = struct {
    name: []const u8,
    mask: u16,
    default_value: u16,
};

pub const NamedValue = struct {
    name: []const u8,
    value: u16,
};

pub const PackOptions = struct {
    word_size: u8,
    compare_mask: u16 = 0,
    apply_compare_mask: bool = false,
};

pub fn packedLen(items: []const ConfigItem, word_size: u8) Error!usize {
    if (word_size != 1 and word_size != 2) return Error.InvalidWordSize;
    return items.len * word_size;
}

pub fn packItems(out: []u8, items: []const ConfigItem, values: []const NamedValue, options: PackOptions) Error![]u8 {
    const needed = try packedLen(items, options.word_size);
    if (out.len < needed) return Error.BufferTooSmall;
    for (items, 0..) |item, index| {
        const raw = findValue(values, item.name) orelse return Error.MissingValue;
        const normalized = normalizeValue(raw, item.mask, options);
        endian.storeInt(out[index * options.word_size ..][0..options.word_size], normalized, .little);
    }
    return out[0..needed];
}

pub fn parseNamedValues(allocator: std.mem.Allocator, text: []const u8) Error![]NamedValue {
    var parsed: std.ArrayListUnmanaged(NamedValue) = .empty;
    errdefer parsed.deinit(allocator);

    var tokens = std.mem.tokenizeAny(u8, text, " \t\r\n");
    while (tokens.next()) |token| {
        const separator = std.mem.indexOfScalar(u8, token, '=') orelse return Error.InvalidAssignment;
        if (separator == 0 or separator == token.len - 1) return Error.InvalidAssignment;
        try parsed.append(allocator, .{
            .name = token[0..separator],
            .value = try parseU16(token[separator + 1 ..]),
        });
    }
    return try parsed.toOwnedSlice(allocator);
}

pub fn normalizeValue(value: u16, mask: u16, options: PackOptions) u16 {
    var result = value | ~mask;
    if (options.apply_compare_mask and options.compare_mask > 0xff) result &= options.compare_mask;
    if (options.word_size == 1) result &= 0xff;
    return result;
}

fn findValue(values: []const NamedValue, name: []const u8) ?u16 {
    for (values) |entry| {
        if (std.ascii.eqlIgnoreCase(entry.name, name)) return entry.value;
    }
    return null;
}

fn parseU16(text: []const u8) Error!u16 {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0) return Error.InvalidValue;
    const radix: u8 = if (trimmed.len > 2 and trimmed[0] == '0' and (trimmed[1] == 'x' or trimmed[1] == 'X')) 16 else 10;
    const digits = if (radix == 16) trimmed[2..] else trimmed;
    if (digits.len == 0) return Error.InvalidValue;
    const value = std.fmt.parseUnsigned(u32, digits, radix) catch return Error.InvalidValue;
    if (value > 0xffff) return Error.ValueTooLarge;
    return @intCast(value);
}

test "parse named fuse values" {
    const values = try parseNamedValues(std.testing.allocator, "fuse=0x05\nlock=3\tUSER=0xffff");
    defer std.testing.allocator.free(values);

    try std.testing.expectEqual(@as(usize, 3), values.len);
    try std.testing.expectEqualStrings("fuse", values[0].name);
    try std.testing.expectEqual(@as(u16, 0x0005), values[0].value);
    try std.testing.expectEqualStrings("lock", values[1].name);
    try std.testing.expectEqual(@as(u16, 3), values[1].value);
    try std.testing.expectEqualStrings("USER", values[2].name);
    try std.testing.expectEqual(@as(u16, 0xffff), values[2].value);
}

test "parse rejects malformed named fuse values" {
    try std.testing.expectError(Error.InvalidAssignment, parseNamedValues(std.testing.allocator, "fuse"));
    try std.testing.expectError(Error.InvalidValue, parseNamedValues(std.testing.allocator, "fuse=0x"));
    try std.testing.expectError(Error.ValueTooLarge, parseNamedValues(std.testing.allocator, "fuse=0x10000"));
}

test "pack config fuse values with unused bits forced high" {
    const items = [_]ConfigItem{
        .{ .name = "fuse", .mask = 0x000f, .default_value = 0x00ff },
    };
    const values = [_]NamedValue{
        .{ .name = "FUSE", .value = 0x0005 },
    };
    var out = [_]u8{0} ** 4;

    const result = try packItems(&out, &items, &values, .{ .word_size = 1 });

    try std.testing.expectEqualSlices(u8, &.{0xf5}, result);
}

test "pack word-sized config fuses little endian with compare mask" {
    const items = [_]ConfigItem{
        .{ .name = "cfg", .mask = 0x0fff, .default_value = 0xffff },
    };
    const values = [_]NamedValue{
        .{ .name = "cfg", .value = 0x0123 },
    };
    var out = [_]u8{0} ** 4;

    const result = try packItems(&out, &items, &values, .{ .word_size = 2, .compare_mask = 0x3fff, .apply_compare_mask = true });

    try std.testing.expectEqualSlices(u8, &.{ 0x23, 0x31 }, result);
}

test "pack lock fuses without compare-mask narrowing" {
    const items = [_]ConfigItem{
        .{ .name = "lock", .mask = 0x0003, .default_value = 0x00ff },
    };
    const values = [_]NamedValue{
        .{ .name = "lock", .value = 0x0001 },
    };
    var out = [_]u8{0} ** 4;

    const result = try packItems(&out, &items, &values, .{ .word_size = 1, .compare_mask = 0x0003, .apply_compare_mask = false });

    try std.testing.expectEqualSlices(u8, &.{0xfd}, result);
}

test "pack requires explicit named values" {
    const items = [_]ConfigItem{
        .{ .name = "lock", .mask = 0x0003, .default_value = 0x00ff },
    };
    var out = [_]u8{0} ** 4;

    try std.testing.expectError(Error.MissingValue, packItems(&out, &items, &.{}, .{ .word_size = 1 }));
}
