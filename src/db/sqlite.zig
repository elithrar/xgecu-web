// SPDX-License-Identifier: GPL-3.0-or-later

const std = @import("std");
const fuses = @import("../core/fuses.zig");
const import_algorithm = @import("import_algorithm.zig");
const import_infoic = @import("import_infoic.zig");
const import_logicic = @import("import_logicic.zig");

const c = @cImport({
    @cInclude("sqlite3.h");
});

pub const schema = @embedFile("schema.sql");

pub const Error = error{
    Sqlite,
    InvalidDatabase,
};

pub const Database = struct {
    handle: *c.sqlite3,

    pub fn open(path: []const u8) !Database {
        var handle: ?*c.sqlite3 = null;
        const z_path = try std.heap.c_allocator.dupeZ(u8, path);
        defer std.heap.c_allocator.free(z_path);

        if (c.sqlite3_open(z_path.ptr, &handle) != c.SQLITE_OK) {
            if (handle) |db| _ = c.sqlite3_close(db);
            return Error.Sqlite;
        }
        return .{ .handle = handle.? };
    }

    pub fn close(self: *Database) void {
        _ = c.sqlite3_close(self.handle);
        self.* = undefined;
    }

    pub fn exec(self: Database, sql: []const u8) !void {
        const z_sql = try std.heap.c_allocator.dupeZ(u8, sql);
        defer std.heap.c_allocator.free(z_sql);
        var err_msg: [*c]u8 = null;
        const rc = c.sqlite3_exec(self.handle, z_sql.ptr, null, null, &err_msg);
        if (err_msg != null) c.sqlite3_free(err_msg);
        if (rc != c.SQLITE_OK) return Error.Sqlite;
    }

    pub fn applySchema(self: Database) !void {
        try self.exec(schema);
    }

    pub fn importInfoic(self: Database, allocator: std.mem.Allocator, xml: []const u8, source_path: []const u8) !usize {
        try self.exec("BEGIN IMMEDIATE");
        errdefer self.exec("ROLLBACK") catch {};

        const source_id = try self.insertSource("infoic", source_path);

        var databases = DatabaseCache.init(allocator);
        defer databases.deinit();
        var manufacturers = ManufacturerCache.init(allocator);
        defer manufacturers.deinit();

        var devices = import_infoic.iterator(allocator, xml);
        var count: usize = 0;
        while (try devices.next()) |device| {
            defer device.deinit(allocator);

            const database_id = try databases.getOrPut(self, source_id, device.database_type);
            const manufacturer_id = try manufacturers.getOrPut(self, database_id, device.manufacturer, device.is_custom);
            const device_id = try self.insertDevice(database_id, manufacturer_id, device, count);
            try self.insertAliases(device_id, device.aliases);
            try self.insertDecoded(device_id, device);
            try self.insertProgrammers(device_id, device);
            count += 1;
        }

        var configs = import_infoic.configIterator(allocator, xml);
        while (try configs.next()) |config| {
            defer config.deinit(allocator);
            const database_id = try databases.getOrPut(self, source_id, "CONFIG");
            try self.insertConfiguration(database_id, config);
        }

        var pin_maps = import_infoic.pinMapIterator(xml);
        const pin_maps_database_id = try databases.getOrPut(self, source_id, "INFOIC2PLUS");
        while (try pin_maps.next()) |pin_map| {
            try self.insertPinMap(pin_maps_database_id, pin_map);
        }

        try self.exec("COMMIT");
        return count;
    }

    pub fn importLogicic(self: Database, allocator: std.mem.Allocator, xml: []const u8, source_path: []const u8) !usize {
        try self.exec("BEGIN IMMEDIATE");
        errdefer self.exec("ROLLBACK") catch {};

        const source_id = try self.insertSource("logicic", source_path);
        const database_id = try self.insertDatabase(source_id, "LOGIC", "logic", 0);

        var manufacturers = ManufacturerCache.init(allocator);
        defer manufacturers.deinit();

        var devices = import_logicic.iterator(allocator, xml);
        var count: usize = 0;
        while (try devices.next()) |device| {
            defer device.deinit(allocator);

            const manufacturer_id = try manufacturers.getOrPut(self, database_id, device.manufacturer, false);
            const device_id = try self.insertLogicDevice(database_id, manufacturer_id, device, count);
            try self.insertAliases(device_id, device.aliases);
            try self.insertLogicDecoded(device_id, device);
            try self.insertLogicProgrammers(device_id);
            try self.insertLogicVectors(device_id, device.vectors);
            count += 1;
        }

        try self.exec("COMMIT");
        return count;
    }

    pub fn importAlgorithms(self: Database, xml: []const u8, source_path: []const u8) !usize {
        try self.exec("BEGIN IMMEDIATE");
        errdefer self.exec("ROLLBACK") catch {};

        const source_id = try self.insertSource("algorithm", source_path);
        var algorithms = import_algorithm.iterator(xml);
        var count: usize = 0;
        while (try algorithms.next()) |algorithm| {
            try self.insertAlgorithm(source_id, algorithm, count);
            count += 1;
        }

        try self.exec("COMMIT");
        return count;
    }

    pub fn stats(self: Database) !Stats {
        return .{
            .devices = try self.scalarInt("SELECT count(*) FROM devices"),
            .aliases = try self.scalarInt("SELECT count(*) FROM device_aliases"),
            .manufacturers = try self.scalarInt("SELECT count(*) FROM manufacturers"),
        };
    }

    pub fn algorithmBase64(self: Database, allocator: std.mem.Allocator, programmer: []const u8, name: []const u8) !?[]const u8 {
        var stmt = try Statement.prepare(self,
            \\SELECT gzip_base64
            \\FROM algorithms
            \\WHERE programmer = ?1 AND name = ?2
            \\LIMIT 1
        );
        defer stmt.finalize();
        try stmt.bindText(1, programmer);
        try stmt.bindText(2, name);
        if (!try stmt.step()) return null;
        return try stmt.text(0, allocator);
    }

    pub fn listDevices(self: Database, allocator: std.mem.Allocator, programmer: ?[]const u8, limit: usize, writer: anytype) !void {
        var stmt = try Statement.prepare(self, if (programmer == null)
            \\SELECT CASE WHEN devices.is_custom = 1 THEN device_aliases.alias || '(custom)' ELSE device_aliases.alias END
            \\FROM device_aliases
            \\JOIN devices ON devices.id = device_aliases.device_id
            \\ORDER BY devices.id, device_aliases.ordinal
            \\LIMIT ?1
        else
            \\SELECT CASE WHEN devices.is_custom = 1 THEN device_aliases.alias || '(custom)' ELSE device_aliases.alias END
            \\FROM device_aliases
            \\JOIN devices ON devices.id = device_aliases.device_id
            \\JOIN databases ON databases.id = devices.database_id
            \\WHERE databases.programmer_family = ?1 OR databases.programmer_family = 'logic'
            \\ORDER BY CASE WHEN databases.programmer_family = 'logic' THEN 0 ELSE 1 END, devices.id, device_aliases.ordinal
            \\LIMIT ?2
        );
        defer stmt.finalize();
        if (programmer) |value| {
            try stmt.bindText(1, value);
            try stmt.bindInt(2, limit);
        } else {
            try stmt.bindInt(1, limit);
        }
        while (try stmt.step()) {
            try writer.print("{s}\n", .{try stmt.text(0, allocator)});
        }
    }

    pub fn searchDevices(self: Database, allocator: std.mem.Allocator, programmer: ?[]const u8, term: []const u8, limit: usize, writer: anytype) !void {
        var stmt = try Statement.prepare(self, if (programmer == null)
            \\SELECT CASE WHEN devices.is_custom = 1 THEN device_aliases.alias || '(custom)' ELSE device_aliases.alias END
            \\FROM device_aliases
            \\JOIN devices ON devices.id = device_aliases.device_id
            \\WHERE device_aliases.alias_normalized LIKE ?1
            \\ORDER BY devices.id, device_aliases.ordinal
            \\LIMIT ?2
        else
            \\SELECT CASE WHEN devices.is_custom = 1 THEN device_aliases.alias || '(custom)' ELSE device_aliases.alias END
            \\FROM device_aliases
            \\JOIN devices ON devices.id = device_aliases.device_id
            \\JOIN databases ON databases.id = devices.database_id
            \\WHERE (databases.programmer_family = ?1 OR databases.programmer_family = 'logic')
            \\  AND device_aliases.alias_normalized LIKE ?2
            \\ORDER BY CASE WHEN databases.programmer_family = 'logic' THEN 0 ELSE 1 END, devices.id, device_aliases.ordinal
            \\LIMIT ?3
        );
        defer stmt.finalize();
        const pattern = try std.fmt.allocPrint(allocator, "%{s}%", .{term});
        defer allocator.free(pattern);
        asciiLowerInPlace(pattern);
        if (programmer) |value| {
            try stmt.bindText(1, value);
            try stmt.bindText(2, pattern);
            try stmt.bindInt(3, limit);
        } else {
            try stmt.bindText(1, pattern);
            try stmt.bindInt(2, limit);
        }
        while (try stmt.step()) {
            try writer.print("{s}\n", .{try stmt.text(0, allocator)});
        }
    }

    pub fn listDevicesByChipId(self: Database, allocator: std.mem.Allocator, programmer: ?[]const u8, chip_id: u32, pin_count: u8, writer: anytype) !usize {
        var stmt = try Statement.prepare(self,
            \\SELECT CASE WHEN devices.is_custom = 1 THEN device_aliases.alias || '(custom)' ELSE device_aliases.alias END
            \\FROM device_aliases
            \\JOIN devices ON devices.id = device_aliases.device_id
            \\JOIN databases ON databases.id = devices.database_id
            \\LEFT JOIN packages ON packages.device_id = devices.id
            \\WHERE devices.chip_id = ?1
            \\  AND packages.pin_count = ?2
            \\  AND (?3 IS NULL OR databases.programmer_family = ?3 OR databases.programmer_family = 'logic')
            \\ORDER BY devices.id, device_aliases.ordinal
        );
        defer stmt.finalize();
        try stmt.bindInt(1, chip_id);
        try stmt.bindInt(2, pin_count);
        if (programmer) |value| {
            try stmt.bindText(3, value);
        } else {
            try stmt.bindNull(3);
        }
        var count: usize = 0;
        while (try stmt.step()) {
            const text_value = try stmt.text(0, allocator);
            defer allocator.free(text_value);
            try writer.print("{s}\n", .{text_value});
            count += 1;
        }
        return count;
    }

    pub fn deviceInfo(self: Database, allocator: std.mem.Allocator, name: []const u8, programmer_family: ?[]const u8, selected_programmer: ?[]const u8, legacy: bool, writer: anytype) !bool {
        var stmt = try Statement.prepare(self,
            \\SELECT device_aliases.alias, manufacturers.name, devices.code_memory_size,
            \\  devices.data_memory_size, devices.data_memory2_size, devices.page_size,
            \\  devices.chip_type, devices.protocol_id, packages.pin_count, packages.adapter,
            \\  packages.icsp, coalesce(decoded_voltages.vcc_index, 0),
            \\  (SELECT count(*) FROM logic_vectors WHERE logic_vectors.device_id = devices.id),
            \\  devices.id, devices.read_buffer_size, devices.write_buffer_size,
            \\  coalesce(decoded_flags.word_size, 1), coalesce(decoded_flags.can_adjust_vcc, 0),
            \\  coalesce(decoded_flags.can_adjust_vpp, 0), coalesce(decoded_voltages.vdd_index, 0),
            \\  coalesce(decoded_voltages.vpp_index, 0), devices.pulse_delay,
            \\  coalesce(packages.plcc, 0)
            \\FROM device_aliases
            \\JOIN devices ON devices.id = device_aliases.device_id
            \\JOIN databases ON databases.id = devices.database_id
            \\LEFT JOIN manufacturers ON manufacturers.id = devices.manufacturer_id
            \\LEFT JOIN packages ON packages.device_id = devices.id
            \\LEFT JOIN decoded_voltages ON decoded_voltages.device_id = devices.id
            \\LEFT JOIN decoded_flags ON decoded_flags.device_id = devices.id
            \\WHERE device_aliases.alias_normalized = ?1
            \\  AND (?2 IS NULL OR databases.programmer_family = ?2 OR databases.programmer_family = 'logic')
            \\ORDER BY devices.id, device_aliases.ordinal
            \\LIMIT 1
        );
        defer stmt.finalize();

        const normalized = try allocator.dupe(u8, name);
        defer allocator.free(normalized);
        asciiLowerInPlace(normalized);
        try stmt.bindText(1, normalized);
        if (programmer_family) |value| {
            try stmt.bindText(2, value);
        } else {
            try stmt.bindNull(2);
        }
        if (!try stmt.step()) return false;

        const display_name = try stmt.text(0, allocator);
        defer allocator.free(display_name);
        const manufacturer = try stmt.text(1, allocator);
        defer allocator.free(manufacturer);
        const code_size = c.sqlite3_column_int64(stmt.handle, 2);
        const data_size = c.sqlite3_column_int64(stmt.handle, 3);
        const data2_size = c.sqlite3_column_int64(stmt.handle, 4);
        const page_size = c.sqlite3_column_int64(stmt.handle, 5);
        const chip_type = c.sqlite3_column_int64(stmt.handle, 6);
        const protocol_id = c.sqlite3_column_int64(stmt.handle, 7);
        const pin_count = c.sqlite3_column_int64(stmt.handle, 8);
        const adapter = c.sqlite3_column_int64(stmt.handle, 9);
        const icsp = c.sqlite3_column_int64(stmt.handle, 10);
        const device_id = c.sqlite3_column_int64(stmt.handle, 13);
        const read_buffer_size = c.sqlite3_column_int64(stmt.handle, 14);
        const write_buffer_size = c.sqlite3_column_int64(stmt.handle, 15);
        const word_size = c.sqlite3_column_int64(stmt.handle, 16);
        const can_adjust_vcc = c.sqlite3_column_int64(stmt.handle, 17) != 0;
        const can_adjust_vpp = c.sqlite3_column_int64(stmt.handle, 18) != 0;
        const default_vcc_index = c.sqlite3_column_int64(stmt.handle, 11);
        const default_vdd_index = c.sqlite3_column_int64(stmt.handle, 19);
        const default_vpp_index = c.sqlite3_column_int64(stmt.handle, 20);
        const pulse_delay = c.sqlite3_column_int64(stmt.handle, 21);
        const plcc = c.sqlite3_column_int64(stmt.handle, 22) != 0;

        if (chip_type == 5) {
            const vcc_index = c.sqlite3_column_int64(stmt.handle, 11);
            const vector_count = c.sqlite3_column_int64(stmt.handle, 12);

            if (legacy) try writer.writeAll("\n---------------Chip Info----------------\n");
            try writer.print("Name: {s}\n", .{display_name});
            if (adapter != 0) {
                try writer.print("Package:\t Adapter{d:0>3}.JPG\n", .{adapter});
            } else if (pin_count != 0) {
                try writer.print("Package:\t {s}{d}\n", .{ packagePrefix(plcc), pin_count });
            } else {
                try writer.writeAll("Package:\t ICSP only\n");
            }
            try writer.print("Vector count:\t {d}\n", .{vector_count});
            if (legacy) try writer.writeAll("----------------------------------------\n");
            try writer.print("Default VCC voltage: {s} V\n", .{logicVoltageLabel(@intCast(vcc_index))});
            if (legacy) {
                try writer.writeAll("Available VCC voltages [V]: 1.8, 2.5, \n3.3, 5\n");
            } else {
                try writer.writeAll("Available VCC voltages [V]: 1.8, 2.5, 3.3, 5\n");
            }
            return true;
        }

        if (legacy) {
            try writer.writeAll("\n---------------Chip Info----------------\n");
            try writer.print("Name: {s}\n", .{display_name});
            try self.writeAvailableOn(device_id, writer);
            if (word_size > 1) {
                try writer.print("Memory: {d} Words", .{@divTrunc(code_size, word_size)});
            } else {
                try writer.print("Memory: {d} Bytes", .{code_size});
                if (data_size != 0) try writer.print(" + {d} Bytes", .{data_size});
                if (data2_size != 0) try writer.print(" + {d} Bytes", .{data2_size});
            }
            try writer.writeAll("\n");
            if (adapter != 0) {
                try writer.print("Package: Adapter{d:0>3}.JPG\n", .{adapter});
            } else if (pin_count != 0) {
                try writer.print("Package: {s}{d}\n", .{ packagePrefix(plcc), pin_count });
            } else {
                try writer.writeAll("Package: ICSP only\n");
            }
            if (icsp != 0) try writer.print("ICSP: ICP{d:0>3}.JPG\n", .{icsp});
            try writer.print("Protocol: 0x{x:0>2}\n", .{@as(u64, @intCast(protocol_id))});
            if (read_buffer_size != 0 and write_buffer_size != 0) {
                try writer.print("Read buffer size: {d} Bytes\n", .{read_buffer_size});
                try writer.print("Write buffer size: {d} Bytes\n", .{write_buffer_size});
            }
            if (can_adjust_vcc or can_adjust_vpp) {
                const family = selected_programmer orelse programmer_family orelse "tl866ii";
                const vpp_table = voltageTable(family, .vpp);
                const vcc_table = voltageTable(family, .vcc);
                try writer.writeAll("----------------------------------------\n");
                try writer.print("Default VPP programming voltage: {s} V\n", .{parameterLabel(vpp_table, @intCast(default_vpp_index))});
                try printParameterTable(writer, "Available VPP voltages [V]: ", vpp_table);
                try writer.writeAll("\n");
                if (can_adjust_vcc) {
                    try writer.print("Default VDD write voltage: {s} V\n", .{parameterLabel(vcc_table, @intCast(default_vdd_index))});
                    try printParameterTable(writer, "Available VDD write voltages [V]: ", vcc_table);
                    try writer.writeAll("\n");
                    try writer.print("Default VCC verify voltage: {s} V\n", .{parameterLabel(vcc_table, @intCast(default_vcc_index))});
                    try printParameterTable(writer, "Available VCC verify voltages [V]: ", vcc_table);
                    try writer.writeAll("\n");
                    try writer.print("Default write pulse: {d} us\nAvailable write pulse[us]: 1-65535\n", .{pulse_delay});
                }
            }
            try writer.writeAll("----------------------------------------\n");
            return true;
        }

        try writer.print("Name: {s}\n", .{display_name});
        try writer.print("Manufacturer: {s}\n", .{manufacturer});
        try writer.print("Type: {d}\n", .{chip_type});
        try writer.print("Memory: {d} Bytes", .{code_size});
        if (data_size != 0) try writer.print(" + {d} Bytes", .{data_size});
        if (data2_size != 0) try writer.print(" + {d} Bytes", .{data2_size});
        try writer.writeAll("\n");
        try writer.print("Page size: {d} Bytes\n", .{page_size});
        if (adapter != 0) {
            try writer.print("Package: Adapter{d:0>3}.JPG\n", .{adapter});
        } else if (pin_count != 0) {
            try writer.print("Package: {s}{d}\n", .{ packagePrefix(plcc), pin_count });
        } else {
            try writer.writeAll("Package: ICSP only\n");
        }
        if (icsp != 0) try writer.print("ICSP: ICP{d:0>3}.JPG\n", .{icsp});
        try writer.print("Protocol: 0x{x:0>2}\n", .{@as(u64, @intCast(protocol_id))});
        return true;
    }

    pub fn protocolDevice(self: Database, allocator: std.mem.Allocator, name: []const u8, programmer_family: ?[]const u8) !?ProtocolDevice {
        var stmt = try Statement.prepare(self,
            \\SELECT devices.canonical_name, devices.chip_type, devices.protocol_id, devices.variant,
            \\  devices.voltages_raw, devices.chip_info, devices.pin_map_raw,
            \\  devices.data_memory_size, devices.data_memory2_size, devices.page_size,
            \\  devices.pulse_delay, devices.code_memory_size, devices.package_details_raw,
            \\  devices.read_buffer_size, devices.write_buffer_size, devices.flags_raw,
            \\  coalesce(decoded_flags.can_adjust_clock, 0), devices.chip_id,
            \\  devices.chip_id_bytes_count, devices.blank_value, devices.compare_mask,
            \\  devices.config_ref,
            \\  (SELECT count(*) FROM configurations JOIN config_fuses ON config_fuses.configuration_id = configurations.id WHERE configurations.name = devices.config_ref),
            \\  (SELECT count(*) FROM configurations JOIN config_locks ON config_locks.configuration_id = configurations.id WHERE configurations.name = devices.config_ref),
            \\  coalesce((SELECT group_concat(config_fuses.name || ':0x' || printf('%04x', config_fuses.mask) || '/0x' || printf('%04x', config_fuses.default_value), ', ') FROM configurations JOIN config_fuses ON config_fuses.configuration_id = configurations.id WHERE configurations.name = devices.config_ref ORDER BY config_fuses.ordinal), ''),
            \\  coalesce((SELECT group_concat(config_locks.name || ':0x' || printf('%04x', config_locks.mask) || '/0x' || printf('%04x', config_locks.default_value), ', ') FROM configurations JOIN config_locks ON config_locks.configuration_id = configurations.id WHERE configurations.name = devices.config_ref ORDER BY config_locks.ordinal), '')
            \\FROM device_aliases
            \\JOIN devices ON devices.id = device_aliases.device_id
            \\JOIN databases ON databases.id = devices.database_id
            \\LEFT JOIN decoded_flags ON decoded_flags.device_id = devices.id
            \\WHERE device_aliases.alias_normalized = ?1
            \\  AND (?2 IS NULL OR databases.programmer_family = ?2 OR databases.programmer_family = 'logic')
            \\ORDER BY devices.id, device_aliases.ordinal
            \\LIMIT 1
        );
        defer stmt.finalize();

        const normalized = try allocator.dupe(u8, name);
        defer allocator.free(normalized);
        asciiLowerInPlace(normalized);
        try stmt.bindText(1, normalized);
        if (programmer_family) |value| {
            try stmt.bindText(2, value);
        } else {
            try stmt.bindNull(2);
        }
        if (!try stmt.step()) return null;

        return .{
            .canonical_name = try stmt.text(0, allocator),
            .chip_type = @intCast(c.sqlite3_column_int64(stmt.handle, 1)),
            .protocol_id = @intCast(c.sqlite3_column_int64(stmt.handle, 2)),
            .variant = @intCast(c.sqlite3_column_int64(stmt.handle, 3)),
            .voltages_raw = @intCast(c.sqlite3_column_int64(stmt.handle, 4)),
            .chip_info = @intCast(c.sqlite3_column_int64(stmt.handle, 5)),
            .pin_map = @intCast(c.sqlite3_column_int64(stmt.handle, 6)),
            .data_memory_size = @intCast(c.sqlite3_column_int64(stmt.handle, 7)),
            .data_memory2_size = @intCast(c.sqlite3_column_int64(stmt.handle, 8)),
            .page_size = @intCast(c.sqlite3_column_int64(stmt.handle, 9)),
            .pulse_delay = @intCast(c.sqlite3_column_int64(stmt.handle, 10)),
            .code_memory_size = @intCast(c.sqlite3_column_int64(stmt.handle, 11)),
            .package_details_raw = @intCast(c.sqlite3_column_int64(stmt.handle, 12)),
            .read_buffer_size = @intCast(c.sqlite3_column_int64(stmt.handle, 13)),
            .write_buffer_size = @intCast(c.sqlite3_column_int64(stmt.handle, 14)),
            .flags_raw = @intCast(c.sqlite3_column_int64(stmt.handle, 15)),
            .can_adjust_clock = c.sqlite3_column_int64(stmt.handle, 16) != 0,
            .chip_id = @intCast(c.sqlite3_column_int64(stmt.handle, 17)),
            .chip_id_bytes_count = @intCast(c.sqlite3_column_int64(stmt.handle, 18)),
            .blank_value = @intCast(c.sqlite3_column_int64(stmt.handle, 19)),
            .compare_mask = @intCast(c.sqlite3_column_int64(stmt.handle, 20)),
            .config_ref = try stmt.text(21, allocator),
            .config_fuse_count = @intCast(c.sqlite3_column_int64(stmt.handle, 22)),
            .config_lock_count = @intCast(c.sqlite3_column_int64(stmt.handle, 23)),
            .config_fuse_details = try stmt.text(24, allocator),
            .config_lock_details = try stmt.text(25, allocator),
        };
    }

    pub fn configItems(self: Database, allocator: std.mem.Allocator, config_ref: []const u8, kind: ConfigItemKind) !ConfigItems {
        const sql = switch (kind) {
            .fuse => "SELECT config_fuses.name, config_fuses.mask, config_fuses.default_value FROM configurations JOIN config_fuses ON config_fuses.configuration_id = configurations.id WHERE configurations.name = ?1 ORDER BY config_fuses.ordinal",
            .lock => "SELECT config_locks.name, config_locks.mask, config_locks.default_value FROM configurations JOIN config_locks ON config_locks.configuration_id = configurations.id WHERE configurations.name = ?1 ORDER BY config_locks.ordinal",
        };
        var stmt = try Statement.prepare(self, sql);
        defer stmt.finalize();
        try stmt.bindText(1, config_ref);

        var items: std.ArrayListUnmanaged(fuses.ConfigItem) = .empty;
        errdefer {
            for (items.items) |item| allocator.free(item.name);
            items.deinit(allocator);
        }
        while (try stmt.step()) {
            try items.append(allocator, .{
                .name = try stmt.text(0, allocator),
                .mask = @intCast(c.sqlite3_column_int64(stmt.handle, 1)),
                .default_value = @intCast(c.sqlite3_column_int64(stmt.handle, 2)),
            });
        }
        return .{ .items = try items.toOwnedSlice(allocator) };
    }

    pub fn galConfig(self: Database, allocator: std.mem.Allocator, config_ref: []const u8) !?GalConfig {
        var stmt = try Statement.prepare(self, "SELECT config_gal.fuses_size, config_gal.row_width, config_gal.ues_address, config_gal.ues_size, config_gal.powerdown_row, config_gal.acw_address FROM configurations JOIN config_gal ON config_gal.configuration_id = configurations.id WHERE configurations.name = ?1 LIMIT 1");
        defer stmt.finalize();
        try stmt.bindText(1, config_ref);
        if (!try stmt.step()) return null;

        var bits_stmt = try Statement.prepare(self, "SELECT config_gal_acw_bits.fuse_index FROM configurations JOIN config_gal_acw_bits ON config_gal_acw_bits.configuration_id = configurations.id WHERE configurations.name = ?1 ORDER BY config_gal_acw_bits.ordinal");
        defer bits_stmt.finalize();
        try bits_stmt.bindText(1, config_ref);
        var acw_bits: std.ArrayListUnmanaged(u16) = .empty;
        errdefer acw_bits.deinit(allocator);
        while (try bits_stmt.step()) {
            try acw_bits.append(allocator, @intCast(c.sqlite3_column_int64(bits_stmt.handle, 0)));
        }

        return .{
            .fuses_size = @intCast(c.sqlite3_column_int64(stmt.handle, 0)),
            .row_width = @intCast(c.sqlite3_column_int64(stmt.handle, 1)),
            .ues_address = @intCast(c.sqlite3_column_int64(stmt.handle, 2)),
            .ues_size = @intCast(c.sqlite3_column_int64(stmt.handle, 3)),
            .powerdown_row = @intCast(c.sqlite3_column_int64(stmt.handle, 4)),
            .acw_address = @intCast(c.sqlite3_column_int64(stmt.handle, 5)),
            .acw_bits = try acw_bits.toOwnedSlice(allocator),
        };
    }

    pub fn logicDevice(self: Database, allocator: std.mem.Allocator, name: []const u8) !?LogicDevice {
        var stmt = try Statement.prepare(self,
            \\SELECT devices.id, devices.canonical_name, packages.pin_count, coalesce(decoded_voltages.vcc_index, 0)
            \\FROM device_aliases
            \\JOIN devices ON devices.id = device_aliases.device_id
            \\JOIN databases ON databases.id = devices.database_id
            \\LEFT JOIN packages ON packages.device_id = devices.id
            \\LEFT JOIN decoded_voltages ON decoded_voltages.device_id = devices.id
            \\WHERE device_aliases.alias_normalized = ?1
            \\  AND databases.programmer_family = 'logic'
            \\ORDER BY devices.id, device_aliases.ordinal
            \\LIMIT 1
        );
        defer stmt.finalize();

        const normalized = try allocator.dupe(u8, name);
        defer allocator.free(normalized);
        asciiLowerInPlace(normalized);
        try stmt.bindText(1, normalized);
        if (!try stmt.step()) return null;

        const device_id = c.sqlite3_column_int64(stmt.handle, 0);
        var vectors_stmt = try Statement.prepare(self, "SELECT vector_id, states FROM logic_vectors WHERE device_id = ?1 ORDER BY ordinal");
        defer vectors_stmt.finalize();
        try vectors_stmt.bindInt(1, device_id);

        var vectors: std.ArrayListUnmanaged(LogicVector) = .empty;
        errdefer {
            for (vectors.items) |vector| vector.deinit(allocator);
            vectors.deinit(allocator);
        }
        while (try vectors_stmt.step()) {
            try vectors.append(allocator, .{
                .id = try vectors_stmt.text(0, allocator),
                .states = try vectors_stmt.text(1, allocator),
            });
        }

        return .{
            .canonical_name = try stmt.text(1, allocator),
            .pin_count = @intCast(c.sqlite3_column_int64(stmt.handle, 2)),
            .vcc_index = @intCast(c.sqlite3_column_int64(stmt.handle, 3)),
            .vectors = try vectors.toOwnedSlice(allocator),
        };
    }

    fn writeAvailableOn(self: Database, device_id: i64, writer: anytype) !void {
        var stmt = try Statement.prepare(self,
            \\SELECT programmer FROM device_programmers
            \\WHERE device_id = ?1 AND supported = 1
            \\ORDER BY CASE programmer
            \\  WHEN 'tl866a' THEN 0
            \\  WHEN 'tl866ii' THEN 1
            \\  WHEN 't48' THEN 2
            \\  WHEN 't56' THEN 3
            \\  WHEN 't76' THEN 4
            \\  ELSE 5 END
        );
        defer stmt.finalize();
        try stmt.bindInt(1, device_id);
        var labels: [5][]const u8 = undefined;
        var count: usize = 0;
        try writer.writeAll("Available on: ");
        while (try stmt.step()) {
            const programmer = c.sqlite3_column_text(stmt.handle, 0) orelse continue;
            const len: usize = @intCast(c.sqlite3_column_bytes(stmt.handle, 0));
            labels[count] = programmerLabel(programmer[0..len]);
            count += 1;
        }
        for (labels[0..count], 0..) |label, index| {
            if (index != 0) try writer.writeAll(", ");
            try writer.writeAll(label);
        }
        if (count == 1 and !std.mem.eql(u8, labels[0], "TL866A/CS") and !std.mem.eql(u8, labels[0], "T76")) try writer.writeAll(" only");
        try writer.writeAll("\n");
    }

    pub fn query(self: Database, allocator: std.mem.Allocator, sql: []const u8, writer: anytype) !void {
        var stmt = try Statement.prepare(self, sql);
        defer stmt.finalize();

        const columns = c.sqlite3_column_count(stmt.handle);
        var first_row = true;
        while (try stmt.step()) {
            if (!first_row) try writer.writeAll("\n");
            first_row = false;
            var column: c_int = 0;
            while (column < columns) : (column += 1) {
                if (column != 0) try writer.writeAll("\t");
                const value = try stmt.text(column, allocator);
                try writer.writeAll(value);
            }
        }
        if (!first_row) try writer.writeAll("\n");
    }

    pub fn pinMap(self: Database, allocator: std.mem.Allocator, map_index: u32) !?PinMap {
        var stmt = try Statement.prepare(self,
            \\SELECT gnd_pins, masks FROM pin_maps WHERE map_index = ?1 LIMIT 1
        );
        defer stmt.finalize();
        try stmt.bindInt(1, map_index);
        if (!try stmt.step()) return null;
        const gnd_text = columnText(stmt.handle, 0);
        const mask_text = columnText(stmt.handle, 1);
        const gnd_pins = try parsePinList(allocator, gnd_text);
        errdefer allocator.free(gnd_pins);
        const masks = try parsePinList(allocator, mask_text);
        return .{ .gnd_pins = gnd_pins, .masks = masks };
    }

    fn insertSource(self: Database, kind: []const u8, source_path: []const u8) !i64 {
        var stmt = try Statement.prepare(self,
            \\INSERT INTO sources(kind, path, sha256, imported_at, upstream_version)
            \\VALUES (?1, ?2, 'not-calculated-yet', datetime('now'), NULL)
        );
        defer stmt.finalize();
        try stmt.bindText(1, kind);
        try stmt.bindText(2, source_path);
        try stmt.done();
        return c.sqlite3_last_insert_rowid(self.handle);
    }

    fn insertDatabase(self: Database, source_id: i64, xml_type: []const u8, programmer_family: ?[]const u8, ordinal: usize) !i64 {
        var stmt = try Statement.prepare(self,
            \\INSERT INTO databases(source_id, xml_type, programmer_family, ordinal)
            \\VALUES (?1, ?2, ?3, ?4)
        );
        defer stmt.finalize();
        try stmt.bindInt(1, source_id);
        try stmt.bindText(2, xml_type);
        if (programmer_family) |value| try stmt.bindText(3, value) else try stmt.bindNull(3);
        try stmt.bindInt(4, ordinal);
        try stmt.done();
        return c.sqlite3_last_insert_rowid(self.handle);
    }

    fn insertAlgorithm(self: Database, source_id: i64, algorithm: import_algorithm.Algorithm, ordinal: usize) !void {
        _ = ordinal;
        var stmt = try Statement.prepare(self,
            \\INSERT INTO algorithms(source_id, programmer, name, gzip_base64, bitstream, sha256)
            \\VALUES (?1, ?2, ?3, ?4, NULL, NULL)
            \\ON CONFLICT(programmer, name) DO UPDATE SET
            \\  source_id = excluded.source_id,
            \\  gzip_base64 = excluded.gzip_base64,
            \\  bitstream = NULL,
            \\  sha256 = NULL
        );
        defer stmt.finalize();
        try stmt.bindInt(1, source_id);
        try stmt.bindText(2, algorithm.programmer);
        try stmt.bindText(3, algorithm.name);
        try stmt.bindText(4, algorithm.gzip_base64);
        try stmt.done();
    }

    fn insertManufacturer(self: Database, database_id: i64, name: []const u8, is_custom: bool, ordinal: usize) !i64 {
        var stmt = try Statement.prepare(self,
            \\INSERT INTO manufacturers(database_id, name, is_custom, ordinal)
            \\VALUES (?1, ?2, ?3, ?4)
        );
        defer stmt.finalize();
        try stmt.bindInt(1, database_id);
        try stmt.bindText(2, name);
        try stmt.bindInt(3, boolInt(is_custom));
        try stmt.bindInt(4, ordinal);
        try stmt.done();
        return c.sqlite3_last_insert_rowid(self.handle);
    }

    fn insertDevice(self: Database, database_id: i64, manufacturer_id: i64, device: import_infoic.Device, ordinal: usize) !i64 {
        var stmt = try Statement.prepare(self,
            \\INSERT INTO devices(
            \\  database_id, manufacturer_id, canonical_name, chip_type, protocol_id, variant,
            \\  read_buffer_size, write_buffer_size, code_memory_size, data_memory_size,
            \\  data_memory2_size, page_size, pages_per_block, chip_id, chip_id_bytes_count,
            \\  voltages_raw, pulse_delay, flags_raw, chip_info, pin_map_raw,
            \\  package_details_raw, compare_mask, blank_value, config_ref, is_custom, ordinal
            \\) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17, ?18, ?19, ?20, ?21, ?22, ?23, ?24, ?25, ?26)
        );
        defer stmt.finalize();
        try stmt.bindInt(1, database_id);
        try stmt.bindInt(2, manufacturer_id);
        try stmt.bindText(3, device.canonical_name);
        try stmt.bindInt(4, device.chip_type);
        try stmt.bindInt(5, device.protocol_id & 0xff);
        try stmt.bindInt(6, device.variant);
        try stmt.bindInt(7, device.read_buffer_size);
        try stmt.bindInt(8, device.write_buffer_size);
        try stmt.bindInt(9, device.code_memory_size);
        try stmt.bindInt(10, device.data_memory_size);
        try stmt.bindInt(11, device.data_memory2_size);
        try stmt.bindInt(12, device.page_size);
        try stmt.bindInt(13, device.pages_per_block);
        try stmt.bindInt(14, device.chip_id);
        try stmt.bindInt(15, chipIdByteCount(device.chip_id));
        try stmt.bindInt(16, device.voltages.raw_voltages);
        try stmt.bindInt(17, device.pulse_delay);
        try stmt.bindInt(18, device.flags.raw_flags);
        try stmt.bindInt(19, device.chip_info);
        try stmt.bindInt(20, device.pin_map_raw);
        try stmt.bindInt(21, device.package_details.packed_package);
        try stmt.bindInt(22, 0xff);
        try stmt.bindInt(23, 0xff);
        try stmt.bindText(24, device.config_ref);
        try stmt.bindInt(25, boolInt(device.is_custom));
        try stmt.bindInt(26, ordinal);
        try stmt.done();
        return c.sqlite3_last_insert_rowid(self.handle);
    }

    fn insertLogicDevice(self: Database, database_id: i64, manufacturer_id: i64, device: import_logicic.Device, ordinal: usize) !i64 {
        var stmt = try Statement.prepare(self,
            \\INSERT INTO devices(
            \\  database_id, manufacturer_id, canonical_name, chip_type, protocol_id, variant,
            \\  read_buffer_size, write_buffer_size, code_memory_size, data_memory_size,
            \\  data_memory2_size, page_size, pages_per_block, chip_id, chip_id_bytes_count,
            \\  voltages_raw, pulse_delay, flags_raw, chip_info, pin_map_raw,
            \\  package_details_raw, compare_mask, blank_value, config_ref, is_custom, ordinal
            \\) VALUES (?1, ?2, ?3, 5, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, ?4, 0, 0, 0, 0, ?5, 255, 255, 'NULL', ?6, ?7)
        );
        defer stmt.finalize();
        const package_raw = device.pin_count << 24;
        try stmt.bindInt(1, database_id);
        try stmt.bindInt(2, manufacturer_id);
        try stmt.bindText(3, device.canonical_name);
        try stmt.bindInt(4, logicVoltageRaw(device.voltage));
        try stmt.bindInt(5, package_raw);
        try stmt.bindInt(6, boolInt(device.is_custom));
        try stmt.bindInt(7, ordinal);
        try stmt.done();
        return c.sqlite3_last_insert_rowid(self.handle);
    }

    fn insertAliases(self: Database, device_id: i64, aliases: []const []const u8) !void {
        var stmt = try Statement.prepare(self,
            \\INSERT INTO device_aliases(device_id, alias, alias_normalized, ordinal)
            \\VALUES (?1, ?2, ?3, ?4)
        );
        defer stmt.finalize();
        for (aliases, 0..) |alias, ordinal| {
            try stmt.reset();
            try stmt.bindInt(1, device_id);
            try stmt.bindText(2, alias);
            const lower = try std.heap.c_allocator.dupe(u8, alias);
            defer std.heap.c_allocator.free(lower);
            asciiLowerInPlace(lower);
            try stmt.bindText(3, lower);
            try stmt.bindInt(4, ordinal);
            try stmt.done();
        }
    }

    fn insertDecoded(self: Database, device_id: i64, device: import_infoic.Device) !void {
        var flags_stmt = try Statement.prepare(self,
            \\INSERT INTO decoded_flags(device_id, can_erase, has_chip_id, has_data_offset, off_protect_before, protect_after,
            \\  lock_bit_write_only, has_calibration, prog_support, word_size, data_org, can_adjust_vpp, can_adjust_vcc,
            \\  can_adjust_clock, can_adjust_address, custom_protocol, has_power_down, is_powerdown_disabled, reversed_package)
            \\VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17, ?18, ?19)
        );
        defer flags_stmt.finalize();
        const f = device.flags;
        try flags_stmt.bindInt(1, device_id);
        try flags_stmt.bindInt(2, boolInt(f.can_erase));
        try flags_stmt.bindInt(3, boolInt(f.has_chip_id));
        try flags_stmt.bindInt(4, boolInt(f.has_data_offset));
        try flags_stmt.bindInt(5, boolInt(f.off_protect_before));
        try flags_stmt.bindInt(6, boolInt(f.protect_after));
        try flags_stmt.bindInt(7, boolInt(f.lock_bit_write_only));
        try flags_stmt.bindInt(8, boolInt(f.has_calibration));
        try flags_stmt.bindInt(9, f.prog_support);
        try flags_stmt.bindInt(10, f.word_size);
        try flags_stmt.bindInt(11, f.data_org);
        try flags_stmt.bindInt(12, boolInt(f.can_adjust_vpp));
        try flags_stmt.bindInt(13, boolInt(f.can_adjust_vcc));
        try flags_stmt.bindInt(14, boolInt(f.can_adjust_clock));
        try flags_stmt.bindInt(15, boolInt(f.can_adjust_address));
        try flags_stmt.bindInt(16, boolInt(f.custom_protocol));
        try flags_stmt.bindInt(17, boolInt(f.has_power_down));
        try flags_stmt.bindInt(18, boolInt(f.is_powerdown_disabled));
        try flags_stmt.bindInt(19, boolInt(f.reversed_package));
        try flags_stmt.done();

        var volt_stmt = try Statement.prepare(self,
            \\INSERT INTO decoded_voltages(device_id, vcc_index, vdd_index, vpp_index)
            \\VALUES (?1, ?2, ?3, ?4)
        );
        defer volt_stmt.finalize();
        try volt_stmt.bindInt(1, device_id);
        try volt_stmt.bindInt(2, device.voltages.vcc);
        try volt_stmt.bindInt(3, device.voltages.vdd);
        try volt_stmt.bindInt(4, device.voltages.vpp);
        try volt_stmt.done();

        var package_stmt = try Statement.prepare(self,
            \\INSERT INTO packages(device_id, pin_count, adapter, plcc, icsp, smd)
            \\VALUES (?1, ?2, ?3, ?4, ?5, ?6)
        );
        defer package_stmt.finalize();
        try package_stmt.bindInt(1, device_id);
        try package_stmt.bindInt(2, device.package_details.pin_count);
        try package_stmt.bindInt(3, device.package_details.adapter);
        try package_stmt.bindInt(4, boolInt(device.package_details.plcc));
        try package_stmt.bindInt(5, device.package_details.icsp);
        try package_stmt.bindInt(6, boolInt(device.package_details.smd));
        try package_stmt.done();
    }

    fn insertProgrammers(self: Database, device_id: i64, device: import_infoic.Device) !void {
        var stmt = try Statement.prepare(self,
            \\INSERT INTO device_programmers(device_id, programmer, supported, only_flag)
            \\VALUES (?1, ?2, ?3, ?4)
        );
        defer stmt.finalize();
        try insertProgrammer(&stmt, device_id, "tl866a", device.supports_tl866a);
        try insertProgrammer(&stmt, device_id, "tl866ii", device.supports_tl866ii);
        try insertProgrammer(&stmt, device_id, "t48", device.supports_t48);
        try insertProgrammer(&stmt, device_id, "t56", device.supports_t56);
        try insertProgrammer(&stmt, device_id, "t76", device.supports_t76);
    }

    fn insertConfiguration(self: Database, database_id: i64, config: import_infoic.Config) !void {
        var config_stmt = try Statement.prepare(self,
            \\INSERT INTO configurations(database_id, name, kind, raw_xml)
            \\VALUES (?1, ?2, 'mcu', ?3)
        );
        defer config_stmt.finalize();
        try config_stmt.bindInt(1, database_id);
        try config_stmt.bindText(2, config.name);
        try config_stmt.bindText(3, config.raw_xml);
        try config_stmt.done();
        const configuration_id = c.sqlite3_last_insert_rowid(self.handle);

        try self.insertConfigItems("config_fuses", configuration_id, config.fuses);
        try self.insertConfigItems("config_locks", configuration_id, config.locks);
        if (config.gal) |gal| try self.insertGalConfig(configuration_id, gal);
    }

    fn insertPinMap(self: Database, database_id: i64, pin_map: import_infoic.PinMap) !void {
        var stmt = try Statement.prepare(self, "INSERT OR REPLACE INTO pin_maps(database_id, map_index, gnd_pins, masks) VALUES (?1, ?2, ?3, ?4)");
        defer stmt.finalize();
        try stmt.bindInt(1, database_id);
        try stmt.bindInt(2, pin_map.index);
        try stmt.bindText(3, pin_map.gnd_pins);
        try stmt.bindText(4, pin_map.masks);
        try stmt.done();
    }

    fn insertGalConfig(self: Database, configuration_id: i64, gal: import_infoic.GalConfig) !void {
        var stmt = try Statement.prepare(self, "INSERT INTO config_gal(configuration_id, fuses_size, row_width, ues_address, ues_size, powerdown_row, acw_address) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)");
        defer stmt.finalize();
        try stmt.bindInt(1, configuration_id);
        try stmt.bindInt(2, gal.fuses_size);
        try stmt.bindInt(3, gal.row_width);
        try stmt.bindInt(4, gal.ues_address);
        try stmt.bindInt(5, gal.ues_size);
        try stmt.bindInt(6, gal.powerdown_row);
        try stmt.bindInt(7, gal.acw_address);
        try stmt.done();

        var bit_stmt = try Statement.prepare(self, "INSERT INTO config_gal_acw_bits(configuration_id, ordinal, fuse_index) VALUES (?1, ?2, ?3)");
        defer bit_stmt.finalize();
        for (gal.acw_bits, 0..) |fuse_index, ordinal| {
            try bit_stmt.reset();
            try bit_stmt.bindInt(1, configuration_id);
            try bit_stmt.bindInt(2, ordinal);
            try bit_stmt.bindInt(3, fuse_index);
            try bit_stmt.done();
        }
    }

    fn insertConfigItems(self: Database, table_name: []const u8, configuration_id: i64, items: []const import_infoic.ConfigItem) !void {
        const sql = if (std.mem.eql(u8, table_name, "config_fuses"))
            \\INSERT INTO config_fuses(configuration_id, ordinal, name, mask, default_value)
            \\VALUES (?1, ?2, ?3, ?4, ?5)
        else
            \\INSERT INTO config_locks(configuration_id, ordinal, name, mask, default_value)
            \\VALUES (?1, ?2, ?3, ?4, ?5)
        ;
        var stmt = try Statement.prepare(self, sql);
        defer stmt.finalize();
        for (items, 0..) |item, ordinal| {
            try stmt.reset();
            try stmt.bindInt(1, configuration_id);
            try stmt.bindInt(2, ordinal);
            try stmt.bindText(3, item.name);
            try stmt.bindInt(4, item.mask);
            try stmt.bindInt(5, item.default_value);
            try stmt.done();
        }
    }

    fn insertLogicProgrammers(self: Database, device_id: i64) !void {
        var stmt = try Statement.prepare(self,
            \\INSERT INTO device_programmers(device_id, programmer, supported, only_flag)
            \\VALUES (?1, ?2, ?3, ?4)
        );
        defer stmt.finalize();
        try insertProgrammer(&stmt, device_id, "tl866a", true);
        try insertProgrammer(&stmt, device_id, "tl866ii", true);
        try insertProgrammer(&stmt, device_id, "t48", true);
        try insertProgrammer(&stmt, device_id, "t56", true);
        try insertProgrammer(&stmt, device_id, "t76", true);
    }

    fn insertLogicDecoded(self: Database, device_id: i64, device: import_logicic.Device) !void {
        var flags_stmt = try Statement.prepare(self,
            \\INSERT INTO decoded_flags(device_id, can_erase, has_chip_id, has_data_offset, off_protect_before, protect_after,
            \\  lock_bit_write_only, has_calibration, prog_support, word_size, data_org, can_adjust_vpp, can_adjust_vcc,
            \\  can_adjust_clock, can_adjust_address, custom_protocol, has_power_down, is_powerdown_disabled, reversed_package)
            \\VALUES (?1, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        );
        defer flags_stmt.finalize();
        try flags_stmt.bindInt(1, device_id);
        try flags_stmt.done();

        var volt_stmt = try Statement.prepare(self,
            \\INSERT INTO decoded_voltages(device_id, vcc_index, vdd_index, vpp_index)
            \\VALUES (?1, ?2, 0, 0)
        );
        defer volt_stmt.finalize();
        try volt_stmt.bindInt(1, device_id);
        try volt_stmt.bindInt(2, logicVoltageIndex(device.voltage));
        try volt_stmt.done();

        var package_stmt = try Statement.prepare(self,
            \\INSERT INTO packages(device_id, pin_count, adapter, plcc, icsp, smd)
            \\VALUES (?1, ?2, 0, 0, 0, 0)
        );
        defer package_stmt.finalize();
        try package_stmt.bindInt(1, device_id);
        try package_stmt.bindInt(2, device.pin_count);
        try package_stmt.done();
    }

    fn insertLogicVectors(self: Database, device_id: i64, vectors: []const import_logicic.Vector) !void {
        var stmt = try Statement.prepare(self,
            \\INSERT INTO logic_vectors(device_id, vector_id, states, ordinal)
            \\VALUES (?1, ?2, ?3, ?4)
        );
        defer stmt.finalize();
        for (vectors, 0..) |vector, ordinal| {
            try stmt.reset();
            try stmt.bindInt(1, device_id);
            try stmt.bindText(2, vector.id);
            try stmt.bindText(3, vector.states);
            try stmt.bindInt(4, ordinal);
            try stmt.done();
        }
    }

    fn scalarInt(self: Database, sql: []const u8) !usize {
        var stmt = try Statement.prepare(self, sql);
        defer stmt.finalize();
        if (!try stmt.step()) return Error.InvalidDatabase;
        return @intCast(c.sqlite3_column_int64(stmt.handle, 0));
    }
};

