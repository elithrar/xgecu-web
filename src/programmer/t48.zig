// SPDX-License-Identifier: GPL-3.0-or-later

const std = @import("std");
const endian = @import("../core/endian.zig");
const logic = @import("../core/logic.zig");
const model = @import("../core/model.zig");
const transport = @import("transport.zig");

const t48_begin_trans = 0x03;
const t48_end_trans = 0x04;
const t48_read_id = 0x05;
const t48_read_user = 0x06;
const t48_write_user = 0x07;
const t48_read_cfg = 0x08;
const t48_write_cfg = 0x09;
const t48_read_user_data = 0x0b;
const t48_write_user_data = 0x0a;
const t48_write_code = 0x0c;
const t48_read_code = 0x0d;
const t48_erase = 0x0e;
const t48_read_data = 0x10;
const t48_write_data = 0x11;
const t48_write_lock = 0x14;
const t48_read_lock = 0x15;
const t48_protect_off = 0x18;
const t48_protect_on = 0x19;
const t48_read_jedec = 0x1d;
const t48_write_jedec = 0x1e;
const t48_logic_ic_test_vector = 0x28;
const t48_autodetect = 0x37;
const t48_request_status = 0x39;

pub const Error = transport.Error || logic.Error || error{
    UnknownMemoryKind,
    Overcurrent,
};

pub const Device = struct {
    protocol_id: u8,
    variant: u32,
    icsp: u8 = 0,
    voltages_raw: u32,
    chip_info: u32,
    pin_map: u32,
    data_memory_size: u32,
    data_memory2_size: u32,
    page_size: u32,
    pulse_delay: u32,
    code_memory_size: u32,
    package_details_raw: u32,
    read_buffer_size: u16,
    write_buffer_size: u16,
    flags_raw: u32,
    spi_clock: u8 = 0,
    can_adjust_clock: bool = false,
    i2c_address: u8 = 0,
    can_adjust_address: bool = false,
};

pub fn deviceFromProtocolInfo(info: anytype, icsp: u8, spi_clock: u8) Device {
    return .{
        .protocol_id = info.protocol_id,
        .variant = info.variant,
        .icsp = icsp,
        .voltages_raw = info.voltages_raw,
        .chip_info = info.chip_info,
        .pin_map = info.pin_map,
        .data_memory_size = info.data_memory_size,
        .data_memory2_size = info.data_memory2_size,
        .page_size = info.page_size,
        .pulse_delay = info.pulse_delay,
        .code_memory_size = info.code_memory_size,
        .package_details_raw = info.package_details_raw,
        .read_buffer_size = info.read_buffer_size,
        .write_buffer_size = info.write_buffer_size,
        .flags_raw = info.flags_raw,
        .spi_clock = spi_clock,
        .can_adjust_clock = info.can_adjust_clock,
    };
}

pub const Status = struct {
    error_code: u8,
    address: u32,
    c1: u16,
    c2: u16,
    overcurrent: u8,
};

pub const ChipId = struct {
    id_type: u8,
    value: u32,
};

pub const FuseKind = enum {
    user,
    config,
    lock,
};

pub const JedecRow = struct {
    data: []u8,
    size_bits: u8,
    row: u8,
    flags: u8,
    row_type: u8 = 0,
};

pub fn beginTransaction(trans: transport.Transport, device: Device) Error!void {
    var msg = [_]u8{0} ** 64;
    msg[0] = t48_begin_trans;
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
    if (device.can_adjust_clock) {
        msg[24] = 1;
        msg[28] = device.spi_clock;
    }
    endian.storeInt(msg[40..44], device.package_details_raw, .little);
    endian.storeInt(msg[44..46], device.read_buffer_size, .little);
    endian.storeInt(msg[56..60], device.flags_raw, .little);

    try trans.send(&msg);
    const status = try requestStatus(trans);
    if (status.overcurrent != 0) return Error.Overcurrent;
}

pub fn endTransaction(trans: transport.Transport) Error!void {
    var msg = [_]u8{0} ** 8;
    msg[0] = t48_end_trans;
    try trans.send(&msg);
}

pub fn readBlock(trans: transport.Transport, kind: model.MemoryKind, address: u32, out: []u8) Error!void {
    var msg = [_]u8{0} ** 8;
    msg[0] = try readCommand(kind);
    endian.storeInt(msg[2..4], out.len, .little);
    endian.storeInt(msg[4..8], address, .little);
    try trans.send(&msg);
    try trans.readPayload(out, 0);
}

