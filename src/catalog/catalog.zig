// SPDX-License-Identifier: GPL-3.0-or-later

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
    try std.testing.expect(!device.supports(.t56));
    try std.testing.expectError(Error.DeviceNotFound, find("missing", .t48));
    try std.testing.expectError(Error.DeviceNotFound, find("at28c64b", .t56));
}

test "list filters by query" {
    const found = try list(std.testing.allocator, "w25", .t48, 10);
    defer std.testing.allocator.free(found);
    try std.testing.expectEqual(@as(usize, 1), found.len);
    try std.testing.expectEqualStrings("W25Q32JV@SOIC8", found[0].name);
    try std.testing.expect(found[0].supports_t48);
    try std.testing.expect(!found[0].supports_t56);
}
