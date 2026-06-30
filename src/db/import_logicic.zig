// SPDX-License-Identifier: GPL-3.0-or-later

const std = @import("std");
const xml_scan = @import("xml_scan.zig");

pub const Device = struct {
    database_type: []const u8,
    manufacturer: []const u8,
    aliases: []const []const u8,
    canonical_name: []const u8,
    pin_count: u32,
    voltage: []const u8,
    vectors: []const Vector,
    is_custom: bool,

    pub fn deinit(self: Device, allocator: std.mem.Allocator) void {
        allocator.free(self.aliases);
        allocator.free(self.vectors);
    }
};

pub const Vector = struct {
    id: []const u8,
    states: []const u8,
};

pub const Iterator = struct {
    allocator: std.mem.Allocator,
    scanner: xml_scan.Scanner,
    database_type: []const u8 = "LOGIC",
    manufacturer: []const u8 = "Logic Ic",
    is_custom: bool = false,

    pub fn next(self: *Iterator) !?Device {
        while (self.scanner.next()) |tag| {
            if (tag.closing) {
                if (std.mem.eql(u8, tag.name, "custom")) self.is_custom = false;
                continue;
            }

            if (std.mem.eql(u8, tag.name, "database")) {
                self.database_type = xml_scan.attr(tag.attrs, "type") orelse "LOGIC";
                continue;
            }
            if (std.mem.eql(u8, tag.name, "custom")) {
                self.manufacturer = xml_scan.attr(tag.attrs, "name") orelse "Logic Ic";
                self.is_custom = true;
                continue;
            }
            if (std.mem.eql(u8, tag.name, "manufacturer")) {
                self.manufacturer = xml_scan.attr(tag.attrs, "name") orelse "Logic Ic";
                self.is_custom = false;
                continue;
            }
            if (!std.mem.eql(u8, tag.name, "ic")) continue;
            return try self.parseDevice(tag.attrs);
        }
        return null;
    }

    fn parseDevice(self: *Iterator, attrs: []const u8) !Device {
        const name = requiredAttr(attrs, "name");
        const aliases = try splitAliases(self.allocator, name);
        errdefer self.allocator.free(aliases);

        var vectors: std.ArrayListUnmanaged(Vector) = .empty;
        errdefer vectors.deinit(self.allocator);

        while (self.scanner.next()) |tag| {
            if (tag.closing and std.mem.eql(u8, tag.name, "ic")) break;
            if (tag.closing or !std.mem.eql(u8, tag.name, "vector")) continue;

            const id = requiredAttr(tag.attrs, "id");
            const content_start = tag.end;
            const close = self.scanner.next() orelse return error.InvalidLogicXml;
            if (!close.closing or !std.mem.eql(u8, close.name, "vector")) return error.InvalidLogicXml;
            const states = std.mem.trim(u8, self.scanner.xml[content_start..close.start], " \t\r\n");
            try vectors.append(self.allocator, .{ .id = id, .states = states });
        }

        return .{
            .database_type = self.database_type,
            .manufacturer = self.manufacturer,
            .aliases = aliases,
            .canonical_name = aliases[0],
            .pin_count = try requiredInt(attrs, "pins"),
            .voltage = xml_scan.attr(attrs, "voltage") orelse "5V",
            .vectors = try vectors.toOwnedSlice(self.allocator),
            .is_custom = self.is_custom,
        };
    }
};

pub fn iterator(allocator: std.mem.Allocator, xml: []const u8) Iterator {
    return .{ .allocator = allocator, .scanner = .{ .xml = xml } };
}

pub fn countDevices(xml: []const u8) usize {
    var scanner = xml_scan.Scanner{ .xml = xml };
    var count: usize = 0;
    while (scanner.next()) |tag| {
        if (!tag.closing and std.mem.eql(u8, tag.name, "ic")) count += 1;
    }
    return count;
}

fn splitAliases(allocator: std.mem.Allocator, names: []const u8) ![]const []const u8 {
    var count: usize = 1;
    for (names) |byte| {
        if (byte == ',') count += 1;
    }

    var aliases = try allocator.alloc([]const u8, count);
    errdefer allocator.free(aliases);

    var index: usize = 0;
    var parts = std.mem.splitScalar(u8, names, ',');
    while (parts.next()) |part| {
        aliases[index] = std.mem.trim(u8, part, " \t\r\n");
        index += 1;
    }
    return aliases;
}

fn requiredAttr(attrs: []const u8, name: []const u8) []const u8 {
    return xml_scan.attr(attrs, name) orelse @panic("missing required logicic attribute");
}

fn requiredInt(attrs: []const u8, name: []const u8) !u32 {
    return xml_scan.parseInt(requiredAttr(attrs, name));
}

test "count and parse logicic devices with vectors" {
    const xml =
        \\<logicic>
        \\  <database type="LOGIC">
        \\    <manufacturer name="Logic Ic">
        \\      <ic name="40106,7414" type="5" voltage="5V" pins="14">
        \\        <vector id="00"> 0 H 0 H 0 H G H 0 H 0 H 0 V </vector>
        \\        <vector id="01"> 1 L 1 L 1 L G L 1 L 1 L 1 V </vector>
        \\      </ic>
        \\    </manufacturer>
        \\  </database>
        \\</logicic>
    ;

    try std.testing.expectEqual(@as(usize, 1), countDevices(xml));
    var it = iterator(std.testing.allocator, xml);
    const device = (try it.next()).?;
    defer device.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("LOGIC", device.database_type);
    try std.testing.expectEqualStrings("40106", device.canonical_name);
    try std.testing.expectEqual(@as(usize, 2), device.aliases.len);
    try std.testing.expectEqual(@as(u32, 14), device.pin_count);
    try std.testing.expect(!device.is_custom);
    try std.testing.expectEqual(@as(usize, 2), device.vectors.len);
    try std.testing.expectEqualStrings("00", device.vectors[0].id);
    try std.testing.expectEqualStrings("0 H 0 H 0 H G H 0 H 0 H 0 V", device.vectors[0].states);
    try std.testing.expect((try it.next()) == null);
}
