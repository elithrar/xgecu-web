// SPDX-License-Identifier: GPL-3.0-or-later

const std = @import("std");
const endian = @import("../core/endian.zig");
const logic = @import("../core/logic.zig");
const model = @import("../core/model.zig");
const transport = @import("transport.zig");
const t48 = @import("t48.zig");

const t56_begin_trans = 0x03;
const t56_end_trans = 0x04;
const t56_read_id = 0x05;
const t56_read_user = 0x06;
const t56_write_user = 0x07;
const t56_read_cfg = 0x08;
const t56_write_cfg = 0x09;
const t56_write_user_data = 0x0a;
const t56_read_user_data = 0x0b;
const t56_write_code = 0x0c;
const t56_read_code = 0x0d;
const t56_erase = 0x0e;
const t56_read_data = 0x10;
const t56_write_data = 0x11;
const t56_write_lock = 0x14;
const t56_read_lock = 0x15;
const t56_protect_off = 0x18;
const t56_protect_on = 0x19;
const t56_read_jedec = 0x1d;
const t56_write_jedec = 0x1e;
const t56_write_bitstream = 0x26;
const t56_request_status = 0x39;

pub const Error = transport.Error || error{
    Overcurrent,
};

pub const Device = t48.Device;
pub const Status = t48.Status;
pub const FuseKind = t48.FuseKind;
pub const ChipId = t48.ChipId;
pub const JedecRow = t48.JedecRow;

pub fn uploadBitstream(trans: transport.Transport, bitstream: []const u8) Error!void {
    var msg = [_]u8{0} ** 8;
    msg[0] = t56_write_bitstream;
    endian.storeInt(msg[4..8], bitstream.len, .little);
    try trans.send(&msg);
    try trans.send(bitstream);
}

pub fn beginTransaction(trans: transport.Transport, device: Device, bitstream: []const u8) Error!void {
    try uploadBitstream(trans, bitstream);

    var msg = [_]u8{0} ** 64;
    msg[0] = t56_begin_trans;
    msg[1] = device.protocol_id;
    msg[2] = @intCast(device.variant & 0xff);
    msg[3] = device.icsp;
    endian.storeInt(msg[4..6], device.voltages_raw, .little);
    msg[6] = @intCast(device.chip_info & 0xff);
    msg[7] = @intCast(device.pin_map & 0xff);
    endian.storeInt(msg[8..10], device.data_memory_size, .little);
    endian.storeInt(msg[10..12], device.page_size, .little);
    endian.storeInt(msg[12..14], device.pulse_delay, .little);
    endian.storeInt(msg[14..16], device.data_memory2_size, .little);
    endian.storeInt(msg[16..20], device.code_memory_size, .little);
    msg[20] = @intCast((device.voltages_raw >> 16) & 0xff);
    if (device.voltages_raw & 0xf0 == 0xf0) {
        msg[22] = @intCast(device.voltages_raw & 0xff);
    } else {
        msg[21] = @intCast(device.voltages_raw & 0x0f);
        msg[22] = @intCast(device.voltages_raw & 0xf0);
    }
    if (device.voltages_raw & 0x80000000 != 0) msg[22] = @intCast((device.voltages_raw >> 16) & 0x0f);
    if (device.can_adjust_clock) msg[28] = device.spi_clock;
    endian.storeInt(msg[40..44], device.package_details_raw, .little);
    endian.storeInt(msg[44..46], device.read_buffer_size, .little);
    endian.storeInt(msg[56..60], device.flags_raw, .little);

    try trans.send(&msg);
    const status = try requestStatus(trans);
    if (status.overcurrent != 0) return Error.Overcurrent;
}

pub fn endTransaction(trans: transport.Transport) Error!void {
    var msg = [_]u8{0} ** 8;
    msg[0] = t56_end_trans;
    try trans.send(&msg);
}

pub fn readBlock(trans: transport.Transport, kind: model.MemoryKind, address: u32, out: []u8) Error!void {
    var msg = [_]u8{0} ** 64;
    msg[0] = try readCommand(kind);
    endian.storeInt(msg[2..4], out.len, .little);
    endian.storeInt(msg[4..8], address, .little);
    try trans.send(msg[0..8]);

    // Upstream asks for a slightly larger USB buffer to tolerate a T56 firmware off-by-one bug.
    var response = [_]u8{0} ** 80;
    if (out.len > response.len - 16) return transport.Error.Io;
    _ = try trans.recv(response[0 .. out.len + 16]);
    @memcpy(out, response[0..out.len]);
}

pub fn writeBlock(trans: transport.Transport, device: Device, kind: model.MemoryKind, address: u32, data: []const u8) Error!void {
    var msg = [_]u8{0} ** 8;
    msg[0] = try writeCommand(kind);
    endian.storeInt(msg[2..4], data.len, .little);
    endian.storeInt(msg[4..8], address, .little);
    try trans.send(&msg);

    var buffer = [_]u8{0} ** 4096;
    if (device.write_buffer_size > buffer.len or data.len > device.write_buffer_size) return transport.Error.Io;
    @memcpy(buffer[0..data.len], data);
    try trans.send(buffer[0..device.write_buffer_size]);
}

pub fn readFuses(trans: transport.Transport, device: Device, kind: FuseKind, items_count: u8, out: []u8) Error!void {
    var msg = [_]u8{0} ** 64;
    msg[0] = readFuseCommand(kind);
    msg[1] = device.protocol_id;
    msg[2] = items_count;
    endian.storeInt(msg[4..8], device.code_memory_size, .little);
    try trans.send(msg[0..8]);
    _ = try trans.recv(&msg);
    if (out.len > msg.len - 8) return transport.Error.Io;
    @memcpy(out, msg[8 .. 8 + out.len]);
}