fn insertProgrammer(stmt: *Statement, device_id: i64, programmer: []const u8, supported: bool) !void {
    try stmt.reset();
    try stmt.bindInt(1, device_id);
    try stmt.bindText(2, programmer);
    try stmt.bindInt(3, boolInt(supported));
    try stmt.bindInt(4, boolInt(supported));
    try stmt.done();
}

pub const Stats = struct {
    devices: usize,
    aliases: usize,
    manufacturers: usize,
};

pub const ProtocolDevice = struct {
    canonical_name: []const u8,
    chip_type: u8,
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
    can_adjust_clock: bool,
    chip_id: u32,
    chip_id_bytes_count: u8,
    blank_value: u16,
    compare_mask: u16,
    config_ref: []const u8,
    config_fuse_count: usize,
    config_lock_count: usize,
    config_fuse_details: []const u8,
    config_lock_details: []const u8,

    pub fn deinit(self: ProtocolDevice, allocator: std.mem.Allocator) void {
        allocator.free(self.canonical_name);
        allocator.free(self.config_ref);
        allocator.free(self.config_fuse_details);
        allocator.free(self.config_lock_details);
    }
};

pub const PinMap = struct {
    gnd_pins: []u8,
    masks: []u8,

    pub fn deinit(self: PinMap, allocator: std.mem.Allocator) void {
        allocator.free(self.gnd_pins);
        allocator.free(self.masks);
    }
};

