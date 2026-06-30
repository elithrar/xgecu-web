// SPDX-License-Identifier: GPL-3.0-or-later

const std = @import("std");

pub const Endian = enum {
    little,
    big,
};

pub fn storeInt(out: []u8, value: u64, endian: Endian) void {
    std.debug.assert(out.len <= 8);
    for (out, 0..) |*byte, i| {
        const shift: u6 = @intCast(8 * i);
        byte.* = switch (endian) {
            .little => @intCast((value >> shift) & 0xff),
            .big => @intCast((value >> @as(u6, @intCast(8 * (out.len - i - 1)))) & 0xff),
        };
    }
}

pub fn loadInt(input: []const u8, endian: Endian) u64 {
    std.debug.assert(input.len <= 8);
    var result: u64 = 0;
    for (0..input.len) |i| {
        const source_index = switch (endian) {
            .little => i,
            .big => input.len - i - 1,
        };
        const shift: u6 = @intCast(8 * i);
        result |= @as(u64, input[source_index]) << shift;
    }
    return result;
}

test "load and store little endian widths used by protocols" {
    var buffer = [_]u8{0} ** 8;
    storeInt(buffer[0..3], 0x123456, .little);
    try std.testing.expectEqualSlices(u8, &.{ 0x56, 0x34, 0x12 }, buffer[0..3]);
    try std.testing.expectEqual(@as(u64, 0x123456), loadInt(buffer[0..3], .little));

    storeInt(buffer[0..4], 0xa1b2c3d4, .little);
    try std.testing.expectEqualSlices(u8, &.{ 0xd4, 0xc3, 0xb2, 0xa1 }, buffer[0..4]);
    try std.testing.expectEqual(@as(u64, 0xa1b2c3d4), loadInt(buffer[0..4], .little));
}

test "load and store big endian widths used by IDs" {
    var buffer = [_]u8{0} ** 8;
    storeInt(buffer[0..3], 0x123456, .big);
    try std.testing.expectEqualSlices(u8, &.{ 0x12, 0x34, 0x56 }, buffer[0..3]);
    try std.testing.expectEqual(@as(u64, 0x123456), loadInt(buffer[0..3], .big));
}

test "round trip all supported integer widths" {
    const value: u64 = 0x0123456789abcdef;
    var buffer = [_]u8{0} ** 8;
    for (1..9) |width| {
        const mask = if (width == 8) ~@as(u64, 0) else (@as(u64, 1) << @intCast(width * 8)) - 1;
        storeInt(buffer[0..width], value, .little);
        try std.testing.expectEqual(value & mask, loadInt(buffer[0..width], .little));
        storeInt(buffer[0..width], value, .big);
        try std.testing.expectEqual(value & mask, loadInt(buffer[0..width], .big));
    }
}
