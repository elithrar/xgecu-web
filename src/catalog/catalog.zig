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
    try std.testing.expectEqual(@as(u32, 0x13), device.pin_map);
    try std.testing.expectEqual(@as(u32, 0xc010), device.flags_raw);
    try std.testing.expect(device.can_erase);
    try std.testing.expectEqualSlices(u8, &.{14}, device.pin_check.?.gnd_pins);
    try std.testing.expectEqual(@as(usize, 25), device.pin_check.?.mask.len);
    try std.testing.expect(!device.supports(.t56));
    try std.testing.expectError(Error.DeviceNotFound, find("missing", .t48));
    try std.testing.expectError(Error.DeviceNotFound, find("at28c64b", .t56));
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
    try std.testing.expect(!found[0].supports_t56);
    try std.testing.expectError(Error.DeviceNotFound, find("27C64", .t48));
}