fn columnText(stmt: *c.sqlite3_stmt, column: c_int) []const u8 {
    const ptr = c.sqlite3_column_text(stmt, column) orelse return "";
    const len: usize = @intCast(c.sqlite3_column_bytes(stmt, column));
    return ptr[0..len];
}

fn parsePinList(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0) return try allocator.alloc(u8, 0);

    var count: usize = 1;
    for (trimmed) |byte| {
        if (byte == ',') count += 1;
    }
    const pins = try allocator.alloc(u8, count);
    errdefer allocator.free(pins);

    var index: usize = 0;
    var parts = std.mem.splitScalar(u8, trimmed, ',');
    while (parts.next()) |part| {
        const value = std.mem.trim(u8, part, " \t\r\n");
        pins[index] = @intCast(try std.fmt.parseInt(u8, value, 10));
        index += 1;
    }
    return pins;
}

pub const ConfigItemKind = enum {
    fuse,
    lock,
};

pub const ConfigItems = struct {
    items: []const fuses.ConfigItem,

    pub fn deinit(self: ConfigItems, allocator: std.mem.Allocator) void {
        for (self.items) |item| allocator.free(item.name);
        allocator.free(self.items);
    }
};

pub const GalConfig = struct {
    fuses_size: u8,
    row_width: u8,
    ues_address: u16,
    ues_size: u8,
    powerdown_row: u8,
    acw_address: u8,
    acw_bits: []const u16,

    pub fn deinit(self: GalConfig, allocator: std.mem.Allocator) void {
        allocator.free(self.acw_bits);
    }
};

