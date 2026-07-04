// SPDX-License-Identifier: GPL-3.0-or-later

const std = @import("std");
const endian = @import("../core/endian.zig");
const logic = @import("../core/logic.zig");
const model = @import("../core/model.zig");
const protocol_bytes = @import("protocol_bytes.zig");
const transport = @import("transport.zig");
const t48 = @import("t48.zig");

const command = protocol_bytes.command;
const packet = protocol_bytes.packet;

pub const Error = transport.Error || error{
    Overcurrent,
};

pub const Device = t48.Device;
pub const Status = t48.Status;
pub const FuseKind = t48.FuseKind;
pub const ChipId = t48.ChipId;
pub const JedecRow = t48.JedecRow;

pub fn uploadBitstream(trans: transport.Transport, bitstream: []const u8) Error!void {
    var msg = [_]u8{0} ** packet.bitstream_header_len;
    msg[0] = command.write_bitstream;
    endian.storeInt(msg[4..8], bitstream.len, .little);
    try trans.send(&msg);
    try trans.send(bitstream);
}

pub fn beginTransaction(trans: transport.Transport, device: Device, bitstream: []const u8) Error!void {
    try uploadBitstream(trans, bitstream);

    var msg: [packet.begin_len]u8 = undefined;
    t48.writeBeginPacket(&msg, .t56, device);

    try trans.send(&msg);
    const status = try requestStatus(trans);
    if (status.overcurrent != 0) return Error.Overcurrent;
}

pub fn endTransaction(trans: transport.Transport) Error!void {
    var msg = [_]u8{0} ** packet.short_command_len;
    msg[0] = command.end_transaction;
    try trans.send(&msg);
}

pub fn readBlock(trans: transport.Transport, kind: model.MemoryKind, address: u32, out: []u8) Error!void {
    if (out.len > packet.t56_read_payload_max) return transport.Error.Io;

    var msg = [_]u8{0} ** packet.begin_len;
    msg[0] = readCommand(kind);
    endian.storeInt(msg[2..4], out.len, .little);
    endian.storeInt(msg[4..8], address, .little);
    try trans.send(msg[0..packet.short_command_len]);

    // Upstream asks for a slightly larger USB buffer to tolerate a T56 firmware off-by-one bug.
    var response = [_]u8{0} ** (packet.t56_read_payload_max + packet.t56_read_status_slop);
    _ = try trans.recv(response[0 .. out.len + packet.t56_read_status_slop]);
    @memcpy(out, response[0..out.len]);
}

pub fn writeBlock(trans: transport.Transport, device: Device, kind: model.MemoryKind, address: u32, data: []const u8) Error!void {
    if (device.write_buffer_size > packet.t56_padded_write_payload_max or data.len > device.write_buffer_size) return transport.Error.Io;

    var msg = [_]u8{0} ** packet.short_command_len;
    msg[0] = writeCommand(kind);
    endian.storeInt(msg[2..4], data.len, .little);
    endian.storeInt(msg[4..8], address, .little);
    try trans.send(&msg);

    var buffer = [_]u8{0} ** packet.t56_padded_write_payload_max;
    @memcpy(buffer[0..data.len], data);
    try trans.send(buffer[0..device.write_buffer_size]);
}

pub fn readFuses(trans: transport.Transport, device: Device, kind: FuseKind, items_count: u8, out: []u8) Error!void {
    var msg = [_]u8{0} ** packet.fuse_len;
    if (out.len > msg.len - packet.short_command_len) return transport.Error.Io;
    msg[0] = readFuseCommand(kind);
    msg[1] = device.protocol_id;
    msg[2] = items_count;
    endian.storeInt(msg[4..8], device.code_memory_size, .little);
    try trans.send(msg[0..packet.short_command_len]);
    _ = try trans.recv(&msg);
    @memcpy(out, msg[8 .. 8 + out.len]);
}

pub fn writeFuses(trans: transport.Transport, device: Device, kind: FuseKind, items_count: u8, data: []const u8) Error!void {
    var msg = [_]u8{0} ** packet.fuse_len;
    if (data.len > msg.len - packet.short_command_len) return transport.Error.Io;
    msg[0] = writeFuseCommand(kind);
    msg[1] = device.protocol_id;
    msg[2] = items_count;
    endian.storeInt(msg[4..8], device.code_memory_size -| 0x38, .little);
    @memcpy(msg[8 .. 8 + data.len], data);
    try trans.send(&msg);
}

