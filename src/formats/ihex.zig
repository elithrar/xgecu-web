// SPDX-License-Identifier: GPL-3.0-or-later

const std = @import("std");
const image = @import("image.zig");

const row_size = 16;

pub const Error = error{
    NotIntelHex,
    BadRecordType,
    BadChecksum,
    BadCount,
    MissingEof,
    RecordAfterEof,
    DuplicateEof,
    OutOfMemory,
};

const RecordType = enum(u8) {
    data = 0,
    eof = 1,
    extended_segment_address = 2,
    start_segment_address = 3,
    extended_linear_address = 4,
    start_linear_address = 5,
};

const Record = struct {
    address: u16,
    record_type: RecordType,
    count: u8,
    data: [255]u8,

    fn bytes(self: *const Record) []const u8 {
        return self.data[0..self.count];
    }
};

pub fn readAll(allocator: std.mem.Allocator, text: []const u8, options: image.Options) Error!image.MemoryImage {
    var bytes: std.ArrayListUnmanaged(u8) = .empty;
    errdefer bytes.deinit(allocator);

    var upper_base: u32 = 0;
    var eof = false;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trimEnd(u8, raw_line, "\r");
        if (line.len == 0) continue;

        const record = try parseRecord(line);
        if (record.record_type != .eof and eof) return Error.RecordAfterEof;

        switch (record.record_type) {
            .data => {
                const absolute = upper_base + record.address;
                const data = record.bytes();
                const end = absolute + @as(u32, @intCast(data.len));
                if (end > bytes.items.len) {
                    const old_len = bytes.items.len;
                    try bytes.resize(allocator, end);
                    @memset(bytes.items[old_len..], options.fill);
                }
                @memcpy(bytes.items[absolute..end], data);
            },
            .eof => {
                if (eof) return Error.DuplicateEof;
                eof = true;
            },
            .extended_segment_address => {
                const data = record.bytes();
                if (data.len != 2) return Error.BadCount;
                upper_base = (@as(u32, data[0]) << 12) | (@as(u32, data[1]) << 4);
            },
            .extended_linear_address => {
                const data = record.bytes();
                if (data.len != 2) return Error.BadCount;
                upper_base = (@as(u32, data[0]) << 24) | (@as(u32, data[1]) << 16);
            },
            .start_segment_address => {
                const data = record.bytes();
                if (data.len != 4) return Error.BadCount;
                upper_base = (@as(u32, data[0]) << 12) |
                    (@as(u32, data[1]) << 4) |
                    (@as(u32, data[2]) << 8) |
                    @as(u32, data[3]);
            },
            .start_linear_address => {
                const data = record.bytes();
                if (data.len != 4) return Error.BadCount;
                upper_base = (@as(u32, data[0]) << 24) |
                    (@as(u32, data[1]) << 16) |
                    (@as(u32, data[2]) << 8) |
                    @as(u32, data[3]);
            },
        }
    }

    if (!eof) return Error.MissingEof;
    return .{
        .allocator = allocator,
        .data = try bytes.toOwnedSlice(allocator),
        .address = options.address,
        .kind = options.kind,
        .fill = options.fill,
        .word_size = options.word_size,
    };
}

pub fn writeAll(writer: anytype, memory: image.MemoryImage, write_eof: bool) !void {
    var offset: usize = 0;
    var current_upper: u32 = std.math.maxInt(u32);
    while (offset < memory.data.len) {
        const absolute: u32 = memory.address + @as(u32, @intCast(offset));
        const upper = absolute >> 16;
        if (upper != current_upper) {
            current_upper = upper;
            const upper_bytes = [_]u8{ @intCast(upper >> 8), @intCast(upper & 0xff) };
            try writeRecord(writer, 0, .extended_linear_address, &upper_bytes);
        }

        const len = @min(row_size, memory.data.len - offset);
        try writeRecord(writer, @intCast(absolute & 0xffff), .data, memory.data[offset .. offset + len]);
        offset += len;
    }
    if (write_eof) try writeRecord(writer, 0, .eof, &.{});
}

