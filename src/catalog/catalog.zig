// SPDX-License-Identifier: Apache-2.0

const std = @import("std");
const model = @import("../core/model.zig");
const generated = @import("generated.zig");
const schema = @import("schema.zig");

pub const Error = error{
    DeviceNotFound,
    UnsupportedProgrammer,
};

pub const DeviceRecord = schema.DeviceRecord;
pub const DeviceSummary = schema.DeviceSummary;
pub const devices = generated.devices;

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
        const flags = model.decodeFlags(device.flags_raw, device.voltages_raw, device.chip_info, device.protocol_id);
        try out.append(allocator, .{
            .name = device.canonical_name,
            .aliases = device.aliases,
            .chip_type = device.chip_type,
            .code_memory_size = device.code_memory_size,
            .data_memory_size = device.data_memory_size,
            .user_memory_size = device.data_memory2_size,
            .package_pins = package.pin_count,
            .page_size = device.page_size,
            .chip_id = device.chip_id,
            .chip_id_bytes_count = device.chip_id_bytes_count,
            .blank_value = device.blank_value,
            .can_erase = device.can_erase,
            .supports_unprotect = flags.off_protect_before,
            .supports_protect = flags.protect_after,
            .supports_pin_check = device.pin_check != null and device.supports(.t48),
            .supports_t48 = device.supports(.t48),
            .supports_t56 = device.supports(.t56),
            .supports_t76 = device.supports(.t76),
            .t56_algorithm = device.algorithmFor(.t56),
            .t76_algorithm = device.algorithmFor(.t76),
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

test "find resolves sourced T48 descriptors and programmer support" {
    const device = try find("at28c64b", .t48);
    try std.testing.expectEqualStrings("AT28C64B@DIP28", device.canonical_name);
    try std.testing.expectEqual(@as(u8, 0x07), device.protocol_id);
    try std.testing.expectEqual(@as(u32, 0x4126), device.variant);
    try std.testing.expectEqual(@as(u32, 0x0200), device.voltages_raw);
    try std.testing.expectEqual(@as(u32, 0x7013), device.pin_map);
    try std.testing.expectEqual(@as(u32, 0xc010), device.flags_raw);
    try std.testing.expect(device.can_erase);
    try std.testing.expectEqualSlices(u8, &.{14}, device.pin_check.?.gnd_pins);
    try std.testing.expectEqual(@as(usize, 25), device.pin_check.?.mask.len);
    try std.testing.expect(device.supports(.t56));
    try std.testing.expect(device.supports(.t76));
    try std.testing.expectError(Error.DeviceNotFound, find("missing", .t48));
    try std.testing.expectEqualStrings("ROM28P41", device.algorithmFor(.t56).?.name);
}

test "list exposes UV EPROM erase and ID metadata" {
    const found = try list(std.testing.allocator, "m27c64a", .t48, 10);
    defer std.testing.allocator.free(found);
    try std.testing.expectEqual(@as(usize, 1), found.len);
    try std.testing.expectEqualStrings("M27C64A@DIP28", found[0].name);
    try std.testing.expectEqual(@as(u32, 0x9b08), found[0].chip_id);
    try std.testing.expectEqual(@as(u8, 2), found[0].chip_id_bytes_count);
    try std.testing.expect(!found[0].can_erase);
    try std.testing.expect(!found[0].supports_unprotect);
    try std.testing.expect(!found[0].supports_protect);
    try std.testing.expect(found[0].supports_pin_check);
    try std.testing.expect(found[0].supports_t48);
    try std.testing.expect(found[0].supports_t56);
    try std.testing.expect(found[0].supports_t76);
    try std.testing.expectError(Error.DeviceNotFound, find("27C64", .t48));
}

test "automotive and vintage ROM profiles preserve sourced electrical attributes" {
    const Expected = struct {
        name: []const u8,
        variant: u32,
        voltages: u32,
        pin_map: u32,
        size: u32,
        delay: u32,
        read_buffer: u16,
        chip_id: u32,
        algorithm: []const u8,
    };
    const expected = [_]Expected{
        .{ .name = "AT28C64B", .variant = 0x4126, .voltages = 0x0200, .pin_map = 0x7013, .size = 8192, .delay = 10000, .read_buffer = 512, .chip_id = 0, .algorithm = "ROM28P41" },
        .{ .name = "AT28C256", .variant = 0x4126, .voltages = 0x0200, .pin_map = 0x0c14, .size = 32768, .delay = 10000, .read_buffer = 512, .chip_id = 0, .algorithm = "ROM28P41" },
        .{ .name = "M27C64A", .variant = 0x3313, .voltages = 0x4000, .pin_map = 0x6f15, .size = 8192, .delay = 1000, .read_buffer = 512, .chip_id = 0x9b08, .algorithm = "ROM28P33" },
        .{ .name = "AM27C64", .variant = 0x3313, .voltages = 0x5070, .pin_map = 0x6f15, .size = 8192, .delay = 100, .read_buffer = 1024, .chip_id = 0x0115, .algorithm = "ROM28P33" },
        .{ .name = "AM27C128", .variant = 0x3313, .voltages = 0x5070, .pin_map = 0x0c16, .size = 16384, .delay = 100, .read_buffer = 1024, .chip_id = 0x0116, .algorithm = "ROM28P33" },
        .{ .name = "AM27C256", .variant = 0x3211, .voltages = 0x5070, .pin_map = 0x0c16, .size = 32768, .delay = 100, .read_buffer = 1024, .chip_id = 0x0110, .algorithm = "ROM28P32" },
        .{ .name = "M27C256B", .variant = 0x3211, .voltages = 0x5070, .pin_map = 0x0c16, .size = 32768, .delay = 100, .read_buffer = 1024, .chip_id = 0x208d, .algorithm = "ROM28P32" },
        .{ .name = "AM27C512", .variant = 0x3110, .voltages = 0x5070, .pin_map = 0x0c16, .size = 65536, .delay = 100, .read_buffer = 1024, .chip_id = 0x0191, .algorithm = "ROM28P31" },
        .{ .name = "M27C512", .variant = 0x3110, .voltages = 0x5070, .pin_map = 0x0c16, .size = 65536, .delay = 100, .read_buffer = 1024, .chip_id = 0x203d, .algorithm = "ROM28P31" },
        .{ .name = "AT27C512R", .variant = 0x3110, .voltages = 0x5070, .pin_map = 0x0c16, .size = 65536, .delay = 100, .read_buffer = 1024, .chip_id = 0x1e0d, .algorithm = "ROM28P31" },
    };

    for (expected) |want| {
        const device = try find(want.name, .t76);
        try std.testing.expectEqual(@as(u8, 0x07), device.protocol_id);
        try std.testing.expectEqual(want.variant, device.variant);
        try std.testing.expectEqual(want.voltages, device.voltages_raw);
        try std.testing.expectEqual(want.pin_map, device.pin_map);
        try std.testing.expectEqual(want.size, device.code_memory_size);
        try std.testing.expectEqual(want.delay, device.pulse_delay);
        try std.testing.expectEqual(want.read_buffer, device.read_buffer_size);
        try std.testing.expectEqual(@as(u16, 128), device.write_buffer_size);
        try std.testing.expectEqual(@as(u32, 0x1c000000), device.package_details_raw);
        try std.testing.expectEqual(want.chip_id, device.chip_id);
        const is_eeprom = want.variant == 0x4126;
        try std.testing.expectEqual(if (is_eeprom) @as(u32, 0xc010) else @as(u32, 0x68), device.flags_raw);
        try std.testing.expectEqual(if (is_eeprom) @as(u32, 0) else @as(u32, 6), device.chip_info);
        try std.testing.expectEqual(if (is_eeprom) @as(u32, 64) else @as(u32, 0), device.page_size);
        try std.testing.expectEqual(is_eeprom, device.can_erase);
        try std.testing.expectEqual(if (is_eeprom) @as(u8, 0) else @as(u8, 2), device.chip_id_bytes_count);
        try std.testing.expectEqual(@as(u8, 0xff), device.blank_value);
        try std.testing.expectEqualStrings(want.algorithm, device.algorithmFor(.t56).?.name);
        try std.testing.expectEqualStrings(want.algorithm, device.algorithmFor(.t76).?.name);
        try std.testing.expect(device.supports(.t56));
        try std.testing.expect(device.supports(.t76));
    }
    try std.testing.expectError(Error.DeviceNotFound, find("27C64", .t76));
    try std.testing.expectError(Error.DeviceNotFound, find("27C512", .t76));
}