pub fn getChipId(trans: transport.Transport, chip_id_bytes_count: u8) Error!ChipId {
    var request = [_]u8{0} ** packet.short_command_len;
    request[0] = command.read_id;
    try trans.send(&request);

    var response = [_]u8{0} ** packet.chip_id_len;
    _ = try trans.recv(&response);
    const id_type = response[0];
    const id_length = @min(chip_id_bytes_count, 4);
    const value: u32 = if (id_length == 0) 0 else switch (id_type) {
        3, 4 => @intCast(endian.loadInt(response[2 .. 2 + id_length], .little)),
        else => @intCast(endian.loadInt(response[2 .. 2 + id_length], .big)),
    };
    return .{ .id_type = id_type, .value = value };
}

pub fn spiAutodetect(trans: transport.Transport, package_pins: u8) t48.Error!u32 {
    return t48.spiAutodetect(trans, package_pins);
}

pub fn erase(trans: transport.Transport, num_fuses: u8, pld: u8) Error!void {
    var msg = [_]u8{0} ** packet.erase_len;
    msg[0] = command.erase;
    msg[2] = num_fuses;
    msg[4] = pld;
    try trans.send(&msg);
    var response = [_]u8{0} ** packet.erase_response_len;
    _ = try trans.recv(&response);
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

pub fn readJedecRow(trans: transport.Transport, device: Device, row: JedecRow) Error!void {
    var msg = [_]u8{0} ** packet.jedec_read_len;
    const byte_count = rowByteCount(row.size_bits);
    if (row.data.len < byte_count) return transport.Error.Io;
    msg[0] = command.read_jedec;
    msg[1] = device.protocol_id;
    msg[2] = row.size_bits;
    msg[4] = row.row;
    msg[5] = row.flags;
    try trans.send(msg[0..packet.short_command_len]);
    _ = try trans.recv(&msg);
    @memcpy(row.data[0..byte_count], msg[0..byte_count]);
}

pub fn writeJedecRow(trans: transport.Transport, device: Device, row: JedecRow) Error!void {
    var msg = [_]u8{0} ** packet.jedec_write_len;
    const byte_count = rowByteCount(row.size_bits);
    if (row.data.len < byte_count) return transport.Error.Io;
    msg[0] = command.write_jedec;
    msg[1] = device.protocol_id;
    msg[2] = row.size_bits;
    msg[4] = row.row;
    msg[5] = row.flags;
    @memcpy(msg[8 .. 8 + byte_count], row.data[0..byte_count]);
    try trans.send(&msg);
}

pub fn requestStatus(trans: transport.Transport) Error!Status {
    var request = [_]u8{0} ** packet.short_command_len;
    request[0] = command.request_status;
    try trans.send(&request);

    var response = [_]u8{0} ** packet.status_len;
    _ = try trans.recv(&response);
    return .{
        .error_code = response[0],
        .address = @intCast(endian.loadInt(response[8..12], .little)),
        .c1 = @intCast(endian.loadInt(response[2..4], .little)),
        .c2 = @intCast(endian.loadInt(response[4..6], .little)),
        .overcurrent = response[12],
    };
}

pub fn testLogicVector(trans: transport.Transport, vcc_index: u8, pull_down: bool, pin_count: u16, vector_index: u32, states: []const logic.State, out: []u8) t48.Error!void {
    return t48.testLogicVector(trans, vcc_index, pull_down, pin_count, vector_index, states, out);
}

fn readCommand(kind: model.MemoryKind) u8 {
    return switch (kind) {
        .code => command.read_code,
        .data => command.read_data,
        .user => command.read_user_data,
    };
}

fn writeCommand(kind: model.MemoryKind) u8 {
    return switch (kind) {
        .code => command.write_code,
        .data => command.write_data,
        .user => command.write_user_data,
    };
}

fn readFuseCommand(kind: FuseKind) u8 {
    return switch (kind) {
        .user => command.read_user,
        .config => command.read_config,
        .lock => command.read_lock,
    };
}

fn writeFuseCommand(kind: FuseKind) u8 {
    return switch (kind) {
        .user => command.write_user,
        .config => command.write_config,
        .lock => command.write_lock,
    };
}

fn rowByteCount(size_bits: u8) usize {
    return (@as(usize, size_bits) + 7) / 8;
}

test "upload T56 bitstream packet" {
    var fake = transport.FakeTransport.init(std.testing.allocator, &.{});
    defer fake.deinit();

    try uploadBitstream(fake.transport(), &.{ 1, 2, 3 });
    try std.testing.expectEqualSlices(u8, &.{ 0x26, 0, 0, 0, 3, 0, 0, 0, 1, 2, 3 }, fake.sent.items);
}

test "begin T56 transaction uploads bitstream before begin packet" {
    var response = [_]u8{0} ** 32;
    response[12] = 0;
    var fake = transport.FakeTransport.init(std.testing.allocator, &response);
    defer fake.deinit();

    const device = Device{
        .protocol_id = 0x07,
        .variant = 0x4101,
        .voltages_raw = 0x1234,
        .chip_info = 0x06,
        .pin_map = 0x22,
        .data_memory_size = 0x20,
        .data_memory2_size = 0x30,
        .page_size = 0x40,
        .pulse_delay = 0x50,
        .code_memory_size = 0x123456,
        .package_details_raw = 0xaabbccdd,
        .read_buffer_size = 0x200,
        .write_buffer_size = 0x100,
        .flags_raw = 0x01020304,
    };

    try beginTransaction(fake.transport(), device, &.{ 0xaa, 0xbb });
    try std.testing.expectEqual(@as(usize, 8 + 2 + 64 + 8), fake.sent.items.len);
    try std.testing.expectEqual(@as(u8, command.write_bitstream), fake.sent.items[0]);
    try std.testing.expectEqualSlices(u8, &.{ 2, 0, 0, 0 }, fake.sent.items[4..8]);
    try std.testing.expectEqualSlices(u8, &.{ 0xaa, 0xbb }, fake.sent.items[8..10]);

    const begin = fake.sent.items[10..74];
    try std.testing.expectEqual(@as(u8, command.begin_transaction), begin[0]);
    try std.testing.expectEqual(@as(u8, 0x07), begin[1]);
    try std.testing.expectEqual(@as(u8, 0x01), begin[2]);
    try std.testing.expectEqualSlices(u8, &.{ 0x56, 0x34, 0x12, 0x00 }, begin[16..20]);
    try std.testing.expectEqualSlices(u8, &.{ 0xdd, 0xcc, 0xbb, 0xaa }, begin[40..44]);
    try std.testing.expectEqual(@as(u8, command.request_status), fake.sent.items[74]);
}

test "read and write T56 memory blocks" {
    var fake = transport.FakeTransport.init(std.testing.allocator, &.{ 1, 2, 3, 4 });
    defer fake.deinit();

    var out = [_]u8{0} ** 4;
    try readBlock(fake.transport(), .code, 0x1234, &out);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4 }, &out);
    try std.testing.expectEqualSlices(u8, &.{ 0x0d, 0, 4, 0, 0x34, 0x12, 0, 0 }, fake.sent.items[0..8]);

    const device = Device{
        .protocol_id = 0x07,
        .variant = 0,
        .voltages_raw = 0,
        .chip_info = 0,
        .pin_map = 0,
        .data_memory_size = 0,
        .data_memory2_size = 0,
        .page_size = 0,
        .pulse_delay = 0,
        .code_memory_size = 0,
        .package_details_raw = 0,
        .read_buffer_size = 0,
        .write_buffer_size = 8,
        .flags_raw = 0,
    };
    try writeBlock(fake.transport(), device, .data, 0x20, &.{ 9, 8, 7 });
    try std.testing.expectEqualSlices(u8, &.{ 0x11, 0, 3, 0, 0x20, 0, 0, 0 }, fake.sent.items[8..16]);
    try std.testing.expectEqualSlices(u8, &.{ 9, 8, 7, 0, 0, 0, 0, 0 }, fake.sent.items[16..24]);
}

