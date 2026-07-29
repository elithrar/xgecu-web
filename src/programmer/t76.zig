// SPDX-License-Identifier: Apache-2.0

const std = @import("std");
const endian = @import("../core/endian.zig");
const model = @import("../core/model.zig");
const protocol_bytes = @import("protocol_bytes.zig");
const transport = @import("transport.zig");
const t48 = @import("t48.zig");

const command = protocol_bytes.command;
const packet = protocol_bytes.packet;

const bitstream_begin: u8 = 0x00;
const bitstream_block: u8 = 0x01;
const bitstream_end: u8 = 0x02;
const reset_fpga: u8 = 0xaf;
const fpga_magic: u32 = 0xaa55ddee;

pub const Error = transport.Error || std.mem.Allocator.Error || error{
    InvalidAlgorithm,
    Overcurrent,
    ProgrammerStatusError,
};

pub const Device = t48.Device;
pub const Status = t48.Status;
pub const ChipId = t48.ChipId;

pub fn uploadBitstream(trans: transport.Transport, bitstream: []const u8) Error!void {
    if (bitstream.len == 0 or bitstream.len > std.math.maxInt(u32)) return error.InvalidAlgorithm;
    var frame = [_]u8{0} ** packet.t76_bitstream_packet_len;

    frame[0] = command.write_bitstream;
    frame[1] = bitstream_begin;
    endian.storeInt(frame[2..4], packet.t76_bitstream_packet_len, .little);
    endian.storeInt(frame[4..8], bitstream.len, .little);
    try trans.send(frame[0..packet.short_command_len]);
    try readBitstreamAck(trans, &frame);

    var offset: usize = 0;
    while (offset < bitstream.len) {
        const len = @min(packet.t76_bitstream_payload_len, bitstream.len - offset);
        @memset(&frame, 0);
        frame[0] = command.write_bitstream;
        frame[1] = bitstream_block;
        endian.storeInt(frame[2..4], len, .little);
        @memcpy(frame[packet.short_command_len .. packet.short_command_len + len], bitstream[offset .. offset + len]);
        try trans.send(&frame);
        offset += len;
    }

    @memset(&frame, 0);
    frame[0] = command.write_bitstream;
    frame[1] = bitstream_end;
    try trans.send(frame[0..packet.short_command_len]);
    try readBitstreamAck(trans, &frame);
}

pub fn resetFpga(trans: transport.Transport) Error!void {
    var msg = [_]u8{0} ** packet.short_command_len;
    msg[0] = command.write_bitstream;
    msg[1] = reset_fpga;
    endian.storeInt(msg[4..8], fpga_magic, .little);
    try trans.send(&msg);
    var response = [_]u8{0} ** packet.short_command_len;
    const received = try trans.recv(&response);
    if (received < response.len or response[1] != 0) return error.ProgrammerStatusError;
}

pub fn beginTransaction(trans: transport.Transport, device: Device, bitstream: []const u8) Error!void {
    try uploadBitstream(trans, bitstream);
    errdefer resetFpga(trans) catch {};
    try beginLoadedTransaction(trans, device);
}

pub fn beginLoadedTransaction(trans: transport.Transport, device: Device) Error!void {
    var msg: [packet.begin_len]u8 = undefined;
    writeBeginPacket(&msg, device);
    errdefer endTransaction(trans) catch {};
    try trans.send(&msg);
    const status = try requestStatus(trans);
    if (status.overcurrent != 0) return error.Overcurrent;
    if (status.error_code != 0) return error.ProgrammerStatusError;
}

pub fn writeBeginPacket(msg: *[packet.begin_len]u8, device: Device) void {
    @memset(msg, 0);
    msg[0] = command.begin_transaction;
    msg[1] = device.protocol_id;
    msg[2] = @truncate(device.variant);
    msg[3] = device.icsp;
    endian.storeInt(msg[4..6], device.voltages_raw, .little);
    msg[6] = @truncate(device.chip_info);
    msg[7] = @truncate(device.pin_map);
    endian.storeInt(msg[8..10], device.data_memory_size, .little);
    endian.storeInt(msg[10..12], device.page_size, .little);
    endian.storeInt(msg[12..14], device.pulse_delay, .little);
    endian.storeInt(msg[14..16], device.data_memory2_size, .little);
    endian.storeInt(msg[16..20], device.code_memory_size, .little);
    msg[20] = @truncate(device.voltages_raw >> 16);
    if (device.voltages_raw & 0xf0 == 0xf0) {
        msg[22] = @truncate(device.voltages_raw);
    } else {
        msg[21] = @truncate(device.voltages_raw & 0x0f);
        msg[22] = @truncate(device.voltages_raw & 0xf0);
    }
    if (device.voltages_raw & 0x80000000 != 0) msg[22] = @truncate((device.voltages_raw >> 16) & 0x0f);
    if (device.can_adjust_clock) msg[28] = device.spi_clock;
    endian.storeInt(msg[40..44], device.package_details_raw, .little);
    endian.storeInt(msg[44..46], device.read_buffer_size, .little);
    endian.storeInt(msg[56..60], device.flags_raw, .little);
    msg[63] = @truncate(device.variant >> 8);
}

