// SPDX-License-Identifier: GPL-3.0-or-later

const std = @import("std");

const stx = 0x02;
const etx = 0x03;
const row_size = 32;

pub const Error = error{
    BadFormat,
    MissingToken,
    DuplicateToken,
    OutOfRange,
    OutOfMemory,
};

pub const Jedec = struct {
    allocator: std.mem.Allocator,
    device_name: []const u8 = "Unknown",
    f: u8 = 0,
    g: u8 = 0,
    qf: u32 = 0,
    qp: u32 = 0,
    c: u16 = 0,
    fuse_checksum: u16 = 0,
    calc_file_checksum: u16 = 0,
    decl_file_checksum: u16 = 0,
    fuses: []u8,

    pub fn deinit(self: *Jedec) void {
        self.allocator.free(self.fuses);
        self.* = undefined;
    }
};

pub fn readAll(allocator: std.mem.Allocator, bytes: []const u8) Error!Jedec {
    const stx_index = std.mem.indexOfScalar(u8, bytes, stx) orelse return Error.BadFormat;
    const etx_index = std.mem.indexOfScalarPos(u8, bytes, stx_index, etx) orelse return Error.BadFormat;
    if (std.mem.indexOfScalarPos(u8, bytes, stx_index + 1, stx) != null) return Error.BadFormat;
    if (std.mem.indexOfScalarPos(u8, bytes, etx_index + 1, etx) != null) return Error.BadFormat;

    const declared = try parseFixedHex(bytes[etx_index + 1 ..], 4);
    var file_checksum: u16 = 0;
    for (bytes[stx_index .. etx_index + 1]) |byte| file_checksum +%= byte;

    var jedec = Jedec{
        .allocator = allocator,
        .decl_file_checksum = declared,
        .calc_file_checksum = file_checksum,
        .fuses = &.{},
    };
    errdefer if (jedec.fuses.len != 0) allocator.free(jedec.fuses);

    var have_qf = false;
    var have_qp = false;
    var have_f = false;
    var have_g = false;
    var have_c = false;
    var initialized = false;

    var tokens = std.mem.splitScalar(u8, bytes[stx_index + 1 .. etx_index], '*');
    while (tokens.next()) |raw_token| {
        const token = std.mem.trim(u8, raw_token, " \t\r\n");
        if (token.len == 0) continue;
        if (startsWithIgnoreCase(token, "QP")) {
            if (have_qp) return Error.DuplicateToken;
            jedec.qp = try parseDecimal(token[2..]);
            have_qp = true;
        } else if (startsWithIgnoreCase(token, "QF")) {
            if (have_qf) return Error.DuplicateToken;
            jedec.qf = try parseDecimal(token[2..]);
            have_qf = true;
        } else if (startsWithIgnoreCase(token, "F")) {
            if (have_f) return Error.DuplicateToken;
            jedec.f = @intCast(try parseDecimal(token[1..]));
            have_f = true;
        } else if (startsWithIgnoreCase(token, "G")) {
            if (have_g) return Error.DuplicateToken;
            jedec.g = @intCast(try parseDecimal(token[1..]));
            have_g = true;
        } else if (startsWithIgnoreCase(token, "C")) {
            if (have_c) return Error.DuplicateToken;
            jedec.c = try parseFixedHex(token[1..], 4);
            have_c = true;
        } else if (startsWithIgnoreCase(token, "L")) {
            if (!have_qf or have_c) return Error.BadFormat;
            if (!initialized) {
                jedec.fuses = try allocator.alloc(u8, jedec.qf);
                @memset(jedec.fuses, if (have_f and jedec.f != 0) 1 else 0);
                initialized = true;
            }
            try parseFuseLine(token[1..], &jedec);
        }
    }

    if (!have_qf) return Error.MissingToken;
    if (!initialized) {
        jedec.fuses = try allocator.alloc(u8, jedec.qf);
        @memset(jedec.fuses, if (have_f and jedec.f != 0) 1 else 0);
    }
    jedec.fuse_checksum = fuseChecksum(jedec.fuses);
    return jedec;
}