pub fn writeBlock(trans: transport.Transport, kind: model.MemoryKind, address: u32, data: []const u8) Error!void {
    var msg = [_]u8{0} ** 8;
    msg[0] = try writeCommand(kind);
    endian.storeInt(msg[2..4], data.len, .little);
    endian.storeInt(msg[4..8], address, .little);
    try trans.send(&msg);
    try trans.writePayload(data, 0);
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

pub fn readJedecRow(trans: transport.Transport, device: Device, row: JedecRow) Error!void {
    var msg = [_]u8{0} ** 32;
    msg[0] = t48_read_jedec;
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
    msg[0] = t48_write_jedec;
    msg[1] = device.protocol_id;
    msg[2] = row.size_bits;
    msg[4] = row.row;
    msg[5] = row.flags;
    @memcpy(msg[8 .. 8 + byte_count], row.data[0..byte_count]);
    try trans.send(&msg);
}

pub fn getChipId(trans: transport.Transport, chip_id_bytes_count: u8) Error!ChipId {
    var request = [_]u8{0} ** 8;
    request[0] = t48_read_id;
    try trans.send(&request);

    var response = [_]u8{0} ** 32;
    _ = try trans.recv(&response);
    const id_type = response[0];
    const id_len = @min(chip_id_bytes_count, 4);
    const byte_order: endian.Endian = if (id_type == 3 or id_type == 4) .little else .big;
    const value: u32 = if (id_len == 0) 0 else @intCast(endian.loadInt(response[2 .. 2 + id_len], byte_order));
    return .{ .id_type = id_type, .value = value };
}

pub fn spiAutodetect(trans: transport.Transport, package_pins: u8) Error!u32 {
    var msg = [_]u8{0} ** 64;
    msg[0] = t48_autodetect;
    msg[8] = if (package_pins == 16) 1 else 0;
    try trans.send(msg[0..10]);
    _ = try trans.recv(msg[0..32]);
    return @intCast(endian.loadInt(msg[2..5], .big));
}

pub fn erase(trans: transport.Transport, num_fuses: u8, pld: u8) Error!void {
    var msg = [_]u8{0} ** 15;
    msg[0] = t48_erase;
    msg[2] = num_fuses;
    msg[4] = pld;
    try trans.send(&msg);
    var response = [_]u8{0} ** 64;
    _ = try trans.recv(&response);
}

pub fn protectOff(trans: transport.Transport) Error!void {
    var msg = [_]u8{0} ** 8;
    msg[0] = t48_protect_off;
    try trans.send(&msg);
}

pub fn protectOn(trans: transport.Transport) Error!void {
    var msg = [_]u8{0} ** 8;
    msg[0] = t48_protect_on;
    try trans.send(&msg);
}

pub fn requestStatus(trans: transport.Transport) Error!Status {
    var msg = [_]u8{0} ** 32;
    msg[0] = t48_request_status;
    try trans.send(msg[0..8]);
    @memset(&msg, 0);
    _ = try trans.recv(&msg);
    return .{
        .error_code = msg[0],
        .address = @intCast(endian.loadInt(msg[8..12], .little)),
        .c1 = @intCast(endian.loadInt(msg[2..4], .little)),
        .c2 = @intCast(endian.loadInt(msg[4..6], .little)),
        .overcurrent = msg[12],
    };
}

pub fn testLogicVector(trans: transport.Transport, vcc_index: u8, pull_down: bool, pin_count: u16, vector_index: u32, states: []const logic.State, out: []u8) Error!void {
    const pin_len: usize = pin_count;
    if (states.len < pin_len or out.len < pin_len or pin_count > 48) return Error.ShortVector;
    var msg = [_]u8{0xff} ** 32;
    msg[0] = t48_logic_ic_test_vector;
    msg[1] = vcc_index;
    if (pull_down) msg[1] |= 0x80;
    endian.storeInt(msg[2..4], pin_count, .little);
    endian.storeInt(msg[4..8], vector_index, .little);
    try logic.packNibbles(msg[8..], states[0..pin_len]);
    try trans.send(&msg);
    _ = try trans.recv(&msg);
    if (msg[1] != 0) return Error.Overcurrent;
    try logic.unpackNibbles(out, msg[8..], pin_len);
}

fn readCommand(kind: model.MemoryKind) Error!u8 {
    return switch (kind) {
        .code => t48_read_code,
        .data => t48_read_data,
        .user => t48_read_user_data,
    };
}

fn writeCommand(kind: model.MemoryKind) Error!u8 {
    return switch (kind) {
        .code => t48_write_code,
        .data => t48_write_data,
        .user => t48_write_user_data,
    };
}

fn readFuseCommand(kind: FuseKind) u8 {
    return switch (kind) {
        .user => t48_read_user,
        .config => t48_read_cfg,
        .lock => t48_read_lock,
    };
}

fn writeFuseCommand(kind: FuseKind) u8 {
    return switch (kind) {
        .user => t48_write_user,
        .config => t48_write_cfg,
        .lock => t48_write_lock,
    };
}

fn rowByteCount(size_bits: u8) usize {
    return (@as(usize, size_bits) + 7) / 8;
}

test "begin transaction sends upstream T48 packet fields" {
    var status_response = [_]u8{0} ** 32;
    var fake = transport.FakeTransport.init(std.testing.allocator, &status_response);
    defer fake.deinit();

    try beginTransaction(fake.transport(), .{
        .protocol_id = 0x07,
        .variant = 0x4226,
        .voltages_raw = 0x00000200,
        .chip_info = 0,
        .pin_map = 0x14,
        .data_memory_size = 0,
        .data_memory2_size = 0,
        .page_size = 64,
        .pulse_delay = 0x2710,
        .code_memory_size = 8192,
        .package_details_raw = 0x1c000000,
        .read_buffer_size = 512,
        .write_buffer_size = 128,
        .flags_raw = 0x0000c010,
    });

    try std.testing.expectEqual(@as(usize, 72), fake.sent.items.len);
    const begin = fake.sent.items[0..64];
    try std.testing.expectEqual(@as(u8, t48_begin_trans), begin[0]);
    try std.testing.expectEqual(@as(u8, 0x07), begin[1]);
    try std.testing.expectEqual(@as(u8, 0x26), begin[2]);
    try std.testing.expectEqual(@as(u64, 8192), endian.loadInt(begin[16..20], .little));
    try std.testing.expectEqual(@as(u64, 0x1c000000), endian.loadInt(begin[40..44], .little));
    try std.testing.expectEqual(@as(u64, 512), endian.loadInt(begin[44..46], .little));
    try std.testing.expectEqual(@as(u8, t48_request_status), fake.sent.items[64]);
}

test "read and write block use T48 commands and payload API" {
    var response = [_]u8{0} ** 32;
    var payload = [_]u8{ 0xde, 0xad, 0xbe, 0xef };
    var fake = transport.FakeTransport.init(std.testing.allocator, &response);
    fake.payload_response = &payload;
    defer fake.deinit();

    var out = [_]u8{0} ** 4;
    try readBlock(fake.transport(), .code, 0x1234, &out);
    try std.testing.expectEqualSlices(u8, &payload, &out);
    try std.testing.expectEqual(@as(u8, t48_read_code), fake.sent.items[0]);
    try std.testing.expectEqual(@as(u64, 4), endian.loadInt(fake.sent.items[2..4], .little));
    try std.testing.expectEqual(@as(u64, 0x1234), endian.loadInt(fake.sent.items[4..8], .little));

    try writeBlock(fake.transport(), .data, 0x20, &payload);
    try std.testing.expectEqualSlices(u8, &payload, fake.payload_sent.items);
    try std.testing.expectEqual(@as(u8, t48_write_data), fake.sent.items[8]);
}

test "get chip ID decodes big and little endian ID formats" {
    var response = [_]u8{0} ** 32;
    response[0] = 1;
    response[2] = 0x1f;
    response[3] = 0xaa;
    response[4] = 0x55;
    var fake = transport.FakeTransport.init(std.testing.allocator, &response);
    defer fake.deinit();

    const big = try getChipId(fake.transport(), 3);
    try std.testing.expectEqual(@as(u8, t48_read_id), fake.sent.items[0]);
    try std.testing.expectEqual(@as(u8, 1), big.id_type);
    try std.testing.expectEqual(@as(u32, 0x1faa55), big.value);

    response[0] = 3;
    response[2] = 0x34;
    response[3] = 0x12;
    fake.response = &response;
    const little = try getChipId(fake.transport(), 2);
    try std.testing.expectEqual(@as(u8, 3), little.id_type);
    try std.testing.expectEqual(@as(u32, 0x1234), little.value);
}

test "SPI autodetect sends package type and decodes 24-bit ID" {
    var response = [_]u8{0} ** 32;
    response[2] = 0xef;
    response[3] = 0x40;
    response[4] = 0x17;
    var fake = transport.FakeTransport.init(std.testing.allocator, &response);
    defer fake.deinit();

    const id = try spiAutodetect(fake.transport(), 16);
    try std.testing.expectEqual(@as(u8, t48_autodetect), fake.sent.items[0]);
    try std.testing.expectEqual(@as(u8, 1), fake.sent.items[8]);
    try std.testing.expectEqual(@as(u32, 0xef4017), id);
}

test "erase sends T48 erase packet and consumes response" {
    var response = [_]u8{0} ** 64;
    var fake = transport.FakeTransport.init(std.testing.allocator, &response);
    defer fake.deinit();

    try erase(fake.transport(), 2, 1);
    try std.testing.expectEqual(@as(usize, 15), fake.sent.items.len);
    try std.testing.expectEqual(@as(u8, t48_erase), fake.sent.items[0]);
    try std.testing.expectEqual(@as(u8, 2), fake.sent.items[2]);
    try std.testing.expectEqual(@as(u8, 1), fake.sent.items[4]);
}

test "protect commands send upstream T48 opcodes" {
    var response = [_]u8{0} ** 1;
    var fake = transport.FakeTransport.init(std.testing.allocator, &response);
    defer fake.deinit();

    try protectOff(fake.transport());
    try protectOn(fake.transport());
    try std.testing.expectEqual(@as(usize, 16), fake.sent.items.len);
    try std.testing.expectEqual(@as(u8, t48_protect_off), fake.sent.items[0]);
    try std.testing.expectEqual(@as(u8, t48_protect_on), fake.sent.items[8]);
}

test "read fuses sends T48 fuse request and extracts response payload" {
    var response = [_]u8{0} ** 64;
    response[8] = 0xaa;
    response[9] = 0x55;
    var fake = transport.FakeTransport.init(std.testing.allocator, &response);
    defer fake.deinit();

    var out = [_]u8{0} ** 2;
    try readFuses(fake.transport(), .{
        .protocol_id = 0x22,
        .variant = 0,
        .voltages_raw = 0,
        .chip_info = 0,
        .pin_map = 0,
        .data_memory_size = 0,
        .data_memory2_size = 0,
        .page_size = 0,
        .pulse_delay = 0,
        .code_memory_size = 0x1234,
        .package_details_raw = 0,
        .read_buffer_size = 0,
        .write_buffer_size = 0,
        .flags_raw = 0,
    }, .config, 3, &out);

    try std.testing.expectEqual(@as(u8, t48_read_cfg), fake.sent.items[0]);
    try std.testing.expectEqual(@as(u8, 0x22), fake.sent.items[1]);
    try std.testing.expectEqual(@as(u8, 3), fake.sent.items[2]);
    try std.testing.expectEqual(@as(u64, 0x1234), endian.loadInt(fake.sent.items[4..8], .little));
    try std.testing.expectEqualSlices(u8, &.{ 0xaa, 0x55 }, &out);
}

test "write fuses sends T48 fuse packet with firmware offset" {
    var response = [_]u8{0} ** 1;
    var fake = transport.FakeTransport.init(std.testing.allocator, &response);
    defer fake.deinit();

    try writeFuses(fake.transport(), .{
        .protocol_id = 0x22,
        .variant = 0,
        .voltages_raw = 0,
        .chip_info = 0,
        .pin_map = 0,
        .data_memory_size = 0,
        .data_memory2_size = 0,
        .page_size = 0,
        .pulse_delay = 0,
        .code_memory_size = 0x1234,
        .package_details_raw = 0,
        .read_buffer_size = 0,
        .write_buffer_size = 0,
        .flags_raw = 0,
    }, .lock, 2, &.{ 0x12, 0x34 });

    try std.testing.expectEqual(@as(usize, 64), fake.sent.items.len);
    try std.testing.expectEqual(@as(u8, t48_write_lock), fake.sent.items[0]);
    try std.testing.expectEqual(@as(u8, 0x22), fake.sent.items[1]);
    try std.testing.expectEqual(@as(u8, 2), fake.sent.items[2]);
    try std.testing.expectEqual(@as(u64, 0x1234 - 0x38), endian.loadInt(fake.sent.items[4..8], .little));
    try std.testing.expectEqualSlices(u8, &.{ 0x12, 0x34 }, fake.sent.items[8..10]);
}

test "read and write JEDEC rows use upstream T48 packet layout" {
    var response = [_]u8{0} ** 32;
    response[0] = 0xa0;
    response[1] = 0x50;
    var fake = transport.FakeTransport.init(std.testing.allocator, &response);
    defer fake.deinit();
    const device = Device{
        .protocol_id = 0x33,
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

    var row_data = [_]u8{0} ** 4;
    try readJedecRow(fake.transport(), device, .{ .data = &row_data, .size_bits = 10, .row = 7, .flags = 2 });
    try std.testing.expectEqual(@as(u8, t48_read_jedec), fake.sent.items[0]);
    try std.testing.expectEqual(@as(u8, 0x33), fake.sent.items[1]);
    try std.testing.expectEqual(@as(u8, 10), fake.sent.items[2]);
    try std.testing.expectEqual(@as(u8, 7), fake.sent.items[4]);
    try std.testing.expectEqual(@as(u8, 2), fake.sent.items[5]);
    try std.testing.expectEqualSlices(u8, &.{ 0xa0, 0x50 }, row_data[0..2]);

    try writeJedecRow(fake.transport(), device, .{ .data = row_data[0..2], .size_bits = 10, .row = 8, .flags = 3 });
    const write = fake.sent.items[8..72];
    try std.testing.expectEqual(@as(u8, t48_write_jedec), write[0]);
    try std.testing.expectEqual(@as(u8, 0x33), write[1]);
    try std.testing.expectEqual(@as(u8, 10), write[2]);
    try std.testing.expectEqual(@as(u8, 8), write[4]);
    try std.testing.expectEqual(@as(u8, 3), write[5]);
    try std.testing.expectEqualSlices(u8, &.{ 0xa0, 0x50 }, write[8..10]);
}

test "request status decodes error address counters and overcurrent" {
    var response = [_]u8{0} ** 32;
    response[0] = 7;
    response[2] = 0x34;
    response[3] = 0x12;
    response[4] = 0x78;
    response[5] = 0x56;
    response[8] = 0xef;
    response[9] = 0xcd;
    response[10] = 0xab;
    response[11] = 0x89;
    response[12] = 1;
    var fake = transport.FakeTransport.init(std.testing.allocator, &response);
    defer fake.deinit();

    const status = try requestStatus(fake.transport());
    try std.testing.expectEqual(@as(u8, t48_request_status), fake.sent.items[0]);
    try std.testing.expectEqual(@as(u8, 7), status.error_code);
    try std.testing.expectEqual(@as(u16, 0x1234), status.c1);
    try std.testing.expectEqual(@as(u16, 0x5678), status.c2);
    try std.testing.expectEqual(@as(u32, 0x89abcdef), status.address);
    try std.testing.expectEqual(@as(u8, 1), status.overcurrent);
}

test "logic vector test packs states and unpacks pin results" {
    var response = [_]u8{0xff} ** 32;
    response[1] = 0;
    response[8] = 0x10;
    response[9] = 0x32;
    var fake = transport.FakeTransport.init(std.testing.allocator, &response);
    defer fake.deinit();
    const states = [_]logic.State{ .zero, .high, .ground, .vcc };
    var out = [_]u8{0} ** 4;

    try testLogicVector(fake.transport(), 0, true, 4, 7, &states, &out);

    try std.testing.expectEqual(@as(usize, 32), fake.sent.items.len);
    try std.testing.expectEqual(@as(u8, t48_logic_ic_test_vector), fake.sent.items[0]);
    try std.testing.expectEqual(@as(u8, 0x80), fake.sent.items[1]);
    try std.testing.expectEqual(@as(u64, 4), endian.loadInt(fake.sent.items[2..4], .little));
    try std.testing.expectEqual(@as(u64, 7), endian.loadInt(fake.sent.items[4..8], .little));
    try std.testing.expectEqualSlices(u8, &.{ 0x30, 0x87 }, fake.sent.items[8..10]);
    try std.testing.expectEqualSlices(u8, &.{ 0, 1, 2, 3 }, &out);
}

test "deviceFromProtocolInfo maps DB fields into T48 descriptor" {
    const info = struct {
        protocol_id: u8 = 0x07,
        variant: u32 = 0x4226,
        voltages_raw: u32 = 0x0200,
        chip_info: u32 = 1,
        pin_map: u32 = 0x14,
        data_memory_size: u32 = 2,
        data_memory2_size: u32 = 3,
        page_size: u32 = 64,
        pulse_delay: u32 = 0x2710,
        code_memory_size: u32 = 8192,
        package_details_raw: u32 = 0x1c000000,
        read_buffer_size: u16 = 512,
        write_buffer_size: u16 = 128,
        flags_raw: u32 = 0xc010,
        can_adjust_clock: bool = true,
    }{};

    const device = deviceFromProtocolInfo(info, 1, 4);
    try std.testing.expectEqual(@as(u8, 0x07), device.protocol_id);
    try std.testing.expectEqual(@as(u8, 1), device.icsp);
    try std.testing.expectEqual(@as(u8, 4), device.spi_clock);
    try std.testing.expect(device.can_adjust_clock);
    try std.testing.expectEqual(@as(u32, 8192), device.code_memory_size);
}
