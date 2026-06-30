// SPDX-License-Identifier: GPL-3.0-or-later

const std = @import("std");
const image = @import("image.zig");

pub fn readAll(allocator: std.mem.Allocator, reader: anytype, options: image.Options) !image.MemoryImage {
    const bytes = try reader.readAllAlloc(allocator, 1024 * 1024 * 1024);
    errdefer allocator.free(bytes);
    return .{
        .allocator = allocator,
        .data = bytes,
        .address = options.address,
        .kind = options.kind,
        .fill = options.fill,
        .word_size = options.word_size,
    };
}

pub fn writeAll(writer: anytype, memory: image.MemoryImage) !void {
    try writer.writeAll(memory.data);
}

test "binary read/write round trip" {
    var input: std.Io.Reader = .fixed(&[_]u8{ 0xde, 0xad, 0xbe, 0xef });
    var memory = try readAll(std.testing.allocator, &input, .{ .address = 0x20 });
    defer memory.deinit();

    try std.testing.expectEqual(@as(u32, 0x20), memory.address);
    try std.testing.expectEqualSlices(u8, &.{ 0xde, 0xad, 0xbe, 0xef }, memory.data);

    var bytes = [_]u8{0} ** 16;
    var output: std.Io.Writer = .fixed(&bytes);
    try writeAll(&output, memory);
    try std.testing.expectEqualSlices(u8, memory.data, output.buffered());
}
