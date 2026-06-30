// SPDX-License-Identifier: GPL-3.0-or-later

const std = @import("std");
const model = @import("../core/model.zig");

pub const MemoryImage = struct {
    allocator: std.mem.Allocator,
    data: []u8,
    address: u32 = 0,
    kind: model.MemoryKind = .code,
    fill: u8 = 0xff,
    word_size: u8 = 1,

    pub fn initCopy(
        allocator: std.mem.Allocator,
        data: []const u8,
        options: Options,
    ) !MemoryImage {
        const owned = try allocator.dupe(u8, data);
        return .{
            .allocator = allocator,
            .data = owned,
            .address = options.address,
            .kind = options.kind,
            .fill = options.fill,
            .word_size = options.word_size,
        };
    }

    pub fn deinit(self: *MemoryImage) void {
        self.allocator.free(self.data);
        self.* = undefined;
    }

    pub fn byteLen(self: MemoryImage) usize {
        return self.data.len;
    }
};

pub const Options = struct {
    address: u32 = 0,
    kind: model.MemoryKind = .code,
    fill: u8 = 0xff,
    word_size: u8 = 1,
};

test "memory image owns a copy" {
    var source = [_]u8{ 1, 2, 3 };
    var image = try MemoryImage.initCopy(std.testing.allocator, &source, .{ .address = 0x1000, .fill = 0x00 });
    defer image.deinit();

    source[0] = 9;
    try std.testing.expectEqual(@as(usize, 3), image.byteLen());
    try std.testing.expectEqual(@as(u8, 1), image.data[0]);
    try std.testing.expectEqual(@as(u32, 0x1000), image.address);
    try std.testing.expectEqual(@as(u8, 0x00), image.fill);
}
