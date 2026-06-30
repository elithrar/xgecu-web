// SPDX-License-Identifier: GPL-3.0-or-later

const std = @import("std");
const endian = @import("../core/endian.zig");
const logic = @import("../core/logic.zig");
const model = @import("../core/model.zig");
const t48 = @import("t48.zig");
const transport = @import("transport.zig");

const begin_trans = 0x03;
const end_trans = 0x04;
const read_id = 0x05;
const read_user = 0x06;
const write_user = 0x07;
const read_cfg = 0x08;
const write_cfg = 0x09;
const write_user_data = 0x0a;
const read_user_data = 0x0b;
const write_code = 0x0c;
const read_code = 0x0d;
const erase_cmd = 0x0e;
const read_data = 0x10;
const write_data = 0x11;
const write_lock = 0x14;
const read_lock = 0x15;
const protect_off = 0x18;
const protect_on = 0x19;
const read_jedec = 0x1d;
const write_jedec = 0x1e;
const set_pulldowns = 0x31;
const set_pullups = 0x32;
const set_dir = 0x34;
const read_pins = 0x35;
const set_out = 0x36;
const request_status_cmd = 0x39;

pub const Error = transport.Error || error{
    UnknownMemoryKind,
    Overcurrent,
} || std.mem.Allocator.Error;

pub const Device = t48.Device;
pub const Status = t48.Status;
pub const ChipId = t48.ChipId;
pub const FuseKind = t48.FuseKind;
pub const JedecRow = t48.JedecRow;

pub const PinMap = struct {
    gnd_pins: []const u8,
    masks: []const u8,
};

pub fn deviceFromProtocolInfo(info: anytype, icsp: u8, spi_clock: u8) Device {
    return t48.deviceFromProtocolInfo(info, icsp, spi_clock);
}

pub fn beginTransaction(trans: transport.Transport, device: Device) Error!void {
    var msg = [_]u8{0} ** 64;
    msg[0] = begin_trans;
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
    endian.storeInt(msg[40..44], device.package_details_raw, .little);
    endian.storeInt(msg[44..46], device.read_buffer_size, .little);
    endian.storeInt(msg[56..60], device.flags_raw, .little);

    try trans.send(&msg);
    const status = try requestStatus(trans);
    if (status.overcurrent != 0) return Error.Overcurrent;
}

pub fn endTransaction(trans: transport.Transport) Error!void {
    var msg = [_]u8{0} ** 8;
    msg[0] = end_trans;
    try trans.send(&msg);
}

pub fn readBlock(trans: transport.Transport, kind: model.MemoryKind, address: u32, out: []u8) Error!void {
    var msg = [_]u8{0} ** 8;
    msg[0] = try readCommand(kind);
    endian.storeInt(msg[2..4], out.len, .little);
    endian.storeInt(msg[4..8], address, .little);
    try trans.send(&msg);
    if (kind == .user) {
        _ = try trans.recv(out);
    } else {
        try trans.readPayload(out, 0);
    }
}

pub fn writeBlock(trans: transport.Transport, device: Device, kind: model.MemoryKind, address: u32, data: []const u8) Error!void {
    var msg = [_]u8{0} ** 64;
    msg[0] = try writeCommand(kind);
    endian.storeInt(msg[2..4], data.len, .little);
    endian.storeInt(msg[4..8], address, .little);
    if (data.len < 57) {
        @memcpy(msg[8 .. 8 + data.len], data);
        try trans.send(msg[0 .. 8 + data.len]);
    } else {
        try trans.send(msg[0..8]);
        try trans.writePayload(data, device.write_buffer_size);
    }
}

pub fn readFuses(trans: transport.Transport, device: Device, kind: FuseKind, items_count: u8, out: []u8) Error!void {
    return readFusesWithCommands(trans, device, kind, items_count, out);
}

pub fn writeFuses(trans: transport.Transport, device: Device, kind: FuseKind, items_count: u8, data: []const u8) Error!void {
    return writeFusesWithCommands(trans, device, kind, items_count, data);
}

pub fn getChipId(trans: transport.Transport, chip_id_bytes_count: u8) Error!ChipId {
    var request = [_]u8{0} ** 8;
    request[0] = read_id;
    try trans.send(&request);

    var response = [_]u8{0} ** 8;
    _ = try trans.recv(response[0..6]);
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
    var msg = [_]u8{0} ** 15;
    msg[0] = erase_cmd;
    msg[2] = num_fuses;
    msg[4] = pld;
    try trans.send(&msg);
    var response = [_]u8{0} ** 64;
    _ = try trans.recv(&response);
}