pub const LogicVector = struct {
    id: []const u8,
    states: []const u8,

    pub fn deinit(self: LogicVector, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.states);
    }
};

pub const LogicDevice = struct {
    canonical_name: []const u8,
    pin_count: u16,
    vcc_index: u8,
    vectors: []const LogicVector,

    pub fn deinit(self: LogicDevice, allocator: std.mem.Allocator) void {
        allocator.free(self.canonical_name);
        for (self.vectors) |vector| vector.deinit(allocator);
        allocator.free(self.vectors);
    }
};

const Statement = struct {
    handle: *c.sqlite3_stmt,

    fn prepare(db: Database, sql: []const u8) !Statement {
        var handle: ?*c.sqlite3_stmt = null;
        const z_sql = try std.heap.c_allocator.dupeZ(u8, sql);
        defer std.heap.c_allocator.free(z_sql);
        if (c.sqlite3_prepare_v2(db.handle, z_sql.ptr, -1, &handle, null) != c.SQLITE_OK) return Error.Sqlite;
        return .{ .handle = handle.? };
    }

    fn finalize(self: *Statement) void {
        _ = c.sqlite3_finalize(self.handle);
        self.* = undefined;
    }

    fn reset(self: Statement) !void {
        if (c.sqlite3_reset(self.handle) != c.SQLITE_OK) return Error.Sqlite;
        if (c.sqlite3_clear_bindings(self.handle) != c.SQLITE_OK) return Error.Sqlite;
    }

    fn bindInt(self: Statement, index: c_int, value: anytype) !void {
        if (c.sqlite3_bind_int64(self.handle, index, @as(i64, @intCast(value))) != c.SQLITE_OK) return Error.Sqlite;
    }

    fn bindText(self: Statement, index: c_int, value: []const u8) !void {
        if (c.sqlite3_bind_text(self.handle, index, value.ptr, @intCast(value.len), null) != c.SQLITE_OK) return Error.Sqlite;
    }

    fn bindNull(self: Statement, index: c_int) !void {
        if (c.sqlite3_bind_null(self.handle, index) != c.SQLITE_OK) return Error.Sqlite;
    }

    fn step(self: Statement) !bool {
        return switch (c.sqlite3_step(self.handle)) {
            c.SQLITE_ROW => true,
            c.SQLITE_DONE => false,
            else => Error.Sqlite,
        };
    }

    fn done(self: Statement) !void {
        if (try self.step()) return Error.Sqlite;
    }

    fn text(self: Statement, column: c_int, allocator: std.mem.Allocator) ![]const u8 {
        const ptr = c.sqlite3_column_text(self.handle, column) orelse return "";
        const len: usize = @intCast(c.sqlite3_column_bytes(self.handle, column));
        return try allocator.dupe(u8, ptr[0..len]);
    }
};