fn parseRecord(line: []const u8) Error!Record {
    if (line.len < 11 or line[0] != ':') return Error.NotIntelHex;
    const count = try hexByte(line[1..3]);
    const expected_len: usize = 11 + @as(usize, count) * 2;
    if (line.len < expected_len) return Error.BadCount;

    const address = (@as(u16, try hexByte(line[3..5])) << 8) | try hexByte(line[5..7]);
    const raw_type = try hexByte(line[7..9]);
    const record_type: RecordType = switch (raw_type) {
        0 => .data,
        1 => .eof,
        2 => .extended_segment_address,
        3 => .start_segment_address,
        4 => .extended_linear_address,
        5 => .start_linear_address,
        else => return Error.BadRecordType,
    };

    var data: [255]u8 = undefined;
    var checksum: u8 = count +% @as(u8, @intCast(address >> 8)) +% @as(u8, @intCast(address & 0xff)) +% raw_type;
    var index: usize = 0;
    while (index < count) : (index += 1) {
        const value = try hexByte(line[9 + index * 2 .. 11 + index * 2]);
        data[index] = value;
        checksum +%= value;
    }
    const expected_checksum = (~checksum) +% 1;
    const actual_checksum = try hexByte(line[9 + @as(usize, count) * 2 .. 11 + @as(usize, count) * 2]);
    if (expected_checksum != actual_checksum) return Error.BadChecksum;

    return .{ .address = address, .record_type = record_type, .count = count, .data = data };
}

fn writeRecord(writer: anytype, address: u16, record_type: RecordType, data: []const u8) !void {
    var checksum: u8 = @as(u8, @intCast(data.len)) +% @as(u8, @intCast(address >> 8)) +% @as(u8, @intCast(address & 0xff)) +% @intFromEnum(record_type);
    try writer.print(":{X:0>2}{X:0>4}{X:0>2}", .{ data.len, address, @intFromEnum(record_type) });
    for (data) |byte| {
        checksum +%= byte;
        try writer.print("{X:0>2}", .{byte});
    }
    try writer.print("{X:0>2}\r\n", .{(~checksum) +% 1});
}

fn hexByte(text: []const u8) Error!u8 {
    if (text.len != 2) return Error.NotIntelHex;
    const hi = try hexNibble(text[0]);
    const lo = try hexNibble(text[1]);
    return (hi << 4) | lo;
}

fn hexNibble(byte: u8) Error!u8 {
    return switch (byte) {
        '0'...'9' => byte - '0',
        'A'...'F' => byte - 'A' + 10,
        'a'...'f' => byte - 'a' + 10,
        else => Error.NotIntelHex,
    };
}

test "read Intel HEX with extended linear address" {
    const text =
        \\:020000040001F9
        \\:04001000DEADBEEFB4
        \\:00000001FF
        \\
    ;
    var memory = try readAll(std.testing.allocator, text, .{});
    defer memory.deinit();

    try std.testing.expectEqual(@as(usize, 0x10014), memory.data.len);
    try std.testing.expectEqualSlices(u8, &.{ 0xde, 0xad, 0xbe, 0xef }, memory.data[0x10010..0x10014]);
    try std.testing.expectEqual(@as(u8, 0xff), memory.data[0]);
}

test "write Intel HEX rows and EOF" {
    var memory = try image.MemoryImage.initCopy(std.testing.allocator, &.{ 0xde, 0xad, 0xbe, 0xef }, .{ .address = 0x10010 });
    defer memory.deinit();

    var bytes = [_]u8{0} ** 128;
    var writer: std.Io.Writer = .fixed(&bytes);
    try writeAll(&writer, memory, true);

    try std.testing.expectEqualStrings(
        \\:020000040001F9
        \\:04101000DEADBEEFB4
        \\:00000001FF
    , writer.buffered());
}

test "reject bad checksum" {
    try std.testing.expectError(Error.BadChecksum, readAll(std.testing.allocator, ":00000001FE\n", .{}));
}