pub fn writeAll(writer: anytype, jedec: Jedec, version: []const u8) !void {
    var buffer: std.ArrayListUnmanaged(u8) = .empty;
    defer buffer.deinit(jedec.allocator);
    var w = buffer.writer(jedec.allocator);

    try w.print("{c}\r\nDevice: {s}\r\n\r\nNOTE: Written by Minipro open source software v{s}\r\n\r\n*QP{d}\r\n*QF{d}\r\n*F{d}\r\n*G{d}\r\n\r\n", .{ stx, jedec.device_name, version, jedec.qp, jedec.qf, jedec.f, jedec.g });
    for (jedec.fuses, 0..) |fuse, index| {
        if (index % row_size == 0) try w.print("{s}*L{d:0>5} ", .{ if (index == 0) "" else "\r\n", index });
        try w.writeByte(if (fuse == 1) '1' else '0');
    }

    const checksum = fuseChecksum(jedec.fuses);
    try w.print("\r\n*C{X:0>4}\r\n{c}", .{ checksum, etx });

    var file_checksum: u16 = 0;
    for (buffer.items) |byte| file_checksum +%= byte;
    try w.print("{X:0>4}\r\n", .{file_checksum});
    try writer.writeAll(buffer.items);
}

fn parseFuseLine(text: []const u8, jedec: *Jedec) Error!void {
    var end: usize = 0;
    while (end < text.len and std.ascii.isDigit(text[end])) end += 1;
    if (end == 0) return Error.BadFormat;
    var offset = try parseDecimal(text[0..end]);
    for (text[end..]) |byte| {
        if (byte == '0' or byte == '1') {
            if (offset >= jedec.fuses.len) return Error.OutOfRange;
            jedec.fuses[offset] = if (byte == '1') 1 else 0;
            offset += 1;
        } else if (byte == ' ' or byte == '\t' or byte == '\r' or byte == '\n') {
            continue;
        } else {
            return Error.BadFormat;
        }
    }
}

fn fuseChecksum(fuses: []const u8) u16 {
    var checksum: u16 = 0;
    for (fuses, 0..) |fuse, index| {
        if (fuse == 1) checksum +%= @as(u16, 1) << @intCast(index & 0x07);
    }
    return checksum;
}

fn parseDecimal(text: []const u8) Error!u32 {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0) return Error.BadFormat;
    return std.fmt.parseInt(u32, trimmed, 10) catch Error.BadFormat;
}

fn parseFixedHex(text: []const u8, digits: usize) Error!u16 {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len < digits) return Error.BadFormat;
    return std.fmt.parseInt(u16, trimmed[0..digits], 16) catch Error.BadFormat;
}

fn startsWithIgnoreCase(text: []const u8, prefix: []const u8) bool {
    return text.len >= prefix.len and std.ascii.eqlIgnoreCase(text[0..prefix.len], prefix);
}

test "read JEDEC fuses and checksums" {
    const text = "\x02*QP24*QF8*F0*G0*L00000 10101010* C0055\r\n\x0305B8\r\n";
    var jedec = try readAll(std.testing.allocator, text);
    defer jedec.deinit();

    try std.testing.expectEqual(@as(u32, 24), jedec.qp);
    try std.testing.expectEqual(@as(u32, 8), jedec.qf);
    try std.testing.expectEqual(@as(u16, 0x55), jedec.fuse_checksum);
    try std.testing.expectEqualSlices(u8, &.{ 1, 0, 1, 0, 1, 0, 1, 0 }, jedec.fuses);
}

test "write JEDEC includes fuse and file checksum" {
    var fuses = [_]u8{ 1, 0, 1, 0, 1, 0, 1, 0 };
    const jedec = Jedec{ .allocator = std.testing.allocator, .device_name = "TEST", .qp = 24, .qf = 8, .fuses = &fuses };
    var bytes = [_]u8{0} ** 512;
    var writer: std.Io.Writer = .fixed(&bytes);

    try writeAll(&writer, jedec, "test");
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "*L00000 10101010") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "*C0055") != null);
}
