// SPDX-License-Identifier: GPL-3.0-or-later

const std = @import("std");
const endian = @import("../core/endian.zig");
const logic = @import("../core/logic.zig");
const model = @import("../core/model.zig");
const transport = @import("transport.zig");
const t48 = @import("t48.zig");

const t76_begin_trans = 0x03;
const t76_end_trans = 0x04;
const t76_read_id = 0x05;
const t76_read_user = 0x06;
const t76_write_user = 0x07;
const t76_read_cfg = 0x08;
const t76_write_cfg = 0x09;
const t76_write_user_data = 0x0a;
const t76_read_user_data = 0x0b;
const t76_write_code = 0x0c;
const t76_read_code = 0x0d;
const t76_erase = 0x0e;
const t76_read_data = 0x10;
const t76_write_data = 0x11;
const t76_write_lock = 0x14;
const t76_read_lock = 0x15;
const t76_protect_off = 0x18;
const t76_protect_on = 0x19;
const t76_read_jedec = 0x1d;
const t76_write_jedec = 0x1e;
const t76_write_bitstream = 0x26;
const t76_request_status = 0x39;

const t76_begin_bs = 0x00;
const t76_bs_block = 0x01;
const t76_end_bs = 0x02;
const bs_packet_size = 0x200;
const bs_payload_size = bs_packet_size - 8;

pub const Error = transport.Error || error{
    Overcurrent,
    BitstreamRejected,
};

pub const Device = t48.Device;
pub const Status = t48.Status;
pub const JedecRow = t48.JedecRow;
pub const FuseKind = t48.FuseKind;
pub const ChipId = t48.ChipId;

pub fn uploadBitstream(trans: transport.Transport, bitstream: []const u8) Error!void {
    var msg = [_]u8{0} ** bs_packet_size;
    msg[0] = t76_write_bitstream;
    msg[1] = t76_begin_bs;
    endian.storeInt(msg[2..4], bs_packet_size, .little);
    endian.storeInt(msg[4..8], bitstream.len, .little);
    try trans.send(msg[0..8]);
    if (try ackFailed(trans)) return Error.BitstreamRejected;

    var offset: usize = 0;
    while (offset < bitstream.len) : (offset += bs_payload_size) {
        @memset(&msg, 0);
        const block_size = @min(bs_payload_size, bitstream.len - offset);
        msg[0] = t76_write_bitstream;
        msg[1] = t76_bs_block;
        endian.storeInt(msg[2..4], block_size, .little);
        @memcpy(msg[8 .. 8 + block_size], bitstream[offset .. offset + block_size]);
        try trans.send(&msg);
    }

    var end = [_]u8{0} ** 8;
    end[0] = t76_write_bitstream;
    end[1] = t76_end_bs;
    try trans.send(&end);
    if (try ackFailed(trans)) return Error.BitstreamRejected;
}

pub fn beginTransaction(trans: transport.Transport, device: Device, bitstream: []const u8) Error!void {
    try uploadBitstream(trans, bitstream);

    var msg = [_]u8{0} ** 64;
    msg[0] = t76_begin_trans;
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
    if (device.can_adjust_address) msg[24] = device.i2c_address;
    if (device.can_adjust_clock) msg[28] = device.spi_clock;
    endian.storeInt(msg[40..44], device.package_details_raw, .little);
    endian.storeInt(msg[44..46], device.read_buffer_size, .little);
    endian.storeInt(msg[56..60], device.flags_raw, .little);
    msg[63] = @intCast((device.variant >> 8) & 0xff);

    try trans.send(&msg);
    const status = try requestStatus(trans);
    if (status.overcurrent != 0) return Error.Overcurrent;
}

pub fn endTransaction(trans: transport.Transport) Error!void {
    var msg = [_]u8{0} ** 8;
    msg[0] = t76_end_trans;
    try trans.send(&msg);
}