test "T56 memory blocks reject oversized buffers before sending" {
    var response = [_]u8{0} ** 1;
    var fake = transport.FakeTransport.init(std.testing.allocator, &response);
    defer fake.deinit();

    var out = [_]u8{0} ** (packet.t56_read_payload_max + 1);
    try std.testing.expectError(transport.Error.Io, readBlock(fake.transport(), .code, 0, &out));

    var device = Device{
        .protocol_id = 0x07,
        .variant = 0,
        .voltages_raw = 0,
        .chip_info = 0,
        .pin_map = 0,
        .data_memory_size = 0,
        .data_memory2_size = 0,
        .page_size = 0,
        .pulse_delay = 0,
        .code_memory_size = 0,
        .package_details_raw = 0,
        .read_buffer_size = 0,
        .write_buffer_size = 2,
        .flags_raw = 0,
    };
    try std.testing.expectError(transport.Error.Io, writeBlock(fake.transport(), device, .data, 0, &.{ 1, 2, 3 }));

    device.write_buffer_size = packet.t56_padded_write_payload_max + 1;
    try std.testing.expectError(transport.Error.Io, writeBlock(fake.transport(), device, .data, 0, &.{1}));

    try std.testing.expectEqual(@as(usize, 0), fake.sent.items.len);
}

