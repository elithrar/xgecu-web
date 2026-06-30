// SPDX-License-Identifier: GPL-3.0-or-later

const std = @import("std");
const image = @import("image.zig");

const row_size = 16;
const header = "Written by Minipro open source software";

pub const Error = error{
    NotSrec,
    BadRecordType,
    BadChecksum,
    BadCount,
    WrongRecordCount,
    OutOfMemory,
};

const RecordType = enum(u8) { s0 = 0, s1 = 1, s2 = 2, s3 = 3, s4 = 4, s5 = 5, s6 = 6, s7 = 7, s8 = 8, s9 = 9 };

const Record = struct {
    address: u32,
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

    var lines = std.mem.splitScalar(u8, text, '\n');
    var data_records: u32 = 0;
    while (lines.next()) |raw_line| {
        const line = std.mem.trimEnd(u8, raw_line, "\r");
        if (line.len == 0) continue;

        const record = try parseRecord(line);
        switch (record.record_type) {
            .s0, .s7, .s8, .s9 => {},
            .s1, .s2, .s3 => {
                data_records += 1;
                const data = record.bytes();
                const end = record.address + @as(u32, @intCast(data.len));
                if (end > bytes.items.len) {
                    const old_len = bytes.items.len;
                    try bytes.resize(allocator, end);
                    @memset(bytes.items[old_len..], options.fill);
                }
                @memcpy(bytes.items[record.address..end], data);
            },
            .s5, .s6 => if (record.address != data_records) return Error.WrongRecordCount,
            .s4 => {},
        }
    }

    return .{
        .allocator = allocator,
        .data = try bytes.toOwnedSlice(allocator),
        .address = options.address,
        .kind = options.kind,
        .fill = options.fill,
        .word_size = options.word_size,
    };
}

pub fn writeAll(writer: anytype, memory: image.MemoryImage, write_record_count: bool) !void {
    try writeRecord(writer, .s0, 0, header);
    var offset: usize = 0;
    var records: u32 = 0;
    while (offset < memory.data.len) {
        const address = memory.address + @as(u32, @intCast(offset));
        const record_type: RecordType = if (address < 65536) .s1 else if (address < 16777216) .s2 else .s3;
        const len = @min(row_size, memory.data.len - offset);
        try writeRecord(writer, record_type, address, memory.data[offset .. offset + len]);
        offset += len;
        records += 1;
    }
    if (write_record_count) try writeRecord(writer, if (records < 65536) .s5 else .s6, records, &.{});
}

fn parseRecord(line: []const u8) Error!Record {
    if (line.len < 4 or line[0] != 'S') return Error.NotSrec;
    const digit = try hexNibble(line[1]);
    const record_type: RecordType = switch (digit) {
        0 => .s0,
        1 => .s1,
        2 => .s2,
        3 => .s3,
        4 => .s4,
        5 => .s5,
        6 => .s6,
        7 => .s7,
        8 => .s8,
        9 => .s9,
        else => return Error.BadRecordType,
    };
    const byte_count = try hexByte(line[2..4]);
    if (line.len < 4 + @as(usize, byte_count) * 2) return Error.BadCount;

    const address_len: u8 = switch (record_type) {
        .s0, .s1, .s5, .s9 => 2,
        .s2, .s6, .s8 => 3,
        .s3, .s7 => 4,
        .s4 => 0,
    };
    if (address_len == 0) return .{ .address = 0, .record_type = record_type, .count = 0, .data = undefined };
    if (byte_count < address_len + 1) return Error.BadCount;

    var checksum: u8 = byte_count;
    var address: u32 = 0;
    var cursor: usize = 4;
    var index: u8 = 0;
    while (index < address_len) : (index += 1) {
        const value = try hexByte(line[cursor .. cursor + 2]);
        cursor += 2;
        checksum +%= value;
        address = (address << 8) | value;
    }

    const data_count: u8 = byte_count - address_len - 1;
    var data: [255]u8 = undefined;
    index = 0;
    while (index < data_count) : (index += 1) {
        const value = try hexByte(line[cursor .. cursor + 2]);
        cursor += 2;
        data[index] = value;
        checksum +%= value;
    }

    const actual = try hexByte(line[cursor .. cursor + 2]);
    if (~checksum != actual) return Error.BadChecksum;
    return .{ .address = address, .record_type = record_type, .count = data_count, .data = data };
}

fn writeRecord(writer: anytype, record_type: RecordType, address: u32, data: []const u8) !void {
    const address_len: u8 = switch (record_type) {
        .s2, .s6, .s8 => 3,
        .s3, .s7 => 4,
        else => 2,
    };
    const byte_count: u8 = @intCast(data.len + address_len + 1);
    var checksum: u8 = byte_count;
    try writer.print("S{d}{X:0>2}", .{ @intFromEnum(record_type), byte_count });

    var shift: u5 = @intCast((address_len - 1) * 8);
    var remaining = address_len;
    while (remaining != 0) : (remaining -= 1) {
        const byte: u8 = @intCast((address >> shift) & 0xff);
        checksum +%= byte;
        try writer.print("{X:0>2}", .{byte});
        if (shift >= 8) shift -= 8;
    }
    for (data) |byte| {
        checksum +%= byte;
        try writer.print("{X:0>2}", .{byte});
    }
    try writer.print("{X:0>2}\r\n", .{~checksum});
}

fn hexByte(text: []const u8) Error!u8 {
    if (text.len != 2) return Error.NotSrec;
    return (try hexNibble(text[0]) << 4) | try hexNibble(text[1]);
}

fn hexNibble(byte: u8) Error!u8 {
    return switch (byte) {
        '0'...'9' => byte - '0',
        'A'...'F' => byte - 'A' + 10,
        'a'...'f' => byte - 'a' + 10,
        else => Error.NotSrec,
    };
}

test "read S-record data and count" {
    const text =
        \\S00600004844521B
        \\S1070010DEADBEEFA0
        \\S5030001FB
        \\
    ;
    var memory = try readAll(std.testing.allocator, text, .{});
    defer memory.deinit();

    try std.testing.expectEqual(@as(usize, 0x14), memory.data.len);
    try std.testing.expectEqualSlices(u8, &.{ 0xde, 0xad, 0xbe, 0xef }, memory.data[0x10..0x14]);
}

test "write S-record header data and count" {
    var memory = try image.MemoryImage.initCopy(std.testing.allocator, &.{ 0xde, 0xad, 0xbe, 0xef }, .{ .address = 0x10 });
    defer memory.deinit();

    var bytes = [_]u8{0} ** 256;
    var writer: std.Io.Writer = .fixed(&bytes);
    try writeAll(&writer, memory, true);

    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "S1070010DEADBEEFA0") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "S5030001FB") != null);
}

test "reject bad S-record checksum" {
    try std.testing.expectError(Error.BadChecksum, readAll(std.testing.allocator, "S5030001FA\n", .{}));
}
