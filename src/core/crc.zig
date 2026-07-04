// SPDX-License-Identifier: Apache-2.0

const std = @import("std");

const polynomial: u32 = 0xedb88320;

pub fn crc32(data: []const u8, initial: u32) u32 {
    var crc = initial;
    for (data) |byte| {
        crc ^= byte;
        var bit: u8 = 0;
        while (bit < 8) : (bit += 1) {
            const mask: u32 = if (crc & 1 == 1) polynomial else 0;
            crc = (crc >> 1) ^ mask;
        }
    }
    return crc;
}

test "crc32 matches reference values" {
    try std.testing.expectEqual(@as(u32, 0xffffffff), crc32("", 0xffffffff));
    try std.testing.expectEqual(@as(u32, 0x340bc6d9), crc32("123456789", 0xffffffff));
    try std.testing.expectEqual(@as(u32, 0xcbf43926), ~crc32("123456789", 0xffffffff));
}