test "read and write T56 fuses and chip ID" {
    var response = [_]u8{0} ** 64;
    response[8] = 0xaa;
    response[9] = 0xbb;
    var fake = transport.FakeTransport.init(std.testing.allocator, &response);
    defer fake.deinit();

    const device = Device{
        .protocol_id = 0x21,
        .variant = 0,
        .voltages_raw = 0,
        .chip_info = 0,
        .pin_map = 0,
        .data_memory_size = 0,
        .data_memory2_size = 0,
        .page_size = 0,
        .pulse_delay = 0,
        .code_memory_size = 0x1000,
        .package_details_raw = 0,
        .read_buffer_size = 0,
        .write_buffer_size = 0,
        .flags_raw = 0,
    };
    var fuses = [_]u8{0} ** 2;
    try readFuses(fake.transport(), device, .config, 2, &fuses);
    try std.testing.expectEqualSlices(u8, &.{ 0xaa, 0xbb }, &fuses);
    try std.testing.expectEqualSlices(u8, &.{ 0x08, 0x21, 2, 0, 0, 0x10, 0, 0 }, fake.sent.items[0..8]);

    try writeFuses(fake.transport(), device, .lock, 1, &.{0x5a});
    try std.testing.expectEqual(@as(u8, 0x14), fake.sent.items[8]);
    try std.testing.expectEqual(@as(u8, 0x21), fake.sent.items[9]);
    try std.testing.expectEqualSlices(u8, &.{ 0xc8, 0x0f, 0, 0 }, fake.sent.items[12..16]);
    try std.testing.expectEqual(@as(u8, 0x5a), fake.sent.items[16]);

    response[0] = 1;
    response[2] = 0x12;
    response[3] = 0x34;
    const id = try getChipId(fake.transport(), 2);
    try std.testing.expectEqual(@as(u8, 1), id.id_type);
    try std.testing.expectEqual(@as(u32, 0x1234), id.value);
}

test "erase and protect commands send upstream T56 opcodes" {
    var response = [_]u8{0} ** 64;
    var fake = transport.FakeTransport.init(std.testing.allocator, &response);
    defer fake.deinit();

    try erase(fake.transport(), 2, 0x3f);
    try protectOff(fake.transport());
    try protectOn(fake.transport());

    try std.testing.expectEqual(@as(usize, 15 + 8 + 8), fake.sent.items.len);
    try std.testing.expectEqual(@as(u8, command.erase), fake.sent.items[0]);
    try std.testing.expectEqual(@as(u8, 2), fake.sent.items[2]);
    try std.testing.expectEqual(@as(u8, 0x3f), fake.sent.items[4]);
    try std.testing.expectEqual(@as(u8, command.protect_off), fake.sent.items[15]);
    try std.testing.expectEqual(@as(u8, command.protect_on), fake.sent.items[23]);
}

test "read and write T56 JEDEC rows" {
    var response = [_]u8{0} ** 32;
    response[0] = 0x12;
    response[1] = 0x34;
    var fake = transport.FakeTransport.init(std.testing.allocator, &response);
    defer fake.deinit();

    const device = Device{
        .protocol_id = 0x2a,
        .variant = 0,
        .voltages_raw = 0,
        .chip_info = 0,
        .pin_map = 0,
        .data_memory_size = 0,
        .data_memory2_size = 0,
        .page_size = 0,
        .pulse_delay = 0,
        .code_memory_size = 0,
        .package_details_raw = 0,
        .read_buffer_size = 0,
        .write_buffer_size = 0,
        .flags_raw = 0,
    };

    var read_data = [_]u8{0} ** 2;
    try readJedecRow(fake.transport(), device, .{ .data = &read_data, .size_bits = 16, .row = 7, .flags = 3 });
    try std.testing.expectEqualSlices(u8, &.{ 0x12, 0x34 }, &read_data);
    try std.testing.expectEqualSlices(u8, &.{ 0x1d, 0x2a, 16, 0, 7, 3, 0, 0 }, fake.sent.items[0..8]);

    var write_data = [_]u8{ 0xab, 0xcd };
    try writeJedecRow(fake.transport(), device, .{ .data = &write_data, .size_bits = 16, .row = 8, .flags = 4 });
    try std.testing.expectEqual(@as(u8, command.write_jedec), fake.sent.items[8]);
    try std.testing.expectEqual(@as(u8, 0x2a), fake.sent.items[9]);
    try std.testing.expectEqual(@as(u8, 16), fake.sent.items[10]);
    try std.testing.expectEqual(@as(u8, 8), fake.sent.items[12]);
    try std.testing.expectEqual(@as(u8, 4), fake.sent.items[13]);
    try std.testing.expectEqualSlices(u8, &.{ 0xab, 0xcd }, fake.sent.items[16..18]);
}
