// SPDX-License-Identifier: GPL-3.0-or-later

const std = @import("std");
const crc = @import("crc.zig");
const endian = @import("endian.zig");
const model = @import("model.zig");

const algo_size_offset = 0x00;
const algo_crc_offset = 0x04;
const algo_data_offset = 0x08;
const t56_padding = 0x200;

pub fn decode(allocator: std.mem.Allocator, programmer: model.Programmer, base64_gzip: []const u8) ![]u8 {
    const gzip = try decodeBase64(allocator, base64_gzip);
    defer allocator.free(gzip);

    const inflated = try inflateGzip(allocator, gzip);
    defer allocator.free(inflated);

    try validateCrc(inflated);

    return switch (programmer) {
        .t56 => padT56(allocator, inflated),
        .t76 => expandT76(allocator, inflated),
        else => error.UnsupportedProgrammer,
    };
}

pub fn decodeBase64(allocator: std.mem.Allocator, encoded: []const u8) ![]u8 {
    const size = try std.base64.standard.Decoder.calcSizeForSlice(encoded);
    const out = try allocator.alloc(u8, size);
    errdefer allocator.free(out);
    try std.base64.standard.Decoder.decode(out, encoded);
    return out;
}

pub fn inflateGzip(allocator: std.mem.Allocator, gzip: []const u8) ![]u8 {
    var input: std.Io.Reader = .fixed(gzip);
    var allocating: std.Io.Writer.Allocating = .init(allocator);
    errdefer allocating.deinit();

    var decompress: std.compress.flate.Decompress = .init(&input, .gzip, &.{});
    _ = try decompress.reader.streamRemaining(&allocating.writer);
    return try allocating.toOwnedSlice();
}

pub fn validateCrc(bitstream: []const u8) !void {
    if (bitstream.len < algo_data_offset) return error.InvalidAlgorithm;
    const expected: u32 = @intCast(endian.loadInt(bitstream[algo_crc_offset .. algo_crc_offset + 4], .little));
    const actual = crc.crc32(bitstream[algo_data_offset..], 0xffffffff);
    if (expected != actual) return error.BadAlgorithmCrc;
}

pub fn padT56(allocator: std.mem.Allocator, bitstream: []const u8) ![]u8 {
    const padded_len = bitstream.len + (t56_padding - (bitstream.len % t56_padding));
    const out = try allocator.alloc(u8, padded_len);
    @memcpy(out[0..bitstream.len], bitstream);
    @memset(out[bitstream.len..], 0);
    return out;
}

pub fn expandT76(allocator: std.mem.Allocator, bitstream: []const u8) ![]u8 {
    if (bitstream.len < algo_data_offset) return error.InvalidAlgorithm;
    if ((bitstream.len - algo_data_offset) % 2 != 0) return error.InvalidAlgorithm;

    const out_len: usize = @intCast(endian.loadInt(bitstream[algo_size_offset .. algo_size_offset + 4], .little));
    if (out_len % 2 != 0) return error.InvalidAlgorithm;

    const out = try allocator.alloc(u8, out_len);
    errdefer allocator.free(out);
    @memset(out, 0);

    var in_index: usize = algo_data_offset;
    var out_index: usize = 0;
    while (in_index < bitstream.len) {
        const value: u16 = @intCast(endian.loadInt(bitstream[in_index .. in_index + 2], .little));
        in_index += 2;
        if (value != 0) {
            if (out_index + 2 > out.len) return error.InvalidAlgorithm;
            endian.storeInt(out[out_index .. out_index + 2], value, .little);
            out_index += 2;
        } else {
            if (in_index + 2 > bitstream.len) return error.InvalidAlgorithm;
            const zero_words: usize = @intCast(endian.loadInt(bitstream[in_index .. in_index + 2], .little));
            in_index += 2;
            if (out_index + zero_words * 2 > out.len) return error.InvalidAlgorithm;
            out_index += zero_words * 2;
        }
    }
    if (out_index != out.len) return error.InvalidAlgorithm;
    return out;
}

test "decode base64 payload" {
    const decoded = try decodeBase64(std.testing.allocator, "AQIDBA==");
    defer std.testing.allocator.free(decoded);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4 }, decoded);
}

test "validate algorithm CRC and T56 padding" {
    var bitstream = [_]u8{0} ** 12;
    endian.storeInt(bitstream[0..4], 4, .little);
    @memcpy(bitstream[algo_data_offset..], &.{ 1, 2, 3, 4 });
    endian.storeInt(bitstream[algo_crc_offset .. algo_crc_offset + 4], crc.crc32(bitstream[algo_data_offset..], 0xffffffff), .little);
    try validateCrc(&bitstream);

    const padded = try padT56(std.testing.allocator, &bitstream);
    defer std.testing.allocator.free(padded);
    try std.testing.expectEqual(@as(usize, 512), padded.len);
    try std.testing.expectEqualSlices(u8, &bitstream, padded[0..bitstream.len]);
}

test "expand T76 zero-run encoded bitstream" {
    var encoded = [_]u8{0} ** 16;
    endian.storeInt(encoded[0..4], 8, .little);
    endian.storeInt(encoded[8..10], 0x1234, .little);
    endian.storeInt(encoded[10..12], 0, .little);
    endian.storeInt(encoded[12..14], 2, .little);
    endian.storeInt(encoded[14..16], 0xabcd, .little);
    endian.storeInt(encoded[4..8], crc.crc32(encoded[8..], 0xffffffff), .little);

    try validateCrc(&encoded);
    const expanded = try expandT76(std.testing.allocator, &encoded);
    defer std.testing.allocator.free(expanded);
    try std.testing.expectEqualSlices(u8, &.{ 0x34, 0x12, 0, 0, 0, 0, 0xcd, 0xab }, expanded);
}