const ManufacturerCache = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayListUnmanaged(Entry) = .empty,

    const Entry = struct {
        database_id: i64,
        name: []const u8,
        id: i64,
    };

    fn init(allocator: std.mem.Allocator) ManufacturerCache {
        return .{ .allocator = allocator };
    }

    fn deinit(self: *ManufacturerCache) void {
        for (self.entries.items) |entry| self.allocator.free(entry.name);
        self.entries.deinit(self.allocator);
    }

    fn getOrPut(self: *ManufacturerCache, db: Database, database_id: i64, name: []const u8, is_custom: bool) !i64 {
        for (self.entries.items) |entry| {
            if (entry.database_id == database_id and std.mem.eql(u8, entry.name, name)) return entry.id;
        }
        const id = try db.insertManufacturer(database_id, name, is_custom, self.entries.items.len);
        try self.entries.append(self.allocator, .{ .database_id = database_id, .name = try self.allocator.dupe(u8, name), .id = id });
        return id;
    }
};

const DatabaseCache = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayListUnmanaged(Entry) = .empty,

    const Entry = struct {
        xml_type: []const u8,
        id: i64,
    };

    fn init(allocator: std.mem.Allocator) DatabaseCache {
        return .{ .allocator = allocator };
    }

    fn deinit(self: *DatabaseCache) void {
        for (self.entries.items) |entry| self.allocator.free(entry.xml_type);
        self.entries.deinit(self.allocator);
    }

    fn getOrPut(self: *DatabaseCache, db: Database, source_id: i64, xml_type: []const u8) !i64 {
        for (self.entries.items) |entry| {
            if (std.mem.eql(u8, entry.xml_type, xml_type)) return entry.id;
        }
        const id = try db.insertDatabase(source_id, xml_type, programmerFamily(xml_type), self.entries.items.len);
        try self.entries.append(self.allocator, .{ .xml_type = try self.allocator.dupe(u8, xml_type), .id = id });
        return id;
    }
};