pub fn protectOff(trans: transport.Transport) Error!void {
    var msg = [_]u8{0} ** 8;
    msg[0] = protect_off;
    try trans.send(&msg);
}

pub fn protectOn(trans: transport.Transport) Error!void {
    var msg = [_]u8{0} ** 8;
    msg[0] = protect_on;
    try trans.send(&msg);
}

pub fn requestStatus(trans: transport.Transport) Error!Status {
    var msg = [_]u8{0} ** 32;
    msg[0] = request_status_cmd;
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

pub fn testLogicVector(trans: transport.Transport, vcc_index: u8, pull_down: bool, pin_count: u16, vector_index: u32, states: []const logic.State, out: []u8) t48.Error!void {
    return t48.testLogicVector(trans, vcc_index, pull_down, pin_count, vector_index, states, out);
}

pub fn pinContactTest(allocator: std.mem.Allocator, trans: transport.Transport, map: PinMap, device_pin_count: u8) Error![]u8 {
    const programmer_pins = 40;
    var msg = [_]u8{0} ** 48;
    var pins = [_]u8{0} ** programmer_pins;

    msg[0] = set_dir;
    @memset(msg[8..48], 0x01);
    for (map.gnd_pins) |pin| {
        if (pin >= 1 and pin <= programmer_pins) msg[pin + 7] = 0;
    }
    try trans.send(&msg);

    msg[0] = set_out;
    @memset(msg[8..48], 0x01);
    try trans.send(&msg);

    msg[0] = set_pullups;
    @memset(msg[28..48], 0x00);
    try trans.send(&msg);

    msg[0] = set_pulldowns;
    @memset(msg[8..28], 0x00);
    @memset(msg[28..48], 0x01);
    try trans.send(&msg);

    msg[0] = read_pins;
    try trans.send(msg[0..8]);
    _ = try trans.recv(&msg);
    @memcpy(pins[0..20], msg[8..28]);

    msg[0] = set_pullups;
    @memset(msg[8..28], 0x00);
    @memset(msg[28..48], 0x01);
    try trans.send(&msg);

    msg[0] = set_pulldowns;
    @memset(msg[8..28], 0x01);
    @memset(msg[28..48], 0x00);
    try trans.send(&msg);

    msg[0] = read_pins;
    try trans.send(msg[0..8]);
    _ = try trans.recv(&msg);
    @memcpy(pins[20..40], msg[28..48]);

    msg[0] = set_out;
    @memset(msg[8..48], 0x00);
    try trans.send(&msg);

    msg[0] = set_dir;
    @memset(msg[8..48], 0x01);
    try trans.send(&msg);

    msg[0] = set_pullups;
    @memset(msg[8..48], 0x01);
    try trans.send(&msg);

    msg[0] = set_pulldowns;
    @memset(msg[8..48], 0x00);
    try trans.send(&msg);

    try endTransaction(trans);

    var bad: std.ArrayListUnmanaged(u8) = .empty;
    errdefer bad.deinit(allocator);
    const x_pin = device_pin_count / 2;
    const offset = programmer_pins - device_pin_count;
    for (map.masks) |programmer_pin| {
        if (programmer_pin == 0 or programmer_pin > programmer_pins) continue;
        var device_pin = programmer_pin;
        if (programmer_pin > x_pin) device_pin = programmer_pin - offset;
        if (pins[programmer_pin - 1] == 0) try bad.append(allocator, device_pin);
    }
    return try bad.toOwnedSlice(allocator);
}

pub fn readJedecRow(trans: transport.Transport, device: Device, row: JedecRow) Error!void {
    var msg = [_]u8{0} ** 32;
    msg[0] = read_jedec;
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
    msg[0] = write_jedec;
    msg[1] = device.protocol_id;
    msg[2] = row.size_bits;
    msg[4] = row.row;
    msg[5] = row.flags;
    @memcpy(msg[8 .. 8 + byte_count], row.data[0..byte_count]);
    try trans.send(&msg);
}

fn readFusesWithCommands(trans: transport.Transport, device: Device, kind: FuseKind, items_count: u8, out: []u8) Error!void {
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

fn writeFusesWithCommands(trans: transport.Transport, device: Device, kind: FuseKind, items_count: u8, data: []const u8) Error!void {
    var msg = [_]u8{0} ** 64;
    if (data.len > msg.len - 8) return transport.Error.Io;
    msg[0] = writeFuseCommand(kind);
    msg[1] = device.protocol_id;
    msg[2] = items_count;
    endian.storeInt(msg[4..8], device.code_memory_size -| 0x38, .little);
    @memcpy(msg[8 .. 8 + data.len], data);
    try trans.send(&msg);
}

fn readCommand(kind: model.MemoryKind) Error!u8 {
    return switch (kind) {
        .code => read_code,
        .data => read_data,
        .user => read_user_data,
    };
}

fn writeCommand(kind: model.MemoryKind) Error!u8 {
    return switch (kind) {
        .code => write_code,
        .data => write_data,
        .user => write_user_data,
    };
}

fn readFuseCommand(kind: FuseKind) u8 {
    return switch (kind) {
        .user => read_user,
        .config => read_cfg,
        .lock => read_lock,
    };
}

fn writeFuseCommand(kind: FuseKind) u8 {
    return switch (kind) {
        .user => write_user,
        .config => write_cfg,
        .lock => write_lock,
    };
}

fn rowByteCount(size_bits: u8) usize {
    return (@as(usize, size_bits) + 7) / 8;
}

test "begin transaction sends TL866II packet without T48 clock-enable flag" {
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
        .can_adjust_clock = true,
        .spi_clock = 4,
    });

    const begin = fake.sent.items[0..64];
    try std.testing.expectEqual(@as(u8, begin_trans), begin[0]);
    try std.testing.expectEqual(@as(u8, 0), begin[24]);
    try std.testing.expectEqual(@as(u8, 0), begin[28]);
}