pub fn readBlock(trans: transport.Transport, kind: model.MemoryKind, address: u32, out: []u8) Error!void {
    var msg = [_]u8{0} ** 16;
    msg[0] = try readCommand(kind);
    endian.storeInt(msg[2..4], out.len, .little);
    endian.storeInt(msg[4..8], address, .little);
    try trans.send(&msg);

    switch (kind) {
        .code => try trans.readPayload(out, 0),
        .data => {
            var buffer = [_]u8{0} ** 4096;
            if (out.len + 16 > buffer.len) return transport.Error.Io;
            try trans.readPayload(buffer[0 .. out.len + 16], 0);
            @memcpy(out, buffer[16 .. 16 + out.len]);
        },
        .user => {
            var buffer = [_]u8{0} ** 4096;
            if (out.len + 16 > buffer.len) return transport.Error.Io;
            _ = try trans.recv(buffer[0 .. out.len + 16]);
            @memcpy(out, buffer[16 .. 16 + out.len]);
        },
    }
}

pub fn writeBlock(trans: transport.Transport, kind: model.MemoryKind, address: u32, data: []const u8) Error!void {
    var msg = [_]u8{0} ** 64;
    msg[0] = try writeCommand(kind);
    endian.storeInt(msg[2..4], data.len, .little);
    endian.storeInt(msg[4..8], address, .little);
    endian.storeInt(msg[12..16], data.len, .little);

    switch (kind) {
        .code => {
            try trans.send(msg[0..16]);
            @memset(msg[8..12], 0);
            var buffer = [_]u8{0} ** 4096;
            if (data.len + 16 > buffer.len) return transport.Error.Io;
            @memcpy(buffer[0..16], msg[0..16]);
            @memcpy(buffer[16 .. 16 + data.len], data);
            try trans.writePayload(buffer[0 .. 16 + data.len], 0);
        },
        .data => {
            try trans.send(msg[0..16]);
            try trans.writePayload(data, 0);
        },
        .user => {
            if (data.len + 16 > msg.len) return transport.Error.Io;
            @memcpy(msg[16 .. 16 + data.len], data);
            try trans.send(msg[0 .. 16 + data.len]);
        },
    }
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
    request[0] = t76_read_id;
    try trans.send(&request);

    var response = [_]u8{0} ** 32;
    _ = try trans.recv(&response);
    const id_type = response[0];
    const id_len = @min(chip_id_bytes_count, 4);
    const byte_order: endian.Endian = if (id_type == 3 or id_type == 4) .little else .big;
    const value: u32 = if (id_len == 0) 0 else @intCast(endian.loadInt(response[2 .. 2 + id_len], byte_order));
    return .{ .id_type = id_type, .value = value };
}

pub fn spiAutodetect(trans: transport.Transport, package_pins: u8) t48.Error!u32 {
    return t48.spiAutodetect(trans, package_pins);
}

pub fn erase(trans: transport.Transport, num_fuses: u8, pld: u8) Error!void {
    var msg = [_]u8{0} ** 16;
    msg[0] = t76_erase;
    msg[2] = num_fuses;
    msg[4] = pld;
    try trans.send(&msg);
    var response = [_]u8{0} ** 64;
    _ = try trans.recv(&response);
}

pub fn protectOff(trans: transport.Transport) Error!void {
    var msg = [_]u8{0} ** 8;
    msg[0] = t76_protect_off;
    try trans.send(&msg);
}

pub fn protectOn(trans: transport.Transport) Error!void {
    var msg = [_]u8{0} ** 8;
    msg[0] = t76_protect_on;
    try trans.send(&msg);
}

pub fn readJedecRow(trans: transport.Transport, row: JedecRow) Error!void {
    var msg = [_]u8{0} ** 32;
    msg[0] = t76_read_jedec;
    msg[1] = row.row_type;
    msg[2] = row.size_bits;
    msg[4] = row.row;
    msg[5] = row.flags;
    try trans.send(msg[0..8]);
    _ = try trans.recv(&msg);
    const byte_count = rowByteCount(row.size_bits);
    if (row.data.len < byte_count) return transport.Error.Io;
    @memcpy(row.data[0..byte_count], msg[0..byte_count]);
}