fn programmerFamily(xml_type: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, xml_type, "INFOIC")) return "tl866a";
    if (std.mem.eql(u8, xml_type, "INFOIC2PLUS")) return "tl866ii";
    if (std.mem.eql(u8, xml_type, "INFOICT76")) return "t76";
    if (std.mem.eql(u8, xml_type, "LOGIC")) return "logic";
    return null;
}

fn logicVoltageIndex(voltage: []const u8) u8 {
    if (std.ascii.eqlIgnoreCase(voltage, "5V") or std.ascii.eqlIgnoreCase(voltage, "5")) return 0;
    if (std.ascii.eqlIgnoreCase(voltage, "3.3V") or std.ascii.eqlIgnoreCase(voltage, "3.3")) return 1;
    if (std.ascii.eqlIgnoreCase(voltage, "2.5V") or std.ascii.eqlIgnoreCase(voltage, "2.5")) return 2;
    if (std.ascii.eqlIgnoreCase(voltage, "1.8V") or std.ascii.eqlIgnoreCase(voltage, "1.8")) return 3;
    return 0;
}

fn logicVoltageRaw(voltage: []const u8) u32 {
    return @as(u32, logicVoltageIndex(voltage)) << 8;
}

fn logicVoltageLabel(index: u8) []const u8 {
    return switch (index) {
        1 => "3.3",
        2 => "2.5",
        3 => "1.8",
        else => "5",
    };
}

