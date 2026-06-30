// SPDX-License-Identifier: GPL-3.0-or-later

const std = @import("std");
const model = @import("../core/model.zig");
const xml_scan = @import("xml_scan.zig");

pub const Device = struct {
    database_type: []const u8,
    manufacturer: []const u8,
    aliases: []const []const u8,
    canonical_name: []const u8,
    chip_type: u32,
    protocol_id: u32,
    variant: u32,
    read_buffer_size: u32,
    write_buffer_size: u32,
    code_memory_size: u32,
    data_memory_size: u32,
    data_memory2_size: u32,
    page_size: u32,
    pages_per_block: u32,
    chip_id: u32,
    voltages: model.Voltages,
    pulse_delay: u32,
    flags: model.Flags,
    chip_info: u32,
    pin_map_raw: u32,
    package_details: model.PackageDetails,
    config_ref: []const u8,
    is_custom: bool,
    supports_tl866a: bool,
    supports_tl866ii: bool,
    supports_t48: bool,
    supports_t56: bool,
    supports_t76: bool,

    pub fn deinit(self: Device, allocator: std.mem.Allocator) void {
        allocator.free(self.aliases);
    }
};

pub const ConfigItem = struct {
    name: []const u8,
    mask: u32,
    default_value: u32,
};

pub const Config = struct {
    name: []const u8,
    raw_xml: []const u8,
    fuses: []const ConfigItem,
    locks: []const ConfigItem,
    gal: ?GalConfig = null,

    pub fn deinit(self: Config, allocator: std.mem.Allocator) void {
        allocator.free(self.fuses);
        allocator.free(self.locks);
        if (self.gal) |gal| allocator.free(gal.acw_bits);
    }
};

pub const GalConfig = struct {
    fuses_size: u32,
    row_width: u32,
    ues_address: u32,
    ues_size: u32,
    powerdown_row: u32,
    acw_address: u32,
    acw_bits: []const u16,
};

pub const PinMap = struct {
    index: u32,
    gnd_pins: []const u8,
    masks: []const u8,
};

pub const PinMapIterator = struct {
    scanner: xml_scan.Scanner,
    xml: []const u8,
    in_maps: bool = false,

    pub fn next(self: *PinMapIterator) !?PinMap {
        while (self.scanner.next()) |tag| {
            if (tag.closing) {
                if (std.mem.eql(u8, tag.name, "maps")) self.in_maps = false;
                continue;
            }
            if (std.mem.eql(u8, tag.name, "maps")) {
                self.in_maps = true;
                continue;
            }
            if (!self.in_maps or !std.mem.eql(u8, tag.name, "map")) continue;
            return try self.parseMap(tag);
        }
        return null;
    }

    fn parseMap(self: *PinMapIterator, open_tag: xml_scan.Tag) !PinMap {
        const index = try requiredInt(open_tag.attrs, "index");
        const body_start = open_tag.end;
        while (self.scanner.next()) |tag| {
            if (tag.closing and std.mem.eql(u8, tag.name, "map")) {
                const body = self.xml[body_start..tag.start];
                return .{ .index = index, .gnd_pins = pinMapText(body, "gnd"), .masks = pinMapText(body, "mask") };
            }
        }
        return error.BadPinMapXml;
    }
};

pub const ConfigIterator = struct {
    allocator: std.mem.Allocator,
    scanner: xml_scan.Scanner,
    xml: []const u8,
    in_configurations: bool = false,

    pub fn next(self: *ConfigIterator) !?Config {
        while (self.scanner.next()) |tag| {
            if (tag.closing) {
                if (std.mem.eql(u8, tag.name, "configurations")) self.in_configurations = false;
                continue;
            }
            if (std.mem.eql(u8, tag.name, "configurations")) {
                self.in_configurations = true;
                continue;
            }
            if (!self.in_configurations or !std.mem.eql(u8, tag.name, "config")) continue;
            return try self.parseConfig(tag);
        }
        return null;
    }

    fn parseConfig(self: *ConfigIterator, open_tag: xml_scan.Tag) !Config {
        const name = requiredAttr(open_tag.attrs, "name");
        const body_start = open_tag.end;
        while (self.scanner.next()) |tag| {
            if (tag.closing and std.mem.eql(u8, tag.name, "config")) {
                const raw_xml = self.xml[open_tag.start..tag.end];
                const body = self.xml[body_start..tag.start];
                return .{
                    .name = name,
                    .raw_xml = raw_xml,
                    .fuses = try parseConfigItems(self.allocator, body, "fuse"),
                    .locks = try parseConfigItems(self.allocator, body, "lock"),
                    .gal = try parseGalConfig(self.allocator, open_tag.attrs, body),
                };
            }
        }
        return error.BadConfigXml;
    }
};