pub fn endTransaction(trans: transport.Transport) Error!void {
    var msg = [_]u8{0} ** packet.short_command_len;
    msg[0] = command.end_transaction;
    try trans.send(&msg);
}

pub fn readCodeBlock(trans: transport.Transport, device: Device, address: u32, operation_size: usize, out: []u8) Error!void {
    if (out.len == 0 or out.len > std.math.maxInt(u16) or operation_size == 0 or operation_size > device.code_memory_size or !validAddressRange(address, out.len)) return transport.Error.Io;
    if (address == 0) {
        var msg = [_]u8{0} ** packet.t76_code_frame_header_len;
        msg[0] = command.read_code;
        endian.storeInt(msg[2..4], out.len, .little);
        endian.storeInt(msg[4..8], address, .little);
        const block_count = (operation_size + out.len - 1) / out.len;
        endian.storeInt(msg[8..12], block_count, .little);
        try trans.send(&msg);
    }
    try trans.readPayload(out, 0);
}

pub fn writeCodeBlock(
    allocator: std.mem.Allocator,
    trans: transport.Transport,
    device: Device,
    address: u32,
    operation_size: usize,
    data: []const u8,
) Error!void {
    if (data.len == 0 or data.len > std.math.maxInt(u16) or data.len > device.write_buffer_size or operation_size == 0 or operation_size > device.code_memory_size or !validAddressRange(address, data.len)) return transport.Error.Io;
    var header = [_]u8{0} ** packet.t76_code_frame_header_len;
    header[0] = command.write_code;
    endian.storeInt(header[2..4], data.len, .little);
    endian.storeInt(header[4..8], address, .little);
    endian.storeInt(header[12..16], data.len, .little);
    if (address == 0) {
        const block_count = (operation_size + device.write_buffer_size - 1) / device.write_buffer_size;
        endian.storeInt(header[8..12], block_count, .little);
        try trans.send(&header);
        @memset(header[8..12], 0);
    }

    const frame = try allocator.alloc(u8, header.len + data.len);
    defer allocator.free(frame);
    @memcpy(frame[0..header.len], &header);
    @memcpy(frame[header.len..], data);
    try trans.writePayload(frame, 0);
}

pub fn getChipId(trans: transport.Transport, chip_id_bytes_count: u8) Error!ChipId {
    var request = [_]u8{0} ** packet.short_command_len;
    request[0] = command.read_id;
    try trans.send(&request);
    var response = [_]u8{0} ** packet.chip_id_len;
    const received = try trans.recv(&response);
    const id_length = @min(chip_id_bytes_count, 4);
    if (received < 2 + id_length) return transport.Error.Io;
    const id_type = response[0];
    const value: u32 = if (id_length == 0) 0 else switch (id_type) {
        3, 4 => @intCast(endian.loadInt(response[2 .. 2 + id_length], .little)),
        else => @intCast(endian.loadInt(response[2 .. 2 + id_length], .big)),
    };
    return .{ .id_type = id_type, .value = value };
}

pub fn erase(trans: transport.Transport, num_fuses: u8, pld: u8) Error!void {
    var msg = [_]u8{0} ** packet.t76_code_frame_header_len;
    msg[0] = command.erase;
    msg[2] = num_fuses;
    msg[4] = pld;
    try trans.send(&msg);
    var response = [_]u8{0} ** packet.erase_response_len;
    const received = try trans.recv(&response);
    if (received < response.len) return transport.Error.Io;
    if (response[12] != 0) return error.Overcurrent;
    if (response[0] != 0) return error.ProgrammerStatusError;
}

pub fn protectOff(trans: transport.Transport) Error!void {
    var msg = [_]u8{0} ** packet.short_command_len;
    msg[0] = command.protect_off;
    try trans.send(&msg);
}

pub fn protectOn(trans: transport.Transport) Error!void {
    var msg = [_]u8{0} ** packet.short_command_len;
    msg[0] = command.protect_on;
    try trans.send(&msg);
}

pub fn requestStatus(trans: transport.Transport) Error!Status {
    var request = [_]u8{0} ** packet.short_command_len;
    request[0] = command.request_status;
    try trans.send(&request);
    var response = [_]u8{0} ** packet.status_len;
    const received = try trans.recv(&response);
    if (received < 13) return transport.Error.Io;
    return .{
        .error_code = response[0],
        .address = @intCast(endian.loadInt(response[8..12], .little)),
        .c1 = @intCast(endian.loadInt(response[2..4], .little)),
        .c2 = @intCast(endian.loadInt(response[4..6], .little)),
        .overcurrent = response[12],
    };
}

