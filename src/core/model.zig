// SPDX-License-Identifier: Apache-2.0

const std = @import("std");

pub const Programmer = enum {
    auto,
    t48,
    t56,

    pub const supported = [_]Programmer{ .t48, .t56 };

    pub fn parse(text: []const u8) ?Programmer {
        if (std.ascii.eqlIgnoreCase(text, "auto")) return .auto;
        if (std.ascii.eqlIgnoreCase(text, "t48")) return .t48;
        if (std.ascii.eqlIgnoreCase(text, "t56")) return .t56;
        return null;
    }

    pub fn name(self: Programmer) []const u8 {
        return switch (self) {
            .auto => "auto",
            .t48 => "t48",
            .t56 => "t56",
        };
    }

    pub fn label(self: Programmer) []const u8 {
        return switch (self) {
            .auto => "auto",
            .t48 => "T48",
            .t56 => "T56",
        };
    }
};

pub const MemoryKind = enum(u8) {
    code = 0x00,
    data = 0x01,
    user = 0x02,
};

pub const ChipType = enum(u8) {
    memory = 0x01,
    mcu = 0x02,
    pld = 0x03,
    sram = 0x04,
    logic = 0x05,
    nand = 0x06,
    emmc = 0x07,
    vga = 0x08,
};

pub const Flags = struct {
    can_erase: bool,
    has_chip_id: bool,
    has_data_offset: bool,
    off_protect_before: bool,
    protect_after: bool,
    lock_bit_write_only: bool,
    has_calibration: bool,
    prog_support: u2,
    word_size: u8,
    data_org: u8,
    can_adjust_vpp: bool,
    can_adjust_vcc: bool,
    can_adjust_clock: bool,
    can_adjust_address: bool,
    custom_protocol: bool,
    has_power_down: bool,
    is_powerdown_disabled: bool,
    reversed_package: bool,
    raw_flags: u32,
};

pub const Voltages = struct {
    vcc: u8,
    vdd: u8,
    vpp: u8,
    raw_voltages: u32,
};

pub const PackageDetails = struct {
    pin_count: u8,
    adapter: u8,
    plcc: bool,
    icsp: u8,
    smd: bool,
    packed_package: u32,
};

const mp_reversed_package = 0x00000002;
const mp_erase_mask = 0x00000010;
const mp_id_mask = 0x00000020;
const mp_data_memory_address = 0x00001000;
const mp_data_bus_width = 0x00002000;
const mp_off_protect_before = 0x00004000;
const mp_protect_after = 0x00008000;
const mp_lock_bit_write_only = 0x00040000;
const mp_calibration = 0x00080000;
const mp_supported_programming = 0x00300000;

const last_jedec_bit_is_powerdown_enable = 0x1000;
const powerdown_mode_disable = 0x2000;
const mp_voltages1 = 0x0006;
const mp_voltages2 = 0x0007;
const custom_protocol_mask = 0x80000000;

const smd_flag = 0x80000000;
const icsp_mask = 0x0000ff00;
const adapter_mask = 0x000000ff;
const pin_count_mask = 0x3f000000;
const plcc20_adapter = 0x00000038;
const plcc44_adapter = 0x0000003d;
const plcc28_adapter = 0x0000003e;
const plcc32_adapter = 0x0000003f;

pub fn decodeFlags(flags: u32, voltages: u32, chip_info: u32, protocol_id: u32) Flags {
    return .{
        .can_erase = flags & mp_erase_mask != 0,
        .has_chip_id = flags & mp_id_mask != 0,
        .has_data_offset = flags & mp_data_memory_address != 0,
        .off_protect_before = flags & mp_off_protect_before != 0,
        .protect_after = flags & mp_protect_after != 0,
        .lock_bit_write_only = flags & mp_lock_bit_write_only != 0,
        .has_calibration = flags & mp_calibration != 0,
        .prog_support = @intCast((flags & mp_supported_programming) >> 20),
        .word_size = if (flags & mp_data_bus_width != 0) 2 else 1,
        .data_org = if (flags & mp_data_bus_width != 0) 1 else 0,
        .can_adjust_vpp = chip_info == mp_voltages2,
        .can_adjust_vcc = chip_info == mp_voltages1,
        .can_adjust_clock = false,
        .can_adjust_address = false,
        .custom_protocol = protocol_id & custom_protocol_mask != 0,
        .has_power_down = voltages & last_jedec_bit_is_powerdown_enable != 0,
        .is_powerdown_disabled = voltages & powerdown_mode_disable != 0,
        .reversed_package = flags & mp_reversed_package != 0,
        .raw_flags = flags,
    };
}

