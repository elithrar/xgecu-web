// SPDX-License-Identifier: GPL-3.0-or-later

const std = @import("std");
const model = @import("../core/model.zig");
const t48 = @import("../programmer/t48.zig");
const protocol = @import("../programmer/protocol.zig");

pub const Error = error{
    DeviceNotFound,
    UnsupportedProgrammer,
};

pub const DeviceRecord = struct {
    canonical_name: []const u8,
    aliases: []const []const u8,
    programmers: []const model.Programmer,
    chip_type: model.ChipType,
    protocol_id: u8,
    variant: u32,
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
    can_adjust_clock: bool = false,
    chip_id: u32 = 0,
    chip_id_bytes_count: u8 = 0,
    blank_value: u8 = 0xff,
    t56_algorithm: []const u8 = &.{},

    pub fn supports(self: DeviceRecord, programmer: model.Programmer) bool {
        if (programmer == .auto) return true;
        for (self.programmers) |entry| {
            if (entry == programmer) return true;
        }
        return false;
    }

    pub fn descriptor(self: DeviceRecord, programmer: model.Programmer) t48.Device {
        var out = t48.deviceFromProtocolInfo(self, 0, protocol.defaultSpiClock(programmer, self.protocol_id));
        out.can_adjust_clock = protocol.canAdjustClock(programmer, self.protocol_id);
        return out;
    }
};

pub const DeviceSummary = struct {
    name: []const u8,
    code_memory_size: u32,
    data_memory_size: u32,
    package_pins: u8,
    supports_t48: bool,
    supports_t56: bool,
};

const at28_aliases = [_][]const u8{ "AT28C64B", "AT28C64B@DIP28", "AT28C64B-15PU" };
const m27_aliases = [_][]const u8{ "M27C64A", "M27C64A@DIP28", "27C64" };
const winbond_aliases = [_][]const u8{ "W25Q32JV", "W25Q32JV@SOIC8", "W25Q32" };
const both_programmers = [_]model.Programmer{ .t48, .t56 };

pub const devices = [_]DeviceRecord{
    .{
        .canonical_name = "AT28C64B@DIP28",
        .aliases = &at28_aliases,
        .programmers = &both_programmers,
        .chip_type = .memory,
        .protocol_id = 0x07,
        .variant = 0x0000,
        .voltages_raw = 0x00000200,
        .chip_info = 0,
        .pin_map = 0x14,
        .data_memory_size = 0,
        .data_memory2_size = 0,
        .page_size = 64,
        .pulse_delay = 10000,
        .code_memory_size = 8192,
        .package_details_raw = 0x1c000000,
        .read_buffer_size = 512,
        .write_buffer_size = 128,
        .flags_raw = 0x00000030,
    },
    .{
        .canonical_name = "M27C64A@DIP28",
        .aliases = &m27_aliases,
        .programmers = &both_programmers,
        .chip_type = .memory,
        .protocol_id = 0x07,
        .variant = 0x0000,
        .voltages_raw = 0x00000200,
        .chip_info = 0,
        .pin_map = 0x14,
        .data_memory_size = 0,
        .data_memory2_size = 0,
        .page_size = 64,
        .pulse_delay = 10000,
        .code_memory_size = 8192,
        .package_details_raw = 0x1c000000,
        .read_buffer_size = 512,
        .write_buffer_size = 128,
        .flags_raw = 0x00000030,
        .blank_value = 0xff,
    },
    .{
        .canonical_name = "W25Q32JV@SOIC8",
        .aliases = &winbond_aliases,
        .programmers = &both_programmers,
        .chip_type = .memory,
        .protocol_id = 0x03,
        .variant = 0x0000,
        .voltages_raw = 0x00000100,
        .chip_info = 0,
        .pin_map = 0x08,
        .data_memory_size = 0,
        .data_memory2_size = 0,
        .page_size = 256,
        .pulse_delay = 0,
        .code_memory_size = 4 * 1024 * 1024,
        .package_details_raw = 0x08000000,
        .read_buffer_size = 512,
        .write_buffer_size = 256,
        .flags_raw = 0x00000030,
        .chip_id = 0xef4016,
        .chip_id_bytes_count = 3,
    },
};

pub fn find(name: []const u8, programmer: model.Programmer) Error!DeviceRecord {
    for (devices) |device| {
        if (!device.supports(programmer)) continue;
        if (std.ascii.eqlIgnoreCase(name, device.canonical_name)) return device;
        for (device.aliases) |alias| {
            if (std.ascii.eqlIgnoreCase(name, alias)) return device;
        }
    }
    return Error.DeviceNotFound;
}

pub fn list(allocator: std.mem.Allocator, query: ?[]const u8, programmer: model.Programmer, limit: usize) ![]DeviceSummary {
    var out: std.ArrayListUnmanaged(DeviceSummary) = .empty;
    errdefer out.deinit(allocator);
    for (devices) |device| {
        if (out.items.len >= limit) break;
        if (!device.supports(programmer)) continue;
        if (query) |needle| {
            if (!matchesQuery(device, needle)) continue;
        }
        const package = model.decodePackageDetails(device.package_details_raw);
        try out.append(allocator, .{
            .name = device.canonical_name,
            .code_memory_size = device.code_memory_size,
            .data_memory_size = device.data_memory_size,
            .package_pins = package.pin_count,
            .supports_t48 = device.supports(.t48),
            .supports_t56 = device.supports(.t56),
        });
    }
    return try out.toOwnedSlice(allocator);
}

fn matchesQuery(device: DeviceRecord, query: []const u8) bool {
    if (query.len == 0) return true;
    if (containsIgnoreCase(device.canonical_name, query)) return true;
    for (device.aliases) |alias| {
        if (containsIgnoreCase(alias, query)) return true;
    }
    return false;
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var index: usize = 0;
    while (index + needle.len <= haystack.len) : (index += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[index .. index + needle.len], needle)) return true;
    }
    return false;
}

test "find resolves aliases and programmer support" {
    const device = try find("at28c64b", .t48);
    try std.testing.expectEqualStrings("AT28C64B@DIP28", device.canonical_name);
    try std.testing.expect(device.supports(.t56));
    try std.testing.expectError(Error.DeviceNotFound, find("missing", .t48));
}

test "list filters by query" {
    const found = try list(std.testing.allocator, "w25", .t56, 10);
    defer std.testing.allocator.free(found);
    try std.testing.expectEqual(@as(usize, 1), found.len);
    try std.testing.expectEqualStrings("W25Q32JV@SOIC8", found[0].name);
    try std.testing.expect(found[0].supports_t48);
}