fn readBitstreamAck(trans: transport.Transport, buffer: *[packet.t76_bitstream_packet_len]u8) Error!void {
    const received = try trans.recv(buffer[0..packet.short_command_len]);
    if (received < packet.short_command_len or buffer[1] != 0) return error.ProgrammerStatusError;
}

fn validAddressRange(address: u32, len: usize) bool {
    return @as(u64, address) + len <= @as(u64, std.math.maxInt(u32)) + 1;
}

test "T76 begin descriptor includes algorithm number and ROM attributes" {
    const device = Device{
        .protocol_id = 0x07,
        .variant = 0x3313,
        .voltages_raw = 0x5070,
        .chip_info = 0x0006,
        .pin_map = 0x0c16,
        .data_memory_size = 0,
        .data_memory2_size = 0,
        .page_size = 0,
        .pulse_delay = 100,
        .code_memory_size = 0x10000,
        .package_details_raw = 0x1c000000,
        .read_buffer_size = 0x400,
        .write_buffer_size = 0x80,
        .flags_raw = 0x68,
    };
    var msg: [packet.begin_len]u8 = undefined;
    writeBeginPacket(&msg, device);
    try std.testing.expectEqual(@as(u8, command.begin_transaction), msg[0]);
    try std.testing.expectEqual(@as(u8, 0x13), msg[2]);
    try std.testing.expectEqual(@as(u8, 0x33), msg[63]);
    try std.testing.expectEqual(@as(u64, 0x10000), endian.loadInt(msg[16..20], .little));
    try std.testing.expectEqual(@as(u64, 0x400), endian.loadInt(msg[44..46], .little));

    var status = [_]u8{0} ** packet.status_len;
    var fake = transport.FakeTransport.init(std.testing.allocator, &status);
    defer fake.deinit();
    try beginLoadedTransaction(fake.transport(), device);
    try std.testing.expectEqual(@as(usize, packet.begin_len + packet.short_command_len), fake.sent.items.len);
    try std.testing.expectEqual(command.begin_transaction, fake.sent.items[0]);
    try std.testing.expectEqual(command.request_status, fake.sent.items[packet.begin_len]);
}

test "T76 code write uses init command and framed payload" {
    var fake = transport.FakeTransport.init(std.testing.allocator, &.{});
    defer fake.deinit();
    const device = Device{
        .protocol_id = 0,
        .variant = 0,
        .voltages_raw = 0,
        .chip_info = 0,
        .pin_map = 0,
        .data_memory_size = 0,
        .data_memory2_size = 0,
        .page_size = 0,
        .pulse_delay = 0,
        .code_memory_size = 256,
        .package_details_raw = 0,
        .read_buffer_size = 64,
        .write_buffer_size = 128,
        .flags_raw = 0,
    };
    try writeCodeBlock(std.testing.allocator, fake.transport(), device, 0, 3, &.{ 1, 2, 3 });
    try std.testing.expectEqual(@as(usize, 16), fake.sent.items.len);
    try std.testing.expectEqual(@as(u8, command.write_code), fake.sent.items[0]);
    try std.testing.expectEqual(@as(u64, 1), endian.loadInt(fake.sent.items[8..12], .little));
    try std.testing.expectEqual(@as(usize, 19), fake.payload_sent.items.len);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3 }, fake.payload_sent.items[16..19]);
}

test "T76 code read advertises the requested operation block count" {
    var response = [_]u8{0xff} ** 128;
    var fake = transport.FakeTransport.init(std.testing.allocator, &response);
    fake.payload_response = &response;
    defer fake.deinit();
    const device = Device{
        .protocol_id = 0,
        .variant = 0,
        .voltages_raw = 0,
        .chip_info = 0,
        .pin_map = 0,
        .data_memory_size = 0,
        .data_memory2_size = 0,
        .page_size = 0,
        .pulse_delay = 0,
        .code_memory_size = 256,
        .package_details_raw = 0,
        .read_buffer_size = 128,
        .write_buffer_size = 128,
        .flags_raw = 0,
    };
    var out = [_]u8{0} ** 128;

    try readCodeBlock(fake.transport(), device, 0, 129, &out);

    try std.testing.expectEqual(@as(usize, 16), fake.sent.items.len);
    try std.testing.expectEqual(@as(u64, 2), endian.loadInt(fake.sent.items[8..12], .little));
}

test "T76 protection commands do not poll status" {
    var fake = transport.FakeTransport.init(std.testing.allocator, &.{});
    defer fake.deinit();

    try protectOff(fake.transport());
    try protectOn(fake.transport());

    try std.testing.expectEqual(@as(usize, packet.short_command_len * 2), fake.sent.items.len);
    try std.testing.expectEqual(command.protect_off, fake.sent.items[0]);
    try std.testing.expectEqual(command.protect_on, fake.sent.items[packet.short_command_len]);
}