pub fn decodeVoltages(raw: u32) Voltages {
    return .{
        .vdd = @intCast((raw >> 12) & 0x0f),
        .vcc = @intCast((raw >> 8) & 0x0f),
        .vpp = @intCast(raw & 0xff),
        .raw_voltages = raw,
    };
}

pub fn encodeVoltages(voltages: Voltages) u32 {
    return (voltages.raw_voltages & 0xffff0000) |
        (@as(u32, voltages.vdd) << 12) |
        (@as(u32, voltages.vcc) << 8) |
        voltages.vpp;
}

pub fn decodePackageDetails(raw: u32) PackageDetails {
    const pin_field = pinCountField(raw);
    return .{
        .pin_count = getPinCount(raw),
        .adapter = @intCast(raw & adapter_mask),
        .icsp = @intCast((raw & icsp_mask) >> 8),
        .plcc = pin_field > 0x30,
        .smd = raw & smd_flag != 0,
        .packed_package = raw,
    };
}

fn pinCountField(raw: u32) u8 {
    return @intCast((raw & pin_count_mask) >> 24);
}

fn getPinCount(raw: u32) u8 {
    return switch (pinCountField(raw)) {
        plcc20_adapter => 20,
        plcc28_adapter => 28,
        plcc32_adapter => 32,
        plcc44_adapter => 44,
        else => pinCountField(raw),
    };
}

test "programmer parser accepts supported names only" {
    try std.testing.expectEqual(Programmer.t48, Programmer.parse("T48").?);
    try std.testing.expectEqual(Programmer.t56, Programmer.parse("t56").?);
    try std.testing.expect(Programmer.parse("t47") == null);
    try std.testing.expect(Programmer.parse("t57") == null);
    try std.testing.expect(Programmer.parse("programmer") == null);
}

test "decode flags matches catalog masks" {
    const decoded = decodeFlags(0x003cf032, 0x00003123, mp_voltages1, custom_protocol_mask | 1);
    try std.testing.expect(decoded.can_erase);
    try std.testing.expect(decoded.has_chip_id);
    try std.testing.expect(decoded.has_data_offset);
    try std.testing.expect(decoded.off_protect_before);
    try std.testing.expect(decoded.protect_after);
    try std.testing.expect(decoded.lock_bit_write_only);
    try std.testing.expect(decoded.has_calibration);
    try std.testing.expectEqual(@as(u2, 3), decoded.prog_support);
    try std.testing.expectEqual(@as(u8, 2), decoded.word_size);
    try std.testing.expect(decoded.can_adjust_vcc);
    try std.testing.expect(!decoded.can_adjust_vpp);
    try std.testing.expect(decoded.custom_protocol);
    try std.testing.expect(decoded.has_power_down);
    try std.testing.expect(decoded.is_powerdown_disabled);
    try std.testing.expect(decoded.reversed_package);
}

test "decode voltages and package details" {
    const voltages = decodeVoltages(0xabcd4321);
    try std.testing.expectEqual(@as(u8, 0x4), voltages.vdd);
    try std.testing.expectEqual(@as(u8, 0x3), voltages.vcc);
    try std.testing.expectEqual(@as(u8, 0x21), voltages.vpp);
    try std.testing.expectEqual(@as(u32, 0xabcd4321), encodeVoltages(voltages));

    const pkg = decodePackageDetails(0x1c000700);
    try std.testing.expectEqual(@as(u8, 28), pkg.pin_count);
    try std.testing.expectEqual(@as(u8, 7), pkg.icsp);
    try std.testing.expect(!pkg.plcc);
}
