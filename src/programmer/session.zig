// SPDX-License-Identifier: GPL-3.0-or-later

const std = @import("std");
const endian = @import("../core/endian.zig");
const model = @import("../core/model.zig");
const transport = @import("transport.zig");

const mp_tl866a = 1;
const mp_tl866cs = 2;
const mp_tl866ii = 5;
const mp_t56 = 6;
const mp_t48 = 7;
const mp_t76 = 8;

pub const Status = enum {
    normal,
    bootloader,
    unknown,
};

pub const SystemInfo = struct {
    programmer: model.Programmer,
    model_name: []const u8,
    status: Status,
    firmware: u16,
    firmware_string: [8]u8,
    device_code: [8]u8,
    serial_number: [24]u8,
    manufacture_date: [16]u8 = [_]u8{0} ** 16,
    hardware: u8 = 0,
    voltage: f32 = 0,
    speed: u8 = 0,
    external_power: u8 = 0,
};

pub const Session = struct {
    transport: transport.Transport,
    info: SystemInfo,

    pub fn open(trans: transport.Transport) !Session {
        const info = try getSystemInfo(trans);
        return .{ .transport = trans, .info = info };
    }

    pub fn close(self: Session) void {
        self.transport.close();
    }
};

pub fn getSystemInfo(trans: transport.Transport) !SystemInfo {
    var request = [_]u8{0} ** 5;
    try trans.send(&request);

    var msg = [_]u8{0} ** 80;
    _ = try trans.recv(&msg);
    return parseSystemInfo(&msg) orelse error.UnknownProgrammer;
}

pub fn parseSystemInfo(msg: []const u8) ?SystemInfo {
    if (msg.len < 80) return null;
    const version = msg[6];
    var info = SystemInfo{
        .programmer = .auto,
        .model_name = "unknown",
        .status = .unknown,
        .firmware = @intCast(endian.loadInt(msg[4..6], .little)),
        .firmware_string = firmwareString(0, msg[5], msg[4]),
        .device_code = [_]u8{0} ** 8,
        .serial_number = [_]u8{0} ** 24,
    };

    switch (version) {
        mp_tl866a, mp_tl866cs => {
            info.programmer = .tl866a;
            info.model_name = if (version == mp_tl866a) "TL866A" else "TL866CS";
            info.status = statusFromByte(msg[1]);
            @memcpy(&info.device_code, msg[7..15]);
            @memcpy(&info.serial_number, msg[15..39]);
            info.hardware = msg[39];
            info.firmware_string = firmwareString(info.hardware, msg[5], msg[4]);
        },
        mp_tl866ii => {
            info.programmer = .tl866ii;
            info.model_name = "TL866II+";
            info.status = if (msg[4] == 0) .bootloader else .normal;
            @memcpy(&info.device_code, msg[8..16]);
            @memcpy(info.serial_number[0..20], msg[16..36]);
            info.hardware = msg[40];
            info.firmware_string = firmwareString(info.hardware, msg[5], msg[4]);
        },
        mp_t48, mp_t56, mp_t76 => {
            info.programmer = switch (version) {
                mp_t48 => .t48,
                mp_t56 => .t56,
                else => .t76,
            };
            info.model_name = switch (version) {
                mp_t48 => "T48",
                mp_t56 => "T56",
                else => "T76",
            };
            info.status = if (msg[4] == 0) .bootloader else .normal;
            @memcpy(&info.manufacture_date, msg[8..24]);
            @memcpy(&info.device_code, msg[24..32]);
            @memcpy(&info.serial_number, msg[32..56]);
            const raw_voltage: u32 = @intCast(endian.loadInt(msg[56..60], .little));
            info.voltage = if (version == mp_t76)
                @as(f32, @floatFromInt(raw_voltage)) / 1000.0
            else
                @as(f32, @floatFromInt(raw_voltage * 0xccf6 / 0x27000)) / 100.0;
            info.speed = msg[60];
            info.external_power = if (version == mp_t56 or version == mp_t76) msg[62] else 0;
        },
        else => return null,
    }
    return info;
}

fn statusFromByte(byte: u8) Status {
    return switch (byte) {
        1 => .normal,
        2 => .bootloader,
        else => .unknown,
    };
}

fn firmwareString(hw: u8, major: u8, minor: u8) [8]u8 {
    var out = [_]u8{0} ** 8;
    const text = std.fmt.bufPrint(&out, "{d:0>2}.{d}.{d:0>2}", .{ hw, major, minor }) catch unreachable;
    @memset(out[text.len..], 0);
    return out;
}

test "parse TL866II+ system info" {
    var msg = [_]u8{0} ** 80;
    msg[4] = 34;
    msg[5] = 12;
    msg[6] = mp_tl866ii;
    @memcpy(msg[8..16], "CODE1234");
    @memcpy(msg[16..36], "SERIAL-123456789012");
    msg[40] = 3;

    const info = parseSystemInfo(&msg).?;
    try std.testing.expectEqual(model.Programmer.tl866ii, info.programmer);
    try std.testing.expectEqual(Status.normal, info.status);
    try std.testing.expectEqualStrings("TL866II+", info.model_name);
    try std.testing.expectEqualSlices(u8, "CODE1234", &info.device_code);
    try std.testing.expectEqualStrings("03.12.34", std.mem.sliceTo(&info.firmware_string, 0));
}

test "session sends system-info request through transport" {
    var msg = [_]u8{0} ** 80;
    msg[4] = 1;
    msg[5] = 2;
    msg[6] = mp_t76;
    @memcpy(msg[8..24], "2026-06-26......");
    @memcpy(msg[24..32], "T76CODE!");
    @memcpy(msg[32..56], "SERIAL-T76-00000000000");
    endian.storeInt(msg[56..60], 5000, .little);
    msg[60] = 3;
    msg[62] = 1;

    var fake = transport.FakeTransport.init(std.testing.allocator, &msg);
    defer fake.deinit();
    const session = try Session.open(fake.transport());
    defer session.close();

    try std.testing.expectEqualSlices(u8, &[_]u8{0} ** 5, fake.sent.items);
    try std.testing.expectEqual(model.Programmer.t76, session.info.programmer);
    try std.testing.expectEqual(@as(f32, 5.0), session.info.voltage);
    try std.testing.expectEqual(@as(u8, 1), session.info.external_power);
}