test "TL866II small writes are embedded in EP1 command" {
    var response = [_]u8{0} ** 1;
    var fake = transport.FakeTransport.init(std.testing.allocator, &response);
    defer fake.deinit();
    const device = Device{ .protocol_id = 0, .variant = 0, .voltages_raw = 0, .chip_info = 0, .pin_map = 0, .data_memory_size = 0, .data_memory2_size = 0, .page_size = 0, .pulse_delay = 0, .code_memory_size = 0, .package_details_raw = 0, .read_buffer_size = 0, .write_buffer_size = 128, .flags_raw = 0 };

    try writeBlock(fake.transport(), device, .code, 0x20, &.{ 1, 2, 3 });

    try std.testing.expectEqual(@as(usize, 11), fake.sent.items.len);
    try std.testing.expectEqual(@as(u8, write_code), fake.sent.items[0]);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3 }, fake.sent.items[8..11]);
    try std.testing.expectEqual(@as(usize, 0), fake.payload_sent.items.len);
}

test "TL866II user reads use EP1 response" {
    var response = [_]u8{ 0xde, 0xad, 0xbe, 0xef };
    var fake = transport.FakeTransport.init(std.testing.allocator, &response);
    defer fake.deinit();
    var out = [_]u8{0} ** 4;

    try readBlock(fake.transport(), .user, 0x10, &out);

    try std.testing.expectEqual(@as(u8, read_user_data), fake.sent.items[0]);
    try std.testing.expectEqualSlices(u8, &response, &out);
}

test "TL866II pin contact test maps bad programmer pins to device pins" {
    var response = [_]u8{1} ** 48;
    response[8] = 0;
    response[47] = 0;
    var fake = transport.FakeTransport.init(std.testing.allocator, &response);
    defer fake.deinit();

    const bad = try pinContactTest(std.testing.allocator, fake.transport(), .{ .gnd_pins = &.{4}, .masks = &.{ 1, 40 } }, 8);
    defer std.testing.allocator.free(bad);

    try std.testing.expectEqualSlices(u8, &.{ 1, 8 }, bad);
    try std.testing.expectEqual(@as(u8, set_dir), fake.sent.items[0]);
    try std.testing.expectEqual(@as(u8, set_out), fake.sent.items[48]);
    try std.testing.expectEqual(@as(u8, read_pins), fake.sent.items[48 * 4]);
    try std.testing.expectEqual(@as(u8, end_trans), fake.sent.items[fake.sent.items.len - 8]);
}