pub const Iterator = struct {
    allocator: std.mem.Allocator,
    scanner: xml_scan.Scanner,
    database_type: []const u8 = "",
    manufacturer: []const u8 = "",
    in_custom: bool = false,

    pub fn next(self: *Iterator) !?Device {
        while (self.scanner.next()) |tag| {
            if (tag.closing) {
                if (std.mem.eql(u8, tag.name, "custom")) self.in_custom = false;
                continue;
            }

            if (std.mem.eql(u8, tag.name, "database")) {
                self.database_type = xml_scan.attr(tag.attrs, "type") orelse "";
                continue;
            }
            if (std.mem.eql(u8, tag.name, "manufacturer")) {
                self.manufacturer = xml_scan.attr(tag.attrs, "name") orelse "";
                self.in_custom = false;
                continue;
            }
            if (std.mem.eql(u8, tag.name, "custom")) {
                self.manufacturer = xml_scan.attr(tag.attrs, "name") orelse "CUSTOM";
                self.in_custom = true;
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

        const protocol_id = try requiredInt(attrs, "protocol_id");
        const flags_raw = try requiredInt(attrs, "flags");
        const voltages_raw = try requiredInt(attrs, "voltages");
        const chip_info = try requiredInt(attrs, "chip_info");
        const package_details_raw = try requiredInt(attrs, "package_details");
        const pin_map_raw = if (xml_scan.attr(attrs, "pin_map")) |value| try xml_scan.parseInt(value) else 0;
        const supports = programmerSupport(self.database_type, pin_map_raw);

        return .{
            .database_type = self.database_type,
            .manufacturer = self.manufacturer,
            .aliases = aliases,
            .canonical_name = aliases[0],
            .chip_type = try requiredInt(attrs, "type"),
            .protocol_id = protocol_id,
            .variant = try requiredInt(attrs, "variant"),
            .read_buffer_size = try requiredInt(attrs, "read_buffer_size"),
            .write_buffer_size = try requiredInt(attrs, "write_buffer_size"),
            .code_memory_size = try requiredInt(attrs, "code_memory_size"),
            .data_memory_size = try requiredInt(attrs, "data_memory_size"),
            .data_memory2_size = try requiredInt(attrs, "data_memory2_size"),
            .page_size = try requiredInt(attrs, "page_size"),
            .pages_per_block = if (xml_scan.attr(attrs, "pages_per_block")) |value| try xml_scan.parseInt(value) else 0,
            .chip_id = try requiredInt(attrs, "chip_id"),
            .voltages = model.decodeVoltages(voltages_raw),
            .pulse_delay = try requiredInt(attrs, "pulse_delay"),
            .flags = model.decodeFlags(flags_raw, voltages_raw, chip_info, protocol_id),
            .chip_info = chip_info,
            .pin_map_raw = pin_map_raw,
            .package_details = model.decodePackageDetails(package_details_raw),
            .config_ref = xml_scan.attr(attrs, "config") orelse "NULL",
            .is_custom = self.in_custom,
            .supports_tl866a = supports.tl866a,
            .supports_tl866ii = supports.tl866ii,
            .supports_t48 = supports.t48,
            .supports_t56 = supports.t56,
            .supports_t76 = supports.t76,
        };
    }
};

const Support = struct {
    tl866a: bool = false,
    tl866ii: bool = false,
    t48: bool = false,
    t56: bool = false,
    t76: bool = false,
};

const t56_flag = 0x10000000;
const tl866ii_flag = 0x20000000;
const t48_flag = 0x40000000;

fn programmerSupport(database_type: []const u8, pin_map_raw: u32) Support {
    if (std.mem.eql(u8, database_type, "INFOIC")) return .{ .tl866a = true };
    if (std.mem.eql(u8, database_type, "INFOICT76")) return .{ .t76 = true };
    if (std.mem.eql(u8, database_type, "INFOIC2PLUS")) {
        const has_only_flags = pin_map_raw & (t56_flag | tl866ii_flag | t48_flag) != 0;
        if (!has_only_flags) return .{ .tl866ii = true, .t48 = true, .t56 = true };
        return .{
            .tl866ii = pin_map_raw & tl866ii_flag != 0,
            .t48 = pin_map_raw & t48_flag != 0,
            .t56 = pin_map_raw & t56_flag != 0,
        };
    }
    return .{};
}

pub fn iterator(allocator: std.mem.Allocator, xml: []const u8) Iterator {
    return .{ .allocator = allocator, .scanner = .{ .xml = xml } };
}

pub fn configIterator(allocator: std.mem.Allocator, xml: []const u8) ConfigIterator {
    return .{ .allocator = allocator, .scanner = .{ .xml = xml }, .xml = xml };
}

pub fn pinMapIterator(xml: []const u8) PinMapIterator {
    return .{ .scanner = .{ .xml = xml }, .xml = xml };
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

fn pinMapText(xml: []const u8, tag_name: []const u8) []const u8 {
    var scanner = xml_scan.Scanner{ .xml = xml };
    while (scanner.next()) |tag| {
        if (tag.closing or !std.mem.eql(u8, tag.name, tag_name)) continue;
        if (tag.self_closing) return "";
        const text_start = tag.end;
        while (scanner.next()) |closing| {
            if (closing.closing and std.mem.eql(u8, closing.name, tag_name)) {
                return std.mem.trim(u8, xml[text_start..closing.start], " \t\r\n");
            }
        }
    }
    return "";
}

fn parseConfigItems(allocator: std.mem.Allocator, xml: []const u8, item_name: []const u8) ![]const ConfigItem {
    var scanner = xml_scan.Scanner{ .xml = xml };
    var count: usize = 0;
    while (scanner.next()) |tag| {
        if (!tag.closing and std.mem.eql(u8, tag.name, item_name)) count += 1;
    }

    const items = try allocator.alloc(ConfigItem, count);
    errdefer allocator.free(items);

    scanner = .{ .xml = xml };
    var index: usize = 0;
    while (scanner.next()) |tag| {
        if (tag.closing or !std.mem.eql(u8, tag.name, item_name)) continue;
        if (tag.self_closing) continue;
        const close = closingTagAfter(xml, tag.end, item_name) orelse continue;
        const values = std.mem.trim(u8, xml[tag.end..close.start], " \t\r\n");
        const comma = std.mem.indexOfScalar(u8, values, ',') orelse continue;
        items[index] = .{
            .name = xml_scan.attr(tag.attrs, "name") orelse "",
            .mask = xml_scan.parseInt(std.mem.trim(u8, values[0..comma], " \t\r\n")) catch continue,
            .default_value = xml_scan.parseInt(std.mem.trim(u8, values[comma + 1 ..], " \t\r\n")) catch continue,
        };
        index += 1;
    }
    if (index == items.len) return items;
    const trimmed = try allocator.realloc(items, index);
    return trimmed;
}

fn parseGalConfig(allocator: std.mem.Allocator, attrs: []const u8, body: []const u8) !?GalConfig {
    const fuses_size_attr = xml_scan.attr(attrs, "fuses_size") orelse return null;
    return .{
        .fuses_size = try xml_scan.parseInt(fuses_size_attr),
        .row_width = try requiredOptionalInt(attrs, "row_width"),
        .ues_address = try requiredOptionalInt(attrs, "ues_addr"),
        .ues_size = try requiredOptionalInt(attrs, "ues_size"),
        .powerdown_row = try requiredOptionalInt(attrs, "pwrdown_row"),
        .acw_address = try requiredOptionalInt(attrs, "acw_addr"),
        .acw_bits = try parseAcwBits(allocator, body),
    };
}

fn parseAcwBits(allocator: std.mem.Allocator, xml: []const u8) ![]const u16 {
    var scanner = xml_scan.Scanner{ .xml = xml };
    while (scanner.next()) |tag| {
        if (tag.closing or !std.mem.eql(u8, tag.name, "acw_bits")) continue;
        const close = closingTagAfter(xml, tag.end, "acw_bits") orelse break;
        const body = xml[tag.end..close.start];
        return try parseAcwFuseIndices(allocator, body);
    }
    return try allocator.alloc(u16, 0);
}

fn parseAcwFuseIndices(allocator: std.mem.Allocator, xml: []const u8) ![]const u16 {
    var scanner = xml_scan.Scanner{ .xml = xml };
    var count: usize = 0;
    while (scanner.next()) |tag| {
        if (!tag.closing and std.mem.eql(u8, tag.name, "fuse")) count += 1;
    }

    const items = try allocator.alloc(u16, count);
    errdefer allocator.free(items);
    scanner = .{ .xml = xml };
    var index: usize = 0;
    while (scanner.next()) |tag| {
        if (tag.closing or !std.mem.eql(u8, tag.name, "fuse")) continue;
        if (tag.self_closing) continue;
        const close = closingTagAfter(xml, tag.end, "fuse") orelse continue;
        const value = std.mem.trim(u8, xml[tag.end..close.start], " \t\r\n");
        items[index] = @intCast(try xml_scan.parseInt(value));
        index += 1;
    }
    if (index == items.len) return items;
    return try allocator.realloc(items, index);
}

fn closingTagAfter(xml: []const u8, start: usize, name: []const u8) ?xml_scan.Tag {
    var scanner = xml_scan.Scanner{ .xml = xml, .index = start };
    while (scanner.next()) |tag| {
        if (tag.closing and std.mem.eql(u8, tag.name, name)) return tag;
    }
    return null;
}

fn requiredAttr(attrs: []const u8, name: []const u8) []const u8 {
    return xml_scan.attr(attrs, name) orelse @panic("missing required infoic attribute");
}

fn requiredInt(attrs: []const u8, name: []const u8) !u32 {
    return xml_scan.parseInt(requiredAttr(attrs, name));
}

fn requiredOptionalInt(attrs: []const u8, name: []const u8) !u32 {
    return xml_scan.parseInt(xml_scan.attr(attrs, name) orelse "0");
}

test "count and parse infoic devices" {
    const xml =
        \\<infoic>
        \\  <database type="INFOIC2PLUS">
        \\    <manufacturer name="ATMEL">
        \\      <ic name="AT28C64B,AT28C64" type="1" protocol_id="0x05" variant="0x00" read_buffer_size="0x40" write_buffer_size="0x20" code_memory_size="0x2000" data_memory_size="0" data_memory2_size="0" page_size="0x40" pages_per_block="0" chip_id="0x001f" voltages="0x0500" pulse_delay="100" flags="0x30" chip_info="0x06" pin_map="0" package_details="0x1c000000" config="NULL" />
        \\    </manufacturer>
        \\  </database>
        \\</infoic>
    ;

    try std.testing.expectEqual(@as(usize, 1), countDevices(xml));

    var it = iterator(std.testing.allocator, xml);
    const device = (try it.next()).?;
    defer device.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("INFOIC2PLUS", device.database_type);
    try std.testing.expectEqualStrings("ATMEL", device.manufacturer);
    try std.testing.expectEqualStrings("AT28C64B", device.canonical_name);
    try std.testing.expectEqual(@as(usize, 2), device.aliases.len);
    try std.testing.expectEqualStrings("AT28C64", device.aliases[1]);
    try std.testing.expectEqual(@as(u32, 0x2000), device.code_memory_size);
    try std.testing.expect(device.flags.can_erase);
    try std.testing.expect(device.flags.has_chip_id);
    try std.testing.expect(device.flags.can_adjust_vcc);
    try std.testing.expectEqual(@as(u8, 28), device.package_details.pin_count);
    try std.testing.expect(device.supports_tl866ii);
    try std.testing.expect(device.supports_t48);
    try std.testing.expect(device.supports_t56);
    try std.testing.expect((try it.next()) == null);
}

test "parse infoic configurations" {
    const xml =
        \\<infoic>
        \\  <configurations>
        \\    <config name="at89_3">
        \\      <fuses count="1"><fuse name="fuse">0x0001,0x00ff</fuse></fuses>
        \\      <locks count="1"><lock name="lock">0x0007,0x00ff</lock></locks>
        \\    </config>
        \\  </configurations>
        \\</infoic>
    ;

    var it = configIterator(std.testing.allocator, xml);
    const config = (try it.next()).?;
    defer config.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("at89_3", config.name);
    try std.testing.expectEqual(@as(usize, 1), config.fuses.len);
    try std.testing.expectEqualStrings("fuse", config.fuses[0].name);
    try std.testing.expectEqual(@as(u32, 0x0001), config.fuses[0].mask);
    try std.testing.expectEqual(@as(u32, 0x00ff), config.fuses[0].default_value);
    try std.testing.expectEqual(@as(usize, 1), config.locks.len);
    try std.testing.expectEqualStrings("lock", config.locks[0].name);
    try std.testing.expectEqual(@as(u32, 0x0007), config.locks[0].mask);
    try std.testing.expect((try it.next()) == null);
}

test "parse GAL configurations" {
    const xml =
        \\<infoic>
        \\  <configurations>
        \\    <config name="gal1_acw" fuses_size="32" row_width="64" ues_addr="0x0808" ues_size="64" pwrdown_row="0" acw_addr="0x003c">
        \\      <acw_bits count="3"><fuse>2128</fuse><fuse>2129</fuse><fuse>2130</fuse></acw_bits>
        \\    </config>
        \\  </configurations>
        \\</infoic>
    ;

    var it = configIterator(std.testing.allocator, xml);
    const config = (try it.next()).?;
    defer config.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("gal1_acw", config.name);
    const gal = config.gal.?;
    try std.testing.expectEqual(@as(u32, 32), gal.fuses_size);
    try std.testing.expectEqual(@as(u32, 64), gal.row_width);
    try std.testing.expectEqual(@as(u32, 0x0808), gal.ues_address);
    try std.testing.expectEqual(@as(usize, 3), gal.acw_bits.len);
    try std.testing.expectEqual(@as(u16, 2129), gal.acw_bits[1]);
}