fn packagePrefix(plcc: bool) []const u8 {
    return if (plcc) "PLCC" else "DIP";
}

const Parameter = struct {
    name: []const u8,
    value: u8,
};

const VoltageKind = enum { vcc, vpp };

const tl866a_vpp_voltages = [_]Parameter{
    .{ .name = "10", .value = 0x40 }, .{ .name = "12.5", .value = 0x00 }, .{ .name = "13.5", .value = 0x30 },
    .{ .name = "14", .value = 0x50 }, .{ .name = "16", .value = 0x10 },   .{ .name = "17", .value = 0x70 },
    .{ .name = "18", .value = 0x60 }, .{ .name = "21", .value = 0x20 },
};

const tl866a_vcc_voltages = [_]Parameter{
    .{ .name = "3.3", .value = 0x02 }, .{ .name = "4", .value = 0x01 },   .{ .name = "4.5", .value = 0x05 },
    .{ .name = "5", .value = 0x00 },   .{ .name = "5.5", .value = 0x04 }, .{ .name = "6.5", .value = 0x03 },
};

const tl866ii_vpp_voltages = [_]Parameter{
    .{ .name = "9", .value = 0x10 },    .{ .name = "9.5", .value = 0x20 },  .{ .name = "10", .value = 0x30 },
    .{ .name = "11", .value = 0x40 },   .{ .name = "11.5", .value = 0x50 }, .{ .name = "12", .value = 0x00 },
    .{ .name = "12.5", .value = 0x60 }, .{ .name = "13", .value = 0x70 },   .{ .name = "13.5", .value = 0x80 },
    .{ .name = "14", .value = 0x90 },   .{ .name = "14.5", .value = 0xa0 }, .{ .name = "15.5", .value = 0xb0 },
    .{ .name = "16", .value = 0xc0 },   .{ .name = "16.5", .value = 0xd0 }, .{ .name = "17", .value = 0xe0 },
    .{ .name = "18", .value = 0xf0 },
};