pub fn writeJedecRow(trans: transport.Transport, row: JedecRow) Error!void {
    var msg = [_]u8{0} ** 64;
    const byte_count = rowByteCount(row.size_bits);
    if (row.data.len < byte_count) return transport.Error.Io;
    msg[0] = t76_write_jedec;
    msg[1] = row.row_type;
    msg[2] = row.size_bits;
    msg[4] = row.row;
    msg[5] = row.flags;
    @memcpy(msg[8 .. 8 + byte_count], row.data[0..byte_count]);
    try trans.send(&msg);
}

pub fn requestStatus(trans: transport.Transport) Error!Status {
    var request = [_]u8{0} ** 8;
    request[0] = t76_request_status;
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

fn ackFailed(trans: transport.Transport) transport.Error!bool {
    var response = [_]u8{0} ** 8;
    _ = try trans.recv(&response);
    return response[1] != 0;
}

fn rowByteCount(size_bits: u8) usize {
    return (@as(usize, size_bits) + 7) / 8;
}

fn readCommand(kind: model.MemoryKind) !u8 {
    return switch (kind) {
        .code => t76_read_code,
        .data => t76_read_data,
        .user => t76_read_user_data,
    };
}

fn writeCommand(kind: model.MemoryKind) !u8 {
    return switch (kind) {
        .code => t76_write_code,
        .data => t76_write_data,
        .user => t76_write_user_data,
    };
}

fn readFuseCommand(kind: FuseKind) u8 {
    return switch (kind) {
        .user => t76_read_user,
        .config => t76_read_cfg,
        .lock => t76_read_lock,
    };
}

fn writeFuseCommand(kind: FuseKind) u8 {
    return switch (kind) {
        .user => t76_write_user,
        .config => t76_write_cfg,
        .lock => t76_write_lock,
    };
}

test "upload T76 bitstream in 512-byte packets" {
    var ack = [_]u8{0} ** 8;
    var fake = transport.FakeTransport.init(std.testing.allocator, &ack);
    defer fake.deinit();

    var bitstream = [_]u8{0xaa} ** 505;
    try uploadBitstream(fake.transport(), &bitstream);

    try std.testing.expectEqual(@as(usize, 8 + 512 + 512 + 8), fake.sent.items.len);
    try std.testing.expectEqual(@as(u8, t76_write_bitstream), fake.sent.items[0]);
    try std.testing.expectEqual(@as(u8, t76_begin_bs), fake.sent.items[1]);
    try std.testing.expectEqual(@as(u64, bs_packet_size), endian.loadInt(fake.sent.items[2..4], .little));
    try std.testing.expectEqual(@as(u64, 505), endian.loadInt(fake.sent.items[4..8], .little));
    try std.testing.expectEqual(@as(u8, t76_bs_block), fake.sent.items[9]);
    try std.testing.expectEqual(@as(u64, 504), endian.loadInt(fake.sent.items[10..12], .little));
    try std.testing.expectEqual(@as(u8, t76_bs_block), fake.sent.items[521]);
    try std.testing.expectEqual(@as(u64, 1), endian.loadInt(fake.sent.items[522..524], .little));
    try std.testing.expectEqual(@as(u8, t76_end_bs), fake.sent.items[1033]);
}

test "begin T76 transaction includes algorithm number" {
    var ack = [_]u8{0} ** 32;
    var fake = transport.FakeTransport.init(std.testing.allocator, &ack);
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

    try beginTransaction(fake.transport(), device, &.{0xbb});
    const begin = fake.sent.items[8 + 512 + 8 ..][0..64];
    try std.testing.expectEqual(@as(u8, t76_begin_trans), begin[0]);
    try std.testing.expectEqual(@as(u8, 0x07), begin[1]);
    try std.testing.expectEqual(@as(u8, 0x01), begin[2]);
    try std.testing.expectEqual(@as(u8, 0x41), begin[63]);
    try std.testing.expectEqual(@as(u8, t76_request_status), fake.sent.items[8 + 512 + 8 + 64]);
}

test "T76 erase protect and JEDEC row packets" {
    var response = [_]u8{0} ** 64;
    response[0] = 0x12;
    response[1] = 0x34;
    var fake = transport.FakeTransport.init(std.testing.allocator, &response);
    defer fake.deinit();

    try erase(fake.transport(), 2, 0x3f);
    try protectOff(fake.transport());
    try protectOn(fake.transport());
    try std.testing.expectEqual(@as(u8, t76_erase), fake.sent.items[0]);
    try std.testing.expectEqual(@as(u8, 2), fake.sent.items[2]);
    try std.testing.expectEqual(@as(u8, 0x3f), fake.sent.items[4]);
    try std.testing.expectEqual(@as(u8, t76_protect_off), fake.sent.items[16]);
    try std.testing.expectEqual(@as(u8, t76_protect_on), fake.sent.items[24]);

    var read_data = [_]u8{0} ** 2;
    try readJedecRow(fake.transport(), .{ .data = &read_data, .size_bits = 16, .row = 7, .flags = 3, .row_type = 2 });
    try std.testing.expectEqualSlices(u8, &.{ 0x12, 0x34 }, &read_data);
    try std.testing.expectEqualSlices(u8, &.{ 0x1d, 2, 16, 0, 7, 3, 0, 0 }, fake.sent.items[32..40]);

    var write_data = [_]u8{ 0xab, 0xcd };
    try writeJedecRow(fake.transport(), .{ .data = &write_data, .size_bits = 16, .row = 8, .flags = 4, .row_type = 2 });
    try std.testing.expectEqual(@as(u8, t76_write_jedec), fake.sent.items[40]);
    try std.testing.expectEqual(@as(u8, 2), fake.sent.items[41]);
    try std.testing.expectEqualSlices(u8, &.{ 0xab, 0xcd }, fake.sent.items[48..50]);
}

test "T76 memory block helpers use upstream command shapes" {
    var response = [_]u8{0} ** 64;
    var payload = [_]u8{0} ** 32;
    payload[16] = 0xde;
    payload[17] = 0xad;
    payload[18] = 0xbe;
    payload[19] = 0xef;
    var fake = transport.FakeTransport.init(std.testing.allocator, &response);
    fake.payload_response = &payload;
    defer fake.deinit();

    var out = [_]u8{0} ** 4;
    try readBlock(fake.transport(), .data, 0x1234, &out);
    try std.testing.expectEqualSlices(u8, &.{ 0xde, 0xad, 0xbe, 0xef }, &out);
    try std.testing.expectEqualSlices(u8, &.{ 0x10, 0, 4, 0, 0x34, 0x12, 0, 0 }, fake.sent.items[0..8]);

    try writeBlock(fake.transport(), .code, 0x20, &.{ 1, 2, 3 });
    try std.testing.expectEqualSlices(u8, &.{ 0x0c, 0, 3, 0, 0x20, 0, 0, 0 }, fake.sent.items[16..24]);
    try std.testing.expectEqualSlices(u8, &.{ 0x0c, 0, 3, 0, 0x20, 0, 0, 0 }, fake.payload_sent.items[0..8]);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3 }, fake.payload_sent.items[16..19]);
}

test "T76 fuses and chip ID helpers" {
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
    try std.testing.expectEqualSlices(u8, &.{ 0xc8, 0x0f, 0, 0 }, fake.sent.items[12..16]);

    response[0] = 3;
    response[2] = 0x34;
    response[3] = 0x12;
    const id = try getChipId(fake.transport(), 2);
    try std.testing.expectEqual(@as(u8, 3), id.id_type);
    try std.testing.expectEqual(@as(u32, 0x1234), id.value);
}
