// SPDX-License-Identifier: GPL-3.0-or-later

const std = @import("std");

pub const Error = error{
    BufferTooSmall,
    FuseOutOfRange,
    RowOutOfRange,
};

pub fn rowByteCount(row_width_bits: usize) usize {
    return (row_width_bits + 7) / 8;
}

pub fn packFuseRow(out: []u8, fuses: []const u8, fuses_size: usize, row_width: usize, row: usize) Error![]u8 {
    if (row >= fuses_size) return Error.RowOutOfRange;
    const bytes = rowByteCount(row_width);
    if (out.len < bytes) return Error.BufferTooSmall;
    @memset(out[0..bytes], 0);
    for (0..row_width) |column| {
        const fuse_index = fuses_size * column + row;
        if (fuse_index >= fuses.len) return Error.FuseOutOfRange;
        if (fuses[fuse_index] == 1) out[column / 8] |= @as(u8, 0x80) >> @intCast(column & 0x07);
    }
    return out[0..bytes];
}

pub fn unpackFuseRow(fuses: []u8, row_data: []const u8, fuses_size: usize, row_width: usize, row: usize) Error!void {
    if (row >= fuses_size) return Error.RowOutOfRange;
    if (row_data.len < rowByteCount(row_width)) return Error.BufferTooSmall;
    for (0..row_width) |column| {
        const fuse_index = fuses_size * column + row;
        if (fuse_index >= fuses.len) return Error.FuseOutOfRange;
        fuses[fuse_index] = if (row_data[column / 8] & (@as(u8, 0x80) >> @intCast(column & 0x07)) != 0) 1 else 0;
    }
}

pub fn packIndexedBits(out: []u8, fuses: []const u8, indices: []const u16, size_bits: usize) Error![]u8 {
    const bytes = rowByteCount(size_bits);
    if (out.len < bytes) return Error.BufferTooSmall;
    @memset(out[0..bytes], 0);
    for (0..size_bits) |index| {
        const fuse_index = indices[index];
        if (fuse_index >= fuses.len) return Error.FuseOutOfRange;
        if (fuses[fuse_index] == 1) out[index / 8] |= @as(u8, 0x80) >> @intCast(index & 0x07);
    }
    return out[0..bytes];
}

pub fn unpackIndexedBits(fuses: []u8, row_data: []const u8, indices: []const u16, size_bits: usize) Error!void {
    if (row_data.len < rowByteCount(size_bits)) return Error.BufferTooSmall;
    for (0..size_bits) |index| {
        const fuse_index = indices[index];
        if (fuse_index >= fuses.len) return Error.FuseOutOfRange;
        fuses[fuse_index] = if (row_data[index / 8] & (@as(u8, 0x80) >> @intCast(index & 0x07)) != 0) 1 else 0;
    }
}

test "pack and unpack GAL fuse rows using upstream column-major layout" {
    const fuses = [_]u8{
        1, 0,
        0, 1,
        1, 1,
        0, 0,
    };
    var row = [_]u8{0} ** 1;

    const result = try packFuseRow(&row, &fuses, 2, 4, 1);

    try std.testing.expectEqualSlices(u8, &.{0x60}, result);

    var decoded = [_]u8{0} ** 8;
    try unpackFuseRow(&decoded, result, 2, 4, 1);
    try std.testing.expectEqual(@as(u8, 0), decoded[1]);
    try std.testing.expectEqual(@as(u8, 1), decoded[3]);
    try std.testing.expectEqual(@as(u8, 1), decoded[5]);
    try std.testing.expectEqual(@as(u8, 0), decoded[7]);
}

test "pack indexed ACW bits" {
    const fuses = [_]u8{ 0, 1, 0, 1, 1 };
    const indices = [_]u16{ 1, 3, 4 };
    var row = [_]u8{0} ** 1;

    const result = try packIndexedBits(&row, &fuses, &indices, indices.len);

    try std.testing.expectEqualSlices(u8, &.{0xe0}, result);
}