const tl866ii_vcc_voltages = [_]Parameter{
    .{ .name = "3.3", .value = 0x01 }, .{ .name = "4", .value = 0x02 },   .{ .name = "4.5", .value = 0x03 },
    .{ .name = "5", .value = 0x00 },   .{ .name = "5.5", .value = 0x04 }, .{ .name = "6.5", .value = 0x05 },
};

const xg_vpp_voltages = [_]Parameter{
    .{ .name = "9", .value = 0x10 },    .{ .name = "9.5", .value = 0x20 },  .{ .name = "10", .value = 0x30 },
    .{ .name = "11", .value = 0x40 },   .{ .name = "11.5", .value = 0x50 }, .{ .name = "12", .value = 0x00 },
    .{ .name = "12.5", .value = 0x60 }, .{ .name = "13", .value = 0x70 },   .{ .name = "13.5", .value = 0x80 },
    .{ .name = "14", .value = 0x90 },   .{ .name = "14.5", .value = 0xa0 }, .{ .name = "15.5", .value = 0xb0 },
    .{ .name = "16", .value = 0xc0 },   .{ .name = "16.5", .value = 0xd0 }, .{ .name = "17", .value = 0xe0 },
    .{ .name = "18", .value = 0xf0 },   .{ .name = "21", .value = 0xf2 },   .{ .name = "25", .value = 0xf1 },
};

const xg_vcc_voltages = [_]Parameter{
    .{ .name = "1.2", .value = 0x09 },  .{ .name = "1.8", .value = 0x06 },  .{ .name = "2.5", .value = 0x07 },
    .{ .name = "3", .value = 0x08 },    .{ .name = "3.3", .value = 0x01 },  .{ .name = "4", .value = 0x02 },
    .{ .name = "4.5", .value = 0x03 },  .{ .name = "4.75", .value = 0x0a }, .{ .name = "5", .value = 0x00 },
    .{ .name = "5.25", .value = 0x0b }, .{ .name = "5.5", .value = 0x04 },  .{ .name = "5.75", .value = 0x0c },
    .{ .name = "6", .value = 0x0d },    .{ .name = "6.25", .value = 0x0e }, .{ .name = "6.5", .value = 0x05 },
};

fn voltageTable(programmer: []const u8, kind: VoltageKind) []const Parameter {
    if (std.mem.eql(u8, programmer, "tl866a")) return if (kind == .vpp) &tl866a_vpp_voltages else &tl866a_vcc_voltages;
    if (std.mem.eql(u8, programmer, "t48") or std.mem.eql(u8, programmer, "t56") or std.mem.eql(u8, programmer, "t76")) return if (kind == .vpp) &xg_vpp_voltages else &xg_vcc_voltages;
    return if (kind == .vpp) &tl866ii_vpp_voltages else &tl866ii_vcc_voltages;
}

fn parameterLabel(table: []const Parameter, value: u8) []const u8 {
    for (table) |parameter| {
        if (parameter.value == value) return parameter.name;
    }
    return "-";
}

fn printParameterTable(writer: anytype, message: []const u8, table: []const Parameter) !void {
    var wrap = message.len;
    try writer.writeAll(message);
    for (table, 0..) |parameter, index| {
        const has_next = index + 1 < table.len;
        const extra: usize = if (has_next) 2 else 0;
        if (wrap + parameter.name.len + extra > 40) {
            try writer.writeAll("\n");
            wrap = 0;
        }
        try writer.writeAll(parameter.name);
        if (has_next) {
            try writer.writeAll(", ");
            wrap += parameter.name.len + 2;
        } else {
            wrap += parameter.name.len;
        }
    }
    try writer.writeAll("\n");
}

fn programmerLabel(programmer: []const u8) []const u8 {
    if (std.mem.eql(u8, programmer, "tl866a")) return "TL866A/CS";
    if (std.mem.eql(u8, programmer, "tl866ii")) return "TL866II";
    if (std.mem.eql(u8, programmer, "t48")) return "T48";
    if (std.mem.eql(u8, programmer, "t56")) return "T56";
    if (std.mem.eql(u8, programmer, "t76")) return "T76";
    return programmer;
}

fn boolInt(value: bool) i64 {
    return if (value) 1 else 0;
}

fn chipIdByteCount(chip_id: u32) u8 {
    if (chip_id == 0) return 0;
    var count: u8 = 4;
    const masks = [_]u32{ 0xff, 0xff00, 0xff0000, 0xff000000 };
    while (count > 0) {
        count -= 1;
        if (chip_id & masks[count] != 0) break;
    }
    return count + 1;
}

fn asciiLowerInPlace(value: []u8) void {
    for (value) |*byte| byte.* = std.ascii.toLower(byte.*);
}

test "chip ID byte count matches upstream helper" {
    try std.testing.expectEqual(@as(u8, 0), chipIdByteCount(0));
    try std.testing.expectEqual(@as(u8, 1), chipIdByteCount(0x12));
    try std.testing.expectEqual(@as(u8, 2), chipIdByteCount(0x1234));
    try std.testing.expectEqual(@as(u8, 3), chipIdByteCount(0x123456));
    try std.testing.expectEqual(@as(u8, 4), chipIdByteCount(0x12345678));
}