pub fn writeFuses(trans: transport.Transport, device: Device, kind: FuseKind, items_count: u8, data: []const u8) Error!void {
    var msg = [_]u8{0} ** 64;
    if (data.len > msg.len - 8) return transport.Error.Io;
    msg[0] = writeFuseCommand(kind);
    msg[1] = device.protocol_id;
    msg[2] = items_count;
    endian.storeInt(msg[4..8], device.code_memory_size -| 0x38, .little);
    @memcpy(msg[8 .. 8 + data.len], data);
    try trans.send(&msg);
}

pub fn getChipId(trans: transport.Transport, chip_id_bytes_count: u8) Error!ChipId {
    var request = [_]u8{0} ** 8;
    request[0] = t56_read_id;
    try trans.send(&request);

    var response = [_]u8{0} ** 32;
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
    var msg = [_]u8{0} ** 15;
    msg[0] = t56_erase;
    msg[2] = num_fuses;
    msg[4] = pld;
    try trans.send(&msg);
    var response = [_]u8{0} ** 64;
    _ = try trans.recv(&response);
}

pub fn protectOff(trans: transport.Transport) Error!void {
    var msg = [_]u8{0} ** 8;
    msg[0] = t56_protect_off;
    try trans.send(&msg);
}

pub fn protectOn(trans: transport.Transport) Error!void {
    var msg = [_]u8{0} ** 8;
    msg[0] = t56_protect_on;
    try trans.send(&msg);
}

pub fn readJedecRow(trans: transport.Transport, device: Device, row: JedecRow) Error!void {
    var msg = [_]u8{0} ** 32;
    msg[0] = t56_read_jedec;
    msg[1] = device.protocol_id;
    msg[2] = row.size_bits;
    msg[4] = row.row;
    msg[5] = row.flags;
    try trans.send(msg[0..8]);
    _ = try trans.recv(&msg);
    const byte_count = rowByteCount(row.size_bits);
    if (row.data.len < byte_count) return transport.Error.Io;
    @memcpy(row.data[0..byte_count], msg[0..byte_count]);
}

pub fn writeJedecRow(trans: transport.Transport, device: Device, row: JedecRow) Error!void {
    var msg = [_]u8{0} ** 64;
    const byte_count = rowByteCount(row.size_bits);
    if (row.data.len < byte_count) return transport.Error.Io;
    msg[0] = t56_write_jedec;
    msg[1] = device.protocol_id;
    msg[2] = row.size_bits;
    msg[4] = row.row;
    msg[5] = row.flags;
    @memcpy(msg[8 .. 8 + byte_count], row.data[0..byte_count]);
    try trans.send(&msg);
}

pub fn requestStatus(trans: transport.Transport) Error!Status {
    var request = [_]u8{0} ** 8;
    request[0] = t56_request_status;
    try trans.send(&request);

    var response = [_]u8{0} ** 32;
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

fn readCommand(kind: model.MemoryKind) !u8 {
    return switch (kind) {
        .code => t56_read_code,
        .data => t56_read_data,
        .user => t56_read_user_data,
    };
}

fn writeCommand(kind: model.MemoryKind) !u8 {
    return switch (kind) {
        .code => t56_write_code,
        .data => t56_write_data,
        .user => t56_write_user_data,
    };
}

fn readFuseCommand(kind: FuseKind) u8 {
    return switch (kind) {
        .user => t56_read_user,
        .config => t56_read_cfg,
        .lock => t56_read_lock,
    };
}

fn writeFuseCommand(kind: FuseKind) u8 {
    return switch (kind) {
        .user => t56_write_user,
        .config => t56_write_cfg,
        .lock => t56_write_lock,
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
    try std.testing.expectEqual(@as(u8, t56_write_bitstream), fake.sent.items[0]);
    try std.testing.expectEqualSlices(u8, &.{ 2, 0, 0, 0 }, fake.sent.items[4..8]);
    try std.testing.expectEqualSlices(u8, &.{ 0xaa, 0xbb }, fake.sent.items[8..10]);

    const begin = fake.sent.items[10..74];
    try std.testing.expectEqual(@as(u8, t56_begin_trans), begin[0]);
    try std.testing.expectEqual(@as(u8, 0x07), begin[1]);
    try std.testing.expectEqual(@as(u8, 0x01), begin[2]);
    try std.testing.expectEqualSlices(u8, &.{ 0x56, 0x34, 0x12, 0x00 }, begin[16..20]);
    try std.testing.expectEqualSlices(u8, &.{ 0xdd, 0xcc, 0xbb, 0xaa }, begin[40..44]);
    try std.testing.expectEqual(@as(u8, t56_request_status), fake.sent.items[74]);
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
    try std.testing.expectEqual(@as(u8, t56_erase), fake.sent.items[0]);
    try std.testing.expectEqual(@as(u8, 2), fake.sent.items[2]);
    try std.testing.expectEqual(@as(u8, 0x3f), fake.sent.items[4]);
    try std.testing.expectEqual(@as(u8, t56_protect_off), fake.sent.items[15]);
    try std.testing.expectEqual(@as(u8, t56_protect_on), fake.sent.items[23]);
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
    try std.testing.expectEqual(@as(u8, t56_write_jedec), fake.sent.items[8]);
    try std.testing.expectEqual(@as(u8, 0x2a), fake.sent.items[9]);
    try std.testing.expectEqual(@as(u8, 16), fake.sent.items[10]);
    try std.testing.expectEqual(@as(u8, 8), fake.sent.items[12]);
    try std.testing.expectEqual(@as(u8, 4), fake.sent.items[13]);
    try std.testing.expectEqualSlices(u8, &.{ 0xab, 0xcd }, fake.sent.items[16..18]);
}
