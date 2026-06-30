// SPDX-License-Identifier: GPL-3.0-or-later

const std = @import("std");
const algorithm_name = @import("core/algorithm_name.zig");
const algorithm_payload = @import("core/algorithm_payload.zig");
const sqlite = @import("db/sqlite.zig");
const bin = @import("formats/bin.zig");
const endian = @import("core/endian.zig");
const fuses = @import("core/fuses.zig");
const gal_core = @import("core/gal.zig");
const ihex = @import("formats/ihex.zig");
const image = @import("formats/image.zig");
const jedec = @import("formats/jedec.zig");
const logic = @import("core/logic.zig");
const srec = @import("formats/srec.zig");
const model = @import("core/model.zig");
const session = @import("programmer/session.zig");
const t48 = @import("programmer/t48.zig");
const t56 = @import("programmer/t56.zig");
const t76 = @import("programmer/t76.zig");
const tl866ii = @import("programmer/tl866ii.zig");
const usb = @import("programmer/usb.zig");

pub const version = "0.1.0-dev";
const legacy_limit = 1_000_000;

const GlobalOptions = struct {
    programmer: model.Programmer = .auto,
    json: bool = false,
    verbose: bool = false,
    quiet: bool = false,
    db_path: ?[]const u8 = null,
};

const Parsed = union(enum) {
    help,
    version,
    programmer_list: ProgrammerList,
    programmer_detect: ProgrammerDetect,
    programmer_info: GlobalOptions,
    db_import: DbImport,
    db_stats: GlobalOptions,
    db_query: DbQuery,
    device_list: DeviceList,
    device_search: DeviceSearch,
    device_info: DeviceInfo,
    chip_read: ChipRead,
    chip_verify: ChipVerify,
    chip_erase: ChipErase,
    chip_write: ChipWrite,
    chip_read_id: ChipReadId,
    chip_autodetect: ChipAutodetect,
    chip_blank: ChipBlank,
    chip_pin_check: ChipPinCheck,
    chip_protect: ChipProtect,
    logic_test: LogicTest,
    unsupported: []const u8,
};

const ProgrammerList = struct {
    opts: GlobalOptions = .{},
    legacy: bool = false,
};

const ProgrammerDetect = struct {
    opts: GlobalOptions = .{},
    legacy: bool = false,
};

const DbImport = struct {
    infoic: []const u8,
    logicic: ?[]const u8 = null,
    algorithms: ?[]const u8 = null,
    out: []const u8,
};

const DbQuery = struct {
    opts: GlobalOptions = .{},
    sql: []const u8,
};

const DeviceList = struct {
    opts: GlobalOptions = .{},
    limit: usize = 100,
    legacy: bool = false,
};

const DeviceSearch = struct {
    opts: GlobalOptions = .{},
    term: []const u8,
    limit: usize = 100,
    legacy: bool = false,
};

const DeviceInfo = struct {
    opts: GlobalOptions = .{},
    name: []const u8,
    legacy: bool = false,
};

const ChipRead = struct {
    opts: GlobalOptions = .{},
    device: []const u8,
    out: []const u8,
    format: FileFormat = .bin,
    memory: model.MemoryKind = .code,
    op_opts: OperationOptions = .{},
    execute: bool = false,
};

const ChipVerify = struct {
    opts: GlobalOptions = .{},
    device: []const u8,
    input: []const u8,
    format: FileFormat = .bin,
    memory: model.MemoryKind = .code,
    op_opts: OperationOptions = .{},
    execute: bool = false,
};

const ChipErase = struct {
    opts: GlobalOptions = .{},
    device: []const u8,
    confirm_destructive: ?[]const u8 = null,
    op_opts: OperationOptions = .{},
    execute: bool = false,
};

const ChipWrite = struct {
    opts: GlobalOptions = .{},
    device: []const u8,
    input: []const u8,
    format: FileFormat = .bin,
    memory: model.MemoryKind = .code,
    unprotect_before: bool = false,
    protect_after: bool = false,
    confirm_destructive: ?[]const u8 = null,
    op_opts: OperationOptions = .{},
    execute: bool = false,
};

const ChipReadId = struct {
    opts: GlobalOptions = .{},
    device: []const u8,
    op_opts: OperationOptions = .{},
    execute: bool = false,
};

const ChipAutodetect = struct {
    opts: GlobalOptions = .{},
    package_pins: u8,
    execute: bool = false,
    legacy: bool = false,
};

const ChipBlank = struct {
    opts: GlobalOptions = .{},
    device: []const u8,
    memory: model.MemoryKind = .code,
    op_opts: OperationOptions = .{},
    execute: bool = false,
};

const ChipPinCheck = struct {
    opts: GlobalOptions = .{},
    device: []const u8,
    execute: bool = false,
    legacy: bool = false,
};

const ChipProtect = struct {
    opts: GlobalOptions = .{},
    device: []const u8,
    enable: bool,
    confirm_destructive: ?[]const u8 = null,
    op_opts: OperationOptions = .{},
    execute: bool = false,
};

const LogicTest = struct {
    opts: GlobalOptions = .{},
    device: []const u8,
    out: ?[]const u8 = null,
    execute: bool = false,
    legacy: bool = false,
};

const FileFormat = enum {
    bin,
    ihex,
    srec,
    jedec,
    config,
};

const OperationOptions = struct {
    no_erase: bool = false,
    no_verify: bool = false,
    idcheck_skip: bool = false,
    idcheck_continue: bool = false,
    pincheck: bool = false,
    size_error: bool = false,
    size_nowarn: bool = false,
    force_erase: bool = false,
    pulse: ?[]const u8 = null,
    vpp: ?[]const u8 = null,
    vdd: ?[]const u8 = null,
    vcc: ?[]const u8 = null,
    spi_clock: ?[]const u8 = null,
    address: ?[]const u8 = null,

    fn hasAdvanced(self: OperationOptions) bool {
        return self.pincheck or
            self.force_erase or self.pulse != null or self.vpp != null or
            self.vdd != null or self.vcc != null or self.spi_clock != null or self.address != null;
    }

    fn hasAny(self: OperationOptions) bool {
        return self.hasAdvanced() or self.no_erase or self.no_verify or self.idcheck_skip or self.idcheck_continue or self.size_error or self.size_nowarn;
    }
};

const SizeCheck = enum {
    ok,
    mismatch_error,
    mismatch_warn,
    mismatch_silent,
};

pub fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    args: []const []const u8,
    stdout: anytype,
    stderr: anytype,
) !u8 {
    const parsed = parse(args) catch |err| switch (err) {
        error.NoLegacyAction => {
            try stderr.print("{s}\n", .{parseErrorMessage(err)});
            try writeLegacyShortHelp(stderr);
            return 1;
        },
        error.MissingLegacySearchArgument => {
            try stderr.print("{s}\n", .{parseErrorMessage(err)});
            try writeLegacyShortHelp(stderr);
            return 1;
        },
        error.UnknownOption, error.MissingOptionValue, error.UnknownProgrammer, error.UnknownCommand, error.NoCommand, error.MissingRequiredOption, error.InvalidLimit, error.InvalidOperationValue => {
            try stderr.print("{s}\n\n", .{parseErrorMessage(err)});
            try writeShortUsage(stderr);
            return 1;
        },
    };

    switch (parsed) {
        .help => {
            try writeHelp(stdout);
            return 0;
        },
        .version => {
            try stdout.print("minipro-zig {s}\n", .{version});
            return 0;
        },
        .programmer_list => |command| {
            if (command.opts.json) {
                try writeProgrammerListJson(stdout);
            } else if (command.legacy) {
                try writeProgrammerList(stderr);
            } else {
                try writeProgrammerList(stdout);
            }
            return 0;
        },
        .programmer_detect => |command| {
            const opts = command.opts;
            const usb_transport = usb.UsbTransport.open(allocator) catch |err| {
                if (opts.json) {
                    try stdout.print("{{\"detected\":false,\"error\":\"{s}\"}}\n", .{@errorName(err)});
                } else {
                    try stderr.print("No programmer detected: {s}\n", .{@errorName(err)});
                }
                return 1;
            };
            const programmer_session = session.Session.open(usb_transport.transport()) catch |err| {
                usb_transport.transport().close();
                if (opts.json) {
                    try stdout.print("{{\"detected\":false,\"error\":\"{s}\"}}\n", .{@errorName(err)});
                } else {
                    try stderr.print("Unable to identify programmer: {s}\n", .{@errorName(err)});
                }
                return 1;
            };
            defer programmer_session.close();
            if (opts.json) {
                try stdout.print("{{\"detected\":true,\"programmer\":\"{s}\",\"model\":\"{s}\",\"firmware\":{d}}}\n", .{ programmer_session.info.programmer.name(), programmer_session.info.model_name, programmer_session.info.firmware });
            } else if (command.legacy) {
                try stderr.print("{s}: {s}\n", .{ programmer_session.info.programmer.name(), programmer_session.info.model_name });
            } else {
                try stdout.print("Detected {s}\n", .{programmer_session.info.model_name});
            }
            return 0;
        },
        .programmer_info => |opts| {
            const usb_transport = usb.UsbTransport.open(allocator) catch |err| {
                try stderr.print("Unable to open programmer: {s}\n", .{@errorName(err)});
                return 1;
            };
            const programmer_session = session.Session.open(usb_transport.transport()) catch |err| {
                usb_transport.transport().close();
                try stderr.print("Unable to read programmer info: {s}\n", .{@errorName(err)});
                return 1;
            };
            defer programmer_session.close();
            if (opts.json) {
                try writeProgrammerInfoJson(stdout, programmer_session.info);
            } else {
                try writeProgrammerInfo(stdout, programmer_session.info);
            }
            return 0;
        },
        .db_import => |command| {
            const xml = try readFile(allocator, io, command.infoic);
            defer allocator.free(xml);

            std.Io.Dir.cwd().deleteFile(io, command.out) catch {};
            var db = try sqlite.Database.open(command.out);
            defer db.close();
            try db.applySchema();
            const count = try db.importInfoic(allocator, xml, command.infoic);
            var logic_count: usize = 0;
            if (command.logicic) |logicic| {
                const logic_xml = try readFile(allocator, io, logicic);
                defer allocator.free(logic_xml);
                logic_count = try db.importLogicic(allocator, logic_xml, logicic);
            }
            var algorithm_count: usize = 0;
            if (command.algorithms) |algorithms| {
                const algorithm_xml = try readFile(allocator, io, algorithms);
                defer allocator.free(algorithm_xml);
                algorithm_count = try db.importAlgorithms(algorithm_xml, algorithms);
            }
            if (command.logicic != null or command.algorithms != null) {
                try stdout.print("Imported {d} devices, {d} logic devices, and {d} algorithms into {s}\n", .{ count, logic_count, algorithm_count, command.out });
            } else {
                try stdout.print("Imported {d} devices into {s}\n", .{ count, command.out });
            }
            return 0;
        },
        .db_stats => |opts| {
            var db = try sqlite.Database.open(databasePath(opts));
            defer db.close();
            const stats = try db.stats();
            if (opts.json) {
                try stdout.print("{{\"devices\":{d},\"aliases\":{d},\"manufacturers\":{d}}}\n", .{ stats.devices, stats.aliases, stats.manufacturers });
            } else {
                try stdout.print("Devices: {d}\nAliases: {d}\nManufacturers: {d}\n", .{ stats.devices, stats.aliases, stats.manufacturers });
            }
            return 0;
        },
        .db_query => |command| {
            var db = try sqlite.Database.open(databasePath(command.opts));
            defer db.close();
            try db.query(allocator, command.sql, stdout);
            return 0;
        },
        .device_list => |command| {
            var db = try sqlite.Database.open(databasePath(command.opts));
            defer db.close();
            try db.listDevices(allocator, programmerDatabaseFamily(command.opts.programmer), command.limit, stdout);
            return 0;
        },
        .device_search => |command| {
            var db = try sqlite.Database.open(databasePath(command.opts));
            defer db.close();
            try db.searchDevices(allocator, programmerDatabaseFamily(command.opts.programmer), command.term, command.limit, stdout);
            return 0;
        },
        .device_info => |command| {
            var db = try sqlite.Database.open(databasePath(command.opts));
            defer db.close();
            const writer = if (command.legacy) stderr else stdout;
            if (!try db.deviceInfo(allocator, command.name, programmerDatabaseFamily(command.opts.programmer), programmerFilter(command.opts.programmer), command.legacy, writer)) {
                try stderr.print("Device {s} not found!\n", .{command.name});
                return 1;
            }
            return 0;
        },
        .chip_read => |command| {
            var db = try sqlite.Database.open(databasePath(command.opts));
            defer db.close();
            const family = programmerDatabaseFamily(command.opts.programmer);
            const protocol_device = try db.protocolDevice(allocator, command.device, family) orelse {
                try stderr.print("Device {s} not found!\n", .{command.device});
                return 1;
            };
            defer protocol_device.deinit(allocator);

            if (command.format == .config) {
                const fuse_items = try db.configItems(allocator, protocol_device.config_ref, .fuse);
                defer fuse_items.deinit(allocator);
                const lock_items = try db.configItems(allocator, protocol_device.config_ref, .lock);
                defer lock_items.deinit(allocator);
                if (!command.execute) {
                    try writeChipFuseReadPlan(stdout, command, protocol_device, fuse_items, lock_items);
                    return 0;
                }
                if (try rejectAdvancedOperationOptions(stderr, command.op_opts)) return 2;
                const bytes = executeChipFuseRead(allocator, command.opts, command.op_opts, protocol_device, fuse_items, lock_items) catch |err| {
                    try stderr.print("chip fuse read failed: {s}\n", .{@errorName(err)});
                    return 1;
                };
                defer allocator.free(bytes);
                try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = command.out, .data = bytes });
                try stdout.print("Read fuses from {s} into {s}\n", .{ protocol_device.canonical_name, command.out });
                return 0;
            }
            if (!command.execute) {
                try writeChipReadPlan(stdout, command, protocol_device);
                return 0;
            }
            if (try rejectAdvancedOperationOptions(stderr, command.op_opts)) return 2;
            if (command.format == .jedec) {
                try stderr.writeAll("chip read --format jedec requires fuse-specific read support that is not ported yet.\n");
                return 2;
            }
            const bytes = executeChipRead(allocator, command, protocol_device) catch |err| {
                try stderr.print("chip read failed: {s}\n", .{@errorName(err)});
                return 1;
            };
            defer allocator.free(bytes);
            try writeChipReadOutput(allocator, io, command, bytes);
            try stdout.print("Read {d} bytes from {s} into {s}\n", .{ bytes.len, protocol_device.canonical_name, command.out });
            return 0;
        },
        .chip_verify => |command| {
            var db = try sqlite.Database.open(databasePath(command.opts));
            defer db.close();
            const family = programmerDatabaseFamily(command.opts.programmer);
            const protocol_device = try db.protocolDevice(allocator, command.device, family) orelse {
                try stderr.print("Device {s} not found!\n", .{command.device});
                return 1;
            };
            defer protocol_device.deinit(allocator);

            if (command.format == .config) {
                var plan = try loadFusePlan(allocator, io, db, protocol_device, command.input);
                defer plan.deinit();
                try writeChipFuseVerifyPlan(stdout, command, protocol_device, plan);
                if (command.execute) {
                    if (try rejectAdvancedOperationOptions(stderr, command.op_opts)) return 2;
                    if (try executeChipFuseVerify(allocator, command.opts, command.op_opts, protocol_device, plan)) |mismatch| {
                        try stderr.print("Fuse verify failed in {s} section at item {d}\n", .{ mismatch.section, mismatch.index });
                        return 1;
                    }
                    try stdout.print("Verified fuses for {s}\n", .{protocol_device.canonical_name});
                }
                return 0;
            }
            if (!command.execute) {
                var input = try loadVerifyImage(allocator, io, command);
                defer input.deinit();
                if (try reportInputSizeMismatch(stderr, command.op_opts, input.data.len, chipReadSize(command.memory, protocol_device))) return 1;
                try writeChipVerifyPlan(stdout, command, protocol_device, input);
                if (command.format == .jedec and protocol_device.chip_type == @intFromEnum(model.ChipType.pld)) {
                    if (try db.galConfig(allocator, protocol_device.config_ref)) |gal| {
                        defer gal.deinit(allocator);
                        try writeChipJedecGalPlan(stdout, gal);
                    }
                }
                return 0;
            }
            if (command.format == .jedec) {
                if (try rejectAdvancedOperationOptions(stderr, command.op_opts)) return 2;
                if (protocol_device.chip_type != @intFromEnum(model.ChipType.pld)) {
                    try stderr.writeAll("chip verify --format jedec requires a PLD/GAL device.\n");
                    return 2;
                }
                var input = try loadVerifyImage(allocator, io, command);
                defer input.deinit();
                if (try reportInputSizeMismatch(stderr, command.op_opts, input.data.len, chipReadSize(command.memory, protocol_device))) return 1;
                const gal = try db.galConfig(allocator, protocol_device.config_ref) orelse {
                    try stderr.print("Device {s} has no GAL JEDEC configuration.\n", .{protocol_device.canonical_name});
                    return 2;
                };
                defer gal.deinit(allocator);
                if (try executeChipJedecVerify(allocator, command.opts, command.op_opts, protocol_device, gal, input.data)) |mismatch| {
                    try stderr.print("JEDEC verify failed at fuse {d}\n", .{mismatch});
                    return 1;
                }
                try stdout.print("Verified JEDEC fuses for {s}\n", .{protocol_device.canonical_name});
                return 0;
            }
            var input = try loadVerifyImage(allocator, io, command);
            defer input.deinit();
            if (try reportInputSizeMismatch(stderr, command.op_opts, input.data.len, chipReadSize(command.memory, protocol_device))) return 1;
            if (try rejectAdvancedOperationOptions(stderr, command.op_opts)) return 2;
            if (try executeChipVerify(allocator, command, protocol_device, input)) |mismatch| {
                try stderr.print("Verify failed at byte 0x{x}\n", .{mismatch});
                return 1;
            }
            try stdout.print("Verified {d} bytes for {s}\n", .{ input.data.len, protocol_device.canonical_name });
            return 0;
        },
        .chip_erase => |command| {
            if (try rejectInvalidIdCheckSkip(stderr, command.op_opts)) return 1;
            var db = try sqlite.Database.open(databasePath(command.opts));
            defer db.close();
            const protocol_device = try db.protocolDevice(allocator, command.device, programmerDatabaseFamily(command.opts.programmer)) orelse {
                try stderr.print("Device {s} not found!\n", .{command.device});
                return 1;
            };
            defer protocol_device.deinit(allocator);
            try writeChipErasePlan(stdout, command, protocol_device);
            if (command.execute) {
                if (try rejectAdvancedOperationOptions(stderr, command.op_opts)) return 2;
                if (!destructiveConfirmed(command.confirm_destructive, protocol_device.canonical_name)) {
                    try stderr.print("Refusing destructive erase without --confirm-destructive {s}\n", .{protocol_device.canonical_name});
                    return 2;
                }
                executeChipErase(allocator, command.opts, command.op_opts, protocol_device) catch |err| {
                    try stderr.print("chip erase failed: {s}\n", .{@errorName(err)});
                    return 1;
                };
                try stdout.print("Erased {s}\n", .{protocol_device.canonical_name});
            }
            return 0;
        },
        .chip_write => |command| {
            if (try rejectInvalidIdCheckSkip(stderr, command.op_opts)) return 1;
            var db = try sqlite.Database.open(databasePath(command.opts));
            defer db.close();
            const protocol_device = try db.protocolDevice(allocator, command.device, programmerDatabaseFamily(command.opts.programmer)) orelse {
                try stderr.print("Device {s} not found!\n", .{command.device});
                return 1;
            };
            defer protocol_device.deinit(allocator);
            if (command.format == .config) {
                var plan = try loadFusePlan(allocator, io, db, protocol_device, command.input);
                defer plan.deinit();
                try writeChipFuseWritePlan(stdout, command, protocol_device, plan);
                if (command.execute) {
                    if (try rejectAdvancedOperationOptions(stderr, command.op_opts)) return 2;
                    if (!destructiveConfirmed(command.confirm_destructive, protocol_device.canonical_name)) {
                        try stderr.print("Refusing destructive fuse write without --confirm-destructive {s}\n", .{protocol_device.canonical_name});
                        return 2;
                    }
                    executeChipFuseWrite(allocator, command.opts, command.op_opts, protocol_device, plan) catch |err| {
                        try stderr.print("chip fuse write failed: {s}\n", .{@errorName(err)});
                        return 1;
                    };
                    try stdout.print("Wrote fuses to {s}\n", .{protocol_device.canonical_name});
                }
                return 0;
            }
            var input = try loadWriteImage(allocator, io, command);
            defer input.deinit();
            if (try reportInputSizeMismatch(stderr, command.op_opts, input.data.len, chipReadSize(command.memory, protocol_device))) return 1;
            try writeChipWritePlan(stdout, command, protocol_device, input);
            if (command.format == .jedec and protocol_device.chip_type == @intFromEnum(model.ChipType.pld)) {
                if (try db.galConfig(allocator, protocol_device.config_ref)) |gal| {
                    defer gal.deinit(allocator);
                    try writeChipJedecGalPlan(stdout, gal);
                }
            }
            if (command.execute) {
                if (try rejectAdvancedOperationOptions(stderr, command.op_opts)) return 2;
                if (command.format == .jedec) {
                    if (protocol_device.chip_type != @intFromEnum(model.ChipType.pld)) {
                        try stderr.writeAll("chip write --format jedec requires a PLD/GAL device.\n");
                        return 2;
                    }
                    if (!destructiveConfirmed(command.confirm_destructive, protocol_device.canonical_name)) {
                        try stderr.print("Refusing destructive JEDEC write without --confirm-destructive {s}\n", .{protocol_device.canonical_name});
                        return 2;
                    }
                    const gal = try db.galConfig(allocator, protocol_device.config_ref) orelse {
                        try stderr.print("Device {s} has no GAL JEDEC configuration.\n", .{protocol_device.canonical_name});
                        return 2;
                    };
                    defer gal.deinit(allocator);
                    executeChipJedecWrite(allocator, command.opts, command.op_opts, protocol_device, gal, input.data) catch |err| {
                        try stderr.print("chip JEDEC write failed: {s}\n", .{@errorName(err)});
                        return 1;
                    };
                    try stdout.print("Wrote JEDEC fuses to {s}\n", .{protocol_device.canonical_name});
                    return 0;
                }
                if (!destructiveConfirmed(command.confirm_destructive, protocol_device.canonical_name)) {
                    try stderr.print("Refusing destructive write without --confirm-destructive {s}\n", .{protocol_device.canonical_name});
                    return 2;
                }
                executeChipWrite(allocator, command, protocol_device, input) catch |err| {
                    try stderr.print("chip write failed: {s}\n", .{@errorName(err)});
                    return 1;
                };
                if (!command.op_opts.no_verify) {
                    const verify_command = ChipVerify{
                        .opts = command.opts,
                        .device = command.device,
                        .input = command.input,
                        .format = command.format,
                        .memory = command.memory,
                        .execute = true,
                    };
                    if (try executeChipVerify(allocator, verify_command, protocol_device, input)) |mismatch| {
                        try stderr.print("Verification failed at byte 0x{x}\n", .{mismatch});
                        return 1;
                    }
                    try stderr.writeAll("Verification OK\n");
                }
                try stdout.print("Wrote {d} bytes to {s}\n", .{ input.data.len, protocol_device.canonical_name });
            }
            return 0;
        },
        .chip_read_id => |command| {
            if (try rejectInvalidIdCheckSkip(stderr, command.op_opts)) return 1;
            var db = try sqlite.Database.open(databasePath(command.opts));
            defer db.close();
            const protocol_device = try db.protocolDevice(allocator, command.device, programmerDatabaseFamily(command.opts.programmer)) orelse {
                try stderr.print("Device {s} not found!\n", .{command.device});
                return 1;
            };
            defer protocol_device.deinit(allocator);
            if (!command.execute) {
                try writeChipReadIdPlan(stdout, command, protocol_device);
                return 0;
            }
            if (try rejectAdvancedOperationOptions(stderr, command.op_opts)) return 2;
            const id = executeChipReadId(allocator, command.opts, command.op_opts, protocol_device) catch |err| {
                try stderr.print("chip read-id failed: {s}\n", .{@errorName(err)});
                return 1;
            };
            try stdout.print("Chip ID: 0x{x}\n", .{id.value});
            return 0;
        },
        .chip_autodetect => |command| {
            try writeChipAutodetectPlan(stdout, command);
            if (command.execute) {
                const id = executeChipAutodetect(allocator, command.opts, command.package_pins) catch |err| {
                    try stderr.print("chip autodetect failed: {s}\n", .{@errorName(err)});
                    return 1;
                };
                try stderr.print("Autodetecting device (ID:0x{X:0>4})\n", .{id});
                var db = try sqlite.Database.open(databasePath(command.opts));
                defer db.close();
                const count = try db.listDevicesByChipId(allocator, programmerDatabaseFamily(command.opts.programmer), id, command.package_pins, stdout);
                try stderr.print("{d} device(s) found.\n", .{count});
            }
            return 0;
        },
        .chip_blank => |command| {
            var db = try sqlite.Database.open(databasePath(command.opts));
            defer db.close();
            const protocol_device = try db.protocolDevice(allocator, command.device, programmerDatabaseFamily(command.opts.programmer)) orelse {
                try stderr.print("Device {s} not found!\n", .{command.device});
                return 1;
            };
            defer protocol_device.deinit(allocator);
            if (!command.execute) {
                try writeChipBlankPlan(stdout, command, protocol_device);
                return 0;
            }
            if (try rejectAdvancedOperationOptions(stderr, command.op_opts)) return 2;
            if (try executeChipBlank(allocator, command, protocol_device)) {
                try stdout.print("Blank check OK for {s}\n", .{protocol_device.canonical_name});
                return 0;
            }
            try stderr.print("Blank check failed for {s}\n", .{protocol_device.canonical_name});
            return 1;
        },
        .chip_pin_check => |command| {
            var db = try sqlite.Database.open(databasePath(command.opts));
            defer db.close();
            const protocol_device = try db.protocolDevice(allocator, command.device, programmerDatabaseFamily(command.opts.programmer)) orelse {
                try stderr.print("Device {s} not found!\n", .{command.device});
                return 1;
            };
            defer protocol_device.deinit(allocator);
            const map_index: u32 = protocol_device.pin_map & 0xff;
            const pin_map = if (map_index == 0) null else try db.pinMap(allocator, map_index);
            if (pin_map) |map| {
                defer map.deinit(allocator);
                try writeChipPinCheckPlan(stdout, command, protocol_device, map_index, map);
                if (command.execute) {
                    const bad_pins = executeChipPinCheck(allocator, command.opts, protocol_device, map) catch |err| {
                        try stderr.print("chip pin-check failed: {s}\n", .{@errorName(err)});
                        return 1;
                    };
                    defer allocator.free(bad_pins);
                    for (bad_pins) |pin| try stderr.print("Bad contact on pin:{d}\n", .{pin});
                    if (bad_pins.len != 0) return 1;
                    try stderr.writeAll("Pin test passed.\n");
                }
            } else {
                try stderr.writeAll("Pin test is not available for this chip.\n");
                return 1;
            }
            return 0;
        },
        .chip_protect => |command| {
            var db = try sqlite.Database.open(databasePath(command.opts));
            defer db.close();
            const protocol_device = try db.protocolDevice(allocator, command.device, programmerDatabaseFamily(command.opts.programmer)) orelse {
                try stderr.print("Device {s} not found!\n", .{command.device});
                return 1;
            };
            defer protocol_device.deinit(allocator);
            try writeChipProtectPlan(stdout, command, protocol_device);
            if (command.execute) {
                if (try rejectAdvancedOperationOptions(stderr, command.op_opts)) return 2;
                if (!destructiveConfirmed(command.confirm_destructive, protocol_device.canonical_name)) {
                    try stderr.print("Refusing protection change without --confirm-destructive {s}\n", .{protocol_device.canonical_name});
                    return 2;
                }
                executeChipProtect(allocator, command, protocol_device) catch |err| {
                    try stderr.print("chip protection change failed: {s}\n", .{@errorName(err)});
                    return 1;
                };
                try stdout.print("{s} protection for {s}\n", .{ if (command.enable) "Enabled" else "Disabled", protocol_device.canonical_name });
            }
            return 0;
        },
        .logic_test => |command| {
            var db = try sqlite.Database.open(databasePath(command.opts));
            defer db.close();
            const logic_device = try db.logicDevice(allocator, command.device) orelse {
                try stderr.print("Device {s} not found!\n", .{command.device});
                return 1;
            };
            defer logic_device.deinit(allocator);
            try writeLogicTestPlan(stdout, command, logic_device);
            if (command.execute) {
                const errors = executeLogicTest(allocator, io, command, logic_device, stdout) catch |err| {
                    try stderr.print("logic test failed: {s}\n", .{@errorName(err)});
                    return 1;
                };
                if (errors != 0) {
                    try stderr.print("Logic test failed: {d} errors encountered.\n", .{errors});
                    return 1;
                }
                try stderr.writeAll("Logic test successful.\n");
            }
            return 0;
        },
        .unsupported => |command| {
            try stderr.print("Command '{s}' is not ported yet.\n", .{command});
            return 2;
        },
    }
}

fn parse(args: []const []const u8) !Parsed {
    var opts = GlobalOptions{};
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) return .help;
        if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-V")) return .version;
        if (std.mem.eql(u8, arg, "--json")) {
            opts.json = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--verbose")) {
            opts.verbose = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--quiet")) {
            opts.quiet = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--db")) {
            i += 1;
            if (i >= args.len) return error.MissingOptionValue;
            opts.db_path = args[i];
            continue;
        }
        if (std.mem.eql(u8, arg, "--programmer") or std.mem.eql(u8, arg, "-q")) {
            i += 1;
            if (i >= args.len) return error.MissingOptionValue;
            opts.programmer = model.Programmer.parse(args[i]) orelse return error.UnknownProgrammer;
            continue;
        }
        if (std.mem.eql(u8, arg, "-Q") or std.mem.eql(u8, arg, "--query_supported")) {
            return .{ .programmer_list = .{ .opts = opts, .legacy = true } };
        }
        if (std.mem.eql(u8, arg, "programmer")) {
            i += 1;
            if (i >= args.len) return error.UnknownCommand;
            if (std.mem.eql(u8, args[i], "list")) return .{ .programmer_list = .{ .opts = opts } };
            if (std.mem.eql(u8, args[i], "detect")) return .{ .programmer_detect = .{ .opts = try parseTrailingGlobalOptions(args, &i, opts) } };
            if (std.mem.eql(u8, args[i], "info")) return .{ .programmer_info = try parseTrailingGlobalOptions(args, &i, opts) };
            return .{ .unsupported = "programmer" };
        }
        if (std.mem.eql(u8, arg, "-k") or std.mem.eql(u8, arg, "--presence_check")) {
            return .{ .programmer_detect = .{ .opts = try parseTrailingGlobalOptions(args, &i, opts), .legacy = true } };
        }
        if (std.mem.eql(u8, arg, "-a") or std.mem.eql(u8, arg, "--auto_detect")) {
            i += 1;
            if (i >= args.len) return error.MissingOptionValue;
            const package_pins = try parseAutodetectPackage(args[i]);
            return .{ .chip_autodetect = .{ .opts = try parseTrailingGlobalOptions(args, &i, opts), .package_pins = package_pins, .legacy = true } };
        }
        if (std.mem.eql(u8, arg, "db")) {
            return try parseDb(args, &i, opts);
        }
        if (std.mem.eql(u8, arg, "device")) {
            return try parseDevice(args, &i, opts);
        }
        if (std.mem.eql(u8, arg, "chip")) {
            return try parseChip(args, &i, opts);
        }
        if (std.mem.eql(u8, arg, "logic")) {
            return try parseLogic(args, &i, opts);
        }
        if (std.mem.eql(u8, arg, "-l") or std.mem.eql(u8, arg, "--list")) {
            return .{ .device_list = .{ .opts = try parseTrailingGlobalOptions(args, &i, opts), .limit = legacy_limit, .legacy = true } };
        }
        if (std.mem.eql(u8, arg, "-L") or std.mem.eql(u8, arg, "--search")) {
            i += 1;
            if (i >= args.len) return error.MissingLegacySearchArgument;
            const term = args[i];
            return .{ .device_search = .{ .opts = try parseTrailingGlobalOptions(args, &i, opts), .term = term, .limit = legacy_limit, .legacy = true } };
        }
        if (std.mem.eql(u8, arg, "-d") or
            std.mem.eql(u8, arg, "--get_info"))
        {
            i += 1;
            if (i >= args.len) return error.MissingOptionValue;
            const name = args[i];
            return .{ .device_info = .{ .opts = try parseTrailingGlobalOptions(args, &i, opts), .name = name, .legacy = true } };
        }
        if (std.mem.eql(u8, arg, "-p") or std.mem.eql(u8, arg, "--device")) {
            i += 1;
            if (i >= args.len) return error.MissingOptionValue;
            return try parseLegacyChipOperation(args, &i, opts, args[i]);
        }
        return error.UnknownOption;
    }
    return error.NoCommand;
}

fn parseLegacyChipOperation(args: []const []const u8, index: *usize, opts: GlobalOptions, device: []const u8) !Parsed {
    var parsed_opts = opts;
    var execute = false;
    var memory: model.MemoryKind = .code;
    var format: FileFormat = .bin;
    var path: ?[]const u8 = null;
    var unprotect_before = false;
    var protect_after = false;
    var confirm_destructive: ?[]const u8 = null;
    var logic_out: ?[]const u8 = null;
    var op_opts = OperationOptions{};
    var operation: enum { none, read_id, blank, read, write, verify, erase, protect, unprotect, logic_test } = .none;
    while (index.* + 1 < args.len) {
        index.* += 1;
        const arg = args[index.*];
        if (std.mem.eql(u8, arg, "-D") or std.mem.eql(u8, arg, "--read_id")) {
            operation = .read_id;
        } else if (std.mem.eql(u8, arg, "-b") or std.mem.eql(u8, arg, "--blank_check")) {
            operation = .blank;
        } else if (std.mem.eql(u8, arg, "-r")) {
            operation = .read;
            index.* += 1;
            if (index.* >= args.len) return error.MissingOptionValue;
            path = args[index.*];
        } else if (std.mem.eql(u8, arg, "-w")) {
            operation = .write;
            index.* += 1;
            if (index.* >= args.len) return error.MissingOptionValue;
            path = args[index.*];
        } else if (std.mem.eql(u8, arg, "-m")) {
            operation = .verify;
            index.* += 1;
            if (index.* >= args.len) return error.MissingOptionValue;
            path = args[index.*];
        } else if (std.mem.eql(u8, arg, "-E")) {
            if (operation != .none) op_opts.force_erase = true;
            operation = .erase;
        } else if (std.mem.eql(u8, arg, "-T")) {
            operation = .logic_test;
        } else if (std.mem.eql(u8, arg, "--logicic_out")) {
            index.* += 1;
            if (index.* >= args.len) return error.MissingOptionValue;
            logic_out = args[index.*];
        } else if (std.mem.eql(u8, arg, "-P") or std.mem.eql(u8, arg, "--protect")) {
            protect_after = true;
            if (operation == .none) operation = .protect;
        } else if (std.mem.eql(u8, arg, "-u") or std.mem.eql(u8, arg, "--unprotect")) {
            unprotect_before = true;
            if (operation == .none) operation = .unprotect;
        } else if (std.mem.eql(u8, arg, "--format") or std.mem.eql(u8, arg, "-f")) {
            index.* += 1;
            if (index.* >= args.len) return error.MissingOptionValue;
            format = parseFileFormat(args[index.*]) orelse return error.UnknownOption;
        } else if (std.mem.eql(u8, arg, "--memory")) {
            index.* += 1;
            if (index.* >= args.len) return error.MissingOptionValue;
            memory = parseMemoryKind(args[index.*]) orelse return error.UnknownOption;
        } else if (std.mem.eql(u8, arg, "-c")) {
            index.* += 1;
            if (index.* >= args.len) return error.MissingOptionValue;
            memory = parseMemoryKind(args[index.*]) orelse return error.UnknownOption;
        } else if (try parseOperationOption(args, index, arg, &op_opts)) {
            // Accepted for dry-run compatibility. Execute rejects until protocol wiring is complete.
        } else if (std.mem.eql(u8, arg, "--execute")) {
            execute = true;
        } else if (std.mem.eql(u8, arg, "--dry-run")) {
            execute = false;
        } else if (std.mem.eql(u8, arg, "--confirm-destructive")) {
            index.* += 1;
            if (index.* >= args.len) return error.MissingOptionValue;
            confirm_destructive = args[index.*];
        } else if (std.mem.eql(u8, arg, "--programmer") or std.mem.eql(u8, arg, "-q")) {
            index.* += 1;
            if (index.* >= args.len) return error.MissingOptionValue;
            parsed_opts.programmer = model.Programmer.parse(args[index.*]) orelse return error.UnknownProgrammer;
        } else if (std.mem.eql(u8, arg, "--db")) {
            index.* += 1;
            if (index.* >= args.len) return error.MissingOptionValue;
            parsed_opts.db_path = args[index.*];
        } else {
            return error.UnknownOption;
        }
    }
    return switch (operation) {
        .read_id => .{ .chip_read_id = .{ .opts = parsed_opts, .device = device, .op_opts = op_opts, .execute = execute } },
        .blank => .{ .chip_blank = .{ .opts = parsed_opts, .device = device, .memory = memory, .op_opts = op_opts, .execute = execute } },
        .read => .{ .chip_read = .{ .opts = parsed_opts, .device = device, .out = path orelse return error.MissingRequiredOption, .format = format, .memory = memory, .op_opts = op_opts, .execute = execute } },
        .write => .{ .chip_write = .{ .opts = parsed_opts, .device = device, .input = path orelse return error.MissingRequiredOption, .format = format, .memory = memory, .unprotect_before = unprotect_before, .protect_after = protect_after, .confirm_destructive = confirm_destructive, .op_opts = op_opts, .execute = execute } },
        .verify => .{ .chip_verify = .{ .opts = parsed_opts, .device = device, .input = path orelse return error.MissingRequiredOption, .format = format, .memory = memory, .op_opts = op_opts, .execute = execute } },
        .erase => .{ .chip_erase = .{ .opts = parsed_opts, .device = device, .confirm_destructive = confirm_destructive, .op_opts = op_opts, .execute = execute } },
        .protect => .{ .chip_protect = .{ .opts = parsed_opts, .device = device, .enable = true, .confirm_destructive = confirm_destructive, .op_opts = op_opts, .execute = execute } },
        .unprotect => .{ .chip_protect = .{ .opts = parsed_opts, .device = device, .enable = false, .confirm_destructive = confirm_destructive, .op_opts = op_opts, .execute = execute } },
        .logic_test => .{ .logic_test = .{ .opts = parsed_opts, .device = device, .out = logic_out, .execute = execute, .legacy = true } },
        .none => if (op_opts.pincheck) .{ .chip_pin_check = .{ .opts = parsed_opts, .device = device, .execute = execute, .legacy = true } } else error.NoLegacyAction,
    };
}

fn parseOperationOption(args: []const []const u8, index: *usize, arg: []const u8, options: *OperationOptions) !bool {
    if (std.mem.eql(u8, arg, "-e")) {
        options.no_erase = true;
        return true;
    }
    if (std.mem.eql(u8, arg, "-v")) {
        options.no_verify = true;
        return true;
    }
    if (std.mem.eql(u8, arg, "-x")) {
        options.idcheck_skip = true;
        return true;
    }
    if (std.mem.eql(u8, arg, "-y")) {
        options.idcheck_continue = true;
        return true;
    }
    if (std.mem.eql(u8, arg, "-z")) {
        options.pincheck = true;
        return true;
    }
    if (std.mem.eql(u8, arg, "-s")) {
        options.size_error = true;
        return true;
    }
    if (std.mem.eql(u8, arg, "-S")) {
        options.size_error = true;
        options.size_nowarn = true;
        return true;
    }
    if (std.mem.eql(u8, arg, "--pulse") or std.mem.eql(u8, arg, "--vpp") or std.mem.eql(u8, arg, "--vdd") or
        std.mem.eql(u8, arg, "--vcc") or std.mem.eql(u8, arg, "--spi_clock") or std.mem.eql(u8, arg, "--address"))
    {
        index.* += 1;
        if (index.* >= args.len) return error.MissingOptionValue;
        const value = args[index.*];
        if (std.mem.eql(u8, arg, "--pulse")) {
            _ = try parseBoundedUnsigned(value, 0xffff);
            options.pulse = value;
        }
        if (std.mem.eql(u8, arg, "--vpp")) options.vpp = value;
        if (std.mem.eql(u8, arg, "--vdd")) options.vdd = value;
        if (std.mem.eql(u8, arg, "--vcc")) options.vcc = value;
        if (std.mem.eql(u8, arg, "--spi_clock")) options.spi_clock = value;
        if (std.mem.eql(u8, arg, "--address")) {
            _ = try parseBoundedUnsigned(value, 0xff);
            options.address = value;
        }
        return true;
    }
    if (std.mem.eql(u8, arg, "-o")) {
        index.* += 1;
        if (index.* >= args.len) return error.MissingOptionValue;
        try parseLegacyOptionAssignment(args[index.*], options);
        return true;
    }
    return false;
}

fn parseLegacyOptionAssignment(value: []const u8, options: *OperationOptions) !void {
    const eq = std.mem.indexOfScalar(u8, value, '=') orelse return error.UnknownOption;
    const name = value[0..eq];
    const option_value = value[eq + 1 ..];
    if (option_value.len == 0) return error.MissingOptionValue;
    if (std.ascii.eqlIgnoreCase(name, "pulse")) {
        _ = try parseBoundedUnsigned(option_value, 0xffff);
        options.pulse = option_value;
    } else if (std.ascii.eqlIgnoreCase(name, "vpp")) {
        options.vpp = option_value;
    } else if (std.ascii.eqlIgnoreCase(name, "vdd")) {
        options.vdd = option_value;
    } else if (std.ascii.eqlIgnoreCase(name, "vcc")) {
        options.vcc = option_value;
    } else if (std.ascii.eqlIgnoreCase(name, "spi_clock")) {
        options.spi_clock = option_value;
    } else if (std.ascii.eqlIgnoreCase(name, "address")) {
        _ = try parseBoundedUnsigned(option_value, 0xff);
        options.address = option_value;
    } else {
        return error.UnknownOption;
    }
}

fn parseBoundedUnsigned(value: []const u8, max: u32) !u32 {
    const parsed = std.fmt.parseInt(u32, value, 0) catch return error.InvalidOperationValue;
    if (parsed > max) return error.InvalidOperationValue;
    return parsed;
}

fn parseLogic(args: []const []const u8, index: *usize, opts: GlobalOptions) !Parsed {
    index.* += 1;
    if (index.* >= args.len) return error.UnknownCommand;
    if (!std.mem.eql(u8, args[index.*], "test")) return .{ .unsupported = "logic" };

    var parsed_opts = opts;
    var device: ?[]const u8 = null;
    var out: ?[]const u8 = null;
    var execute = false;
    while (index.* + 1 < args.len) {
        index.* += 1;
        const arg = args[index.*];
        if (std.mem.eql(u8, arg, "--device") or std.mem.eql(u8, arg, "-p")) {
            index.* += 1;
            if (index.* >= args.len) return error.MissingOptionValue;
            device = args[index.*];
        } else if (std.mem.eql(u8, arg, "--out") or std.mem.eql(u8, arg, "--logicic_out")) {
            index.* += 1;
            if (index.* >= args.len) return error.MissingOptionValue;
            out = args[index.*];
        } else if (std.mem.eql(u8, arg, "--execute")) {
            execute = true;
        } else if (std.mem.eql(u8, arg, "--dry-run")) {
            execute = false;
        } else if (std.mem.eql(u8, arg, "--programmer") or std.mem.eql(u8, arg, "-q")) {
            index.* += 1;
            if (index.* >= args.len) return error.MissingOptionValue;
            parsed_opts.programmer = model.Programmer.parse(args[index.*]) orelse return error.UnknownProgrammer;
        } else if (std.mem.eql(u8, arg, "--db")) {
            index.* += 1;
            if (index.* >= args.len) return error.MissingOptionValue;
            parsed_opts.db_path = args[index.*];
        } else {
            return error.UnknownOption;
        }
    }
    return .{ .logic_test = .{ .opts = parsed_opts, .device = device orelse return error.MissingRequiredOption, .out = out, .execute = execute } };
}

fn parseChip(args: []const []const u8, index: *usize, opts: GlobalOptions) !Parsed {
    index.* += 1;
    if (index.* >= args.len) return error.UnknownCommand;
    const subcommand = args[index.*];
    if (std.mem.eql(u8, subcommand, "read")) return try parseChipRead(args, index, opts);
    if (std.mem.eql(u8, subcommand, "verify")) return try parseChipVerify(args, index, opts);
    if (std.mem.eql(u8, subcommand, "erase")) return try parseChipErase(args, index, opts);
    if (std.mem.eql(u8, subcommand, "write")) return try parseChipWrite(args, index, opts);
    if (std.mem.eql(u8, subcommand, "read-id")) return try parseChipReadId(args, index, opts);
    if (std.mem.eql(u8, subcommand, "autodetect")) return try parseChipAutodetect(args, index, opts);
    if (std.mem.eql(u8, subcommand, "blank")) return try parseChipBlank(args, index, opts);
    if (std.mem.eql(u8, subcommand, "protect")) return try parseChipProtect(args, index, opts, true);
    if (std.mem.eql(u8, subcommand, "unprotect")) return try parseChipProtect(args, index, opts, false);
    return .{ .unsupported = "chip" };
}

fn parseChipRead(args: []const []const u8, index: *usize, opts: GlobalOptions) !Parsed {
    var parsed_opts = opts;
    var device: ?[]const u8 = null;
    var out: ?[]const u8 = null;
    var format: FileFormat = .bin;
    var memory: model.MemoryKind = .code;
    var op_opts = OperationOptions{};
    var execute = false;

    while (index.* + 1 < args.len) {
        index.* += 1;
        const arg = args[index.*];
        if (std.mem.eql(u8, arg, "--device") or std.mem.eql(u8, arg, "-p")) {
            index.* += 1;
            if (index.* >= args.len) return error.MissingOptionValue;
            device = args[index.*];
        } else if (std.mem.eql(u8, arg, "--out") or std.mem.eql(u8, arg, "-r")) {
            index.* += 1;
            if (index.* >= args.len) return error.MissingOptionValue;
            out = args[index.*];
        } else if (std.mem.eql(u8, arg, "--format") or std.mem.eql(u8, arg, "-f")) {
            index.* += 1;
            if (index.* >= args.len) return error.MissingOptionValue;
            format = parseFileFormat(args[index.*]) orelse return error.UnknownOption;
        } else if (std.mem.eql(u8, arg, "--memory")) {
            index.* += 1;
            if (index.* >= args.len) return error.MissingOptionValue;
            memory = parseMemoryKind(args[index.*]) orelse return error.UnknownOption;
        } else if (std.mem.eql(u8, arg, "--execute")) {
            execute = true;
        } else if (std.mem.eql(u8, arg, "--dry-run")) {
            execute = false;
        } else if (std.mem.eql(u8, arg, "--programmer") or std.mem.eql(u8, arg, "-q")) {
            index.* += 1;
            if (index.* >= args.len) return error.MissingOptionValue;
            parsed_opts.programmer = model.Programmer.parse(args[index.*]) orelse return error.UnknownProgrammer;
        } else if (std.mem.eql(u8, arg, "--db")) {
            index.* += 1;
            if (index.* >= args.len) return error.MissingOptionValue;
            parsed_opts.db_path = args[index.*];
        } else if (std.mem.eql(u8, arg, "--json")) {
            parsed_opts.json = true;
        } else if (std.mem.eql(u8, arg, "--verbose")) {
            parsed_opts.verbose = true;
        } else if (std.mem.eql(u8, arg, "--quiet")) {
            parsed_opts.quiet = true;
        } else if (try parseOperationOption(args, index, arg, &op_opts)) {
            continue;
        } else {
            return error.UnknownOption;
        }
    }

    return .{ .chip_read = .{
        .opts = parsed_opts,
        .device = device orelse return error.MissingRequiredOption,
        .out = out orelse return error.MissingRequiredOption,
        .format = format,
        .memory = memory,
        .op_opts = op_opts,
        .execute = execute,
    } };
}

fn parseChipVerify(args: []const []const u8, index: *usize, opts: GlobalOptions) !Parsed {
    var parsed_opts = opts;
    var device: ?[]const u8 = null;
    var input: ?[]const u8 = null;
    var format: FileFormat = .bin;
    var memory: model.MemoryKind = .code;
    var op_opts = OperationOptions{};
    var execute = false;

    while (index.* + 1 < args.len) {
        index.* += 1;
        const arg = args[index.*];
        if (std.mem.eql(u8, arg, "--device") or std.mem.eql(u8, arg, "-p")) {
            index.* += 1;
            if (index.* >= args.len) return error.MissingOptionValue;
            device = args[index.*];
        } else if (std.mem.eql(u8, arg, "--in") or std.mem.eql(u8, arg, "--input") or std.mem.eql(u8, arg, "-v")) {
            index.* += 1;
            if (index.* >= args.len) return error.MissingOptionValue;
            input = args[index.*];
        } else if (std.mem.eql(u8, arg, "--format") or std.mem.eql(u8, arg, "-f")) {
            index.* += 1;
            if (index.* >= args.len) return error.MissingOptionValue;
            format = parseFileFormat(args[index.*]) orelse return error.UnknownOption;
        } else if (std.mem.eql(u8, arg, "--memory")) {
            index.* += 1;
            if (index.* >= args.len) return error.MissingOptionValue;
            memory = parseMemoryKind(args[index.*]) orelse return error.UnknownOption;
        } else if (std.mem.eql(u8, arg, "--execute")) {
            execute = true;
        } else if (std.mem.eql(u8, arg, "--dry-run")) {
            execute = false;
        } else if (std.mem.eql(u8, arg, "--programmer") or std.mem.eql(u8, arg, "-q")) {
            index.* += 1;
            if (index.* >= args.len) return error.MissingOptionValue;
            parsed_opts.programmer = model.Programmer.parse(args[index.*]) orelse return error.UnknownProgrammer;
        } else if (std.mem.eql(u8, arg, "--db")) {
            index.* += 1;
            if (index.* >= args.len) return error.MissingOptionValue;
            parsed_opts.db_path = args[index.*];
        } else if (std.mem.eql(u8, arg, "--json")) {
            parsed_opts.json = true;
        } else if (std.mem.eql(u8, arg, "--verbose")) {
            parsed_opts.verbose = true;
        } else if (std.mem.eql(u8, arg, "--quiet")) {
            parsed_opts.quiet = true;
        } else if (try parseOperationOption(args, index, arg, &op_opts)) {
            continue;
        } else {
            return error.UnknownOption;
        }
    }

    return .{ .chip_verify = .{
        .opts = parsed_opts,
        .device = device orelse return error.MissingRequiredOption,
        .input = input orelse return error.MissingRequiredOption,
        .format = format,
        .memory = memory,
        .op_opts = op_opts,
        .execute = execute,
    } };
}

fn parseChipErase(args: []const []const u8, index: *usize, opts: GlobalOptions) !Parsed {
    var parsed_opts = opts;
    var device: ?[]const u8 = null;
    var confirm_destructive: ?[]const u8 = null;
    var execute = false;
    while (index.* + 1 < args.len) {
        index.* += 1;
        const arg = args[index.*];
        if (std.mem.eql(u8, arg, "--device") or std.mem.eql(u8, arg, "-p")) {
            index.* += 1;
            if (index.* >= args.len) return error.MissingOptionValue;
            device = args[index.*];
        } else if (std.mem.eql(u8, arg, "--execute")) {
            execute = true;
        } else if (std.mem.eql(u8, arg, "--dry-run")) {
            execute = false;
        } else if (std.mem.eql(u8, arg, "--confirm-destructive")) {
            index.* += 1;
            if (index.* >= args.len) return error.MissingOptionValue;
            confirm_destructive = args[index.*];
        } else if (std.mem.eql(u8, arg, "--programmer") or std.mem.eql(u8, arg, "-q")) {
            index.* += 1;
            if (index.* >= args.len) return error.MissingOptionValue;
            parsed_opts.programmer = model.Programmer.parse(args[index.*]) orelse return error.UnknownProgrammer;
        } else if (std.mem.eql(u8, arg, "--db")) {
            index.* += 1;
            if (index.* >= args.len) return error.MissingOptionValue;
            parsed_opts.db_path = args[index.*];
        } else {
            return error.UnknownOption;
        }
    }
    return .{ .chip_erase = .{ .opts = parsed_opts, .device = device orelse return error.MissingRequiredOption, .confirm_destructive = confirm_destructive, .execute = execute } };
}

fn parseChipWrite(args: []const []const u8, index: *usize, opts: GlobalOptions) !Parsed {
    var parsed_opts = opts;
    var device: ?[]const u8 = null;
    var input: ?[]const u8 = null;
    var format: FileFormat = .bin;
    var memory: model.MemoryKind = .code;
    var unprotect_before = false;
    var protect_after = false;
    var confirm_destructive: ?[]const u8 = null;
    var op_opts = OperationOptions{};
    var execute = false;
    while (index.* + 1 < args.len) {
        index.* += 1;
        const arg = args[index.*];
        if (std.mem.eql(u8, arg, "--device") or std.mem.eql(u8, arg, "-p")) {
            index.* += 1;
            if (index.* >= args.len) return error.MissingOptionValue;
            device = args[index.*];
        } else if (std.mem.eql(u8, arg, "--in") or std.mem.eql(u8, arg, "--input") or std.mem.eql(u8, arg, "-w")) {
            index.* += 1;
            if (index.* >= args.len) return error.MissingOptionValue;
            input = args[index.*];
        } else if (std.mem.eql(u8, arg, "--format") or std.mem.eql(u8, arg, "-f")) {
            index.* += 1;
            if (index.* >= args.len) return error.MissingOptionValue;
            format = parseFileFormat(args[index.*]) orelse return error.UnknownOption;
        } else if (std.mem.eql(u8, arg, "--memory")) {
            index.* += 1;
            if (index.* >= args.len) return error.MissingOptionValue;
            memory = parseMemoryKind(args[index.*]) orelse return error.UnknownOption;
        } else if (std.mem.eql(u8, arg, "--execute")) {
            execute = true;
        } else if (std.mem.eql(u8, arg, "--dry-run")) {
            execute = false;
        } else if (std.mem.eql(u8, arg, "--unprotect") or std.mem.eql(u8, arg, "-u")) {
            unprotect_before = true;
        } else if (std.mem.eql(u8, arg, "--protect") or std.mem.eql(u8, arg, "-P")) {
            protect_after = true;
        } else if (std.mem.eql(u8, arg, "--confirm-destructive")) {
            index.* += 1;
            if (index.* >= args.len) return error.MissingOptionValue;
            confirm_destructive = args[index.*];
        } else if (std.mem.eql(u8, arg, "--programmer") or std.mem.eql(u8, arg, "-q")) {
            index.* += 1;
            if (index.* >= args.len) return error.MissingOptionValue;
            parsed_opts.programmer = model.Programmer.parse(args[index.*]) orelse return error.UnknownProgrammer;
        } else if (std.mem.eql(u8, arg, "--db")) {
            index.* += 1;
            if (index.* >= args.len) return error.MissingOptionValue;
            parsed_opts.db_path = args[index.*];
        } else if (try parseOperationOption(args, index, arg, &op_opts)) {
            continue;
        } else {
            return error.UnknownOption;
        }
    }
    return .{ .chip_write = .{ .opts = parsed_opts, .device = device orelse return error.MissingRequiredOption, .input = input orelse return error.MissingRequiredOption, .format = format, .memory = memory, .unprotect_before = unprotect_before, .protect_after = protect_after, .confirm_destructive = confirm_destructive, .op_opts = op_opts, .execute = execute } };
}

fn parseChipReadId(args: []const []const u8, index: *usize, opts: GlobalOptions) !Parsed {
    var parsed_opts = opts;
    var device: ?[]const u8 = null;
    var execute = false;
    while (index.* + 1 < args.len) {
        index.* += 1;
        const arg = args[index.*];
        if (std.mem.eql(u8, arg, "--device") or std.mem.eql(u8, arg, "-p")) {
            index.* += 1;
            if (index.* >= args.len) return error.MissingOptionValue;
            device = args[index.*];
        } else if (std.mem.eql(u8, arg, "--execute")) {
            execute = true;
        } else if (std.mem.eql(u8, arg, "--dry-run")) {
            execute = false;
        } else if (std.mem.eql(u8, arg, "--programmer") or std.mem.eql(u8, arg, "-q")) {
            index.* += 1;
            if (index.* >= args.len) return error.MissingOptionValue;
            parsed_opts.programmer = model.Programmer.parse(args[index.*]) orelse return error.UnknownProgrammer;
        } else if (std.mem.eql(u8, arg, "--db")) {
            index.* += 1;
            if (index.* >= args.len) return error.MissingOptionValue;
            parsed_opts.db_path = args[index.*];
        } else {
            return error.UnknownOption;
        }
    }
    return .{ .chip_read_id = .{ .opts = parsed_opts, .device = device orelse return error.MissingRequiredOption, .execute = execute } };
}

fn parseChipAutodetect(args: []const []const u8, index: *usize, opts: GlobalOptions) !Parsed {
    var parsed_opts = opts;
    var package_pins: ?u8 = null;
    var execute = false;
    while (index.* + 1 < args.len) {
        index.* += 1;
        const arg = args[index.*];
        if (std.mem.eql(u8, arg, "--package") or std.mem.eql(u8, arg, "-a")) {
            index.* += 1;
            if (index.* >= args.len) return error.MissingOptionValue;
            package_pins = try parseAutodetectPackage(args[index.*]);
        } else if (std.mem.eql(u8, arg, "--execute")) {
            execute = true;
        } else if (std.mem.eql(u8, arg, "--dry-run")) {
            execute = false;
        } else if (std.mem.eql(u8, arg, "--programmer") or std.mem.eql(u8, arg, "-q")) {
            index.* += 1;
            if (index.* >= args.len) return error.MissingOptionValue;
            parsed_opts.programmer = model.Programmer.parse(args[index.*]) orelse return error.UnknownProgrammer;
        } else if (std.mem.eql(u8, arg, "--db")) {
            index.* += 1;
            if (index.* >= args.len) return error.MissingOptionValue;
            parsed_opts.db_path = args[index.*];
        } else {
            return error.UnknownOption;
        }
    }
    return .{ .chip_autodetect = .{ .opts = parsed_opts, .package_pins = package_pins orelse return error.MissingRequiredOption, .execute = execute } };
}

fn parseChipBlank(args: []const []const u8, index: *usize, opts: GlobalOptions) !Parsed {
    var parsed_opts = opts;
    var device: ?[]const u8 = null;
    var memory: model.MemoryKind = .code;
    var execute = false;
    while (index.* + 1 < args.len) {
        index.* += 1;
        const arg = args[index.*];
        if (std.mem.eql(u8, arg, "--device") or std.mem.eql(u8, arg, "-p")) {
            index.* += 1;
            if (index.* >= args.len) return error.MissingOptionValue;
            device = args[index.*];
        } else if (std.mem.eql(u8, arg, "--memory")) {
            index.* += 1;
            if (index.* >= args.len) return error.MissingOptionValue;
            memory = parseMemoryKind(args[index.*]) orelse return error.UnknownOption;
        } else if (std.mem.eql(u8, arg, "--execute")) {
            execute = true;
        } else if (std.mem.eql(u8, arg, "--dry-run")) {
            execute = false;
        } else if (std.mem.eql(u8, arg, "--programmer") or std.mem.eql(u8, arg, "-q")) {
            index.* += 1;
            if (index.* >= args.len) return error.MissingOptionValue;
            parsed_opts.programmer = model.Programmer.parse(args[index.*]) orelse return error.UnknownProgrammer;
        } else if (std.mem.eql(u8, arg, "--db")) {
            index.* += 1;
            if (index.* >= args.len) return error.MissingOptionValue;
            parsed_opts.db_path = args[index.*];
        } else {
            return error.UnknownOption;
        }
    }
    return .{ .chip_blank = .{ .opts = parsed_opts, .device = device orelse return error.MissingRequiredOption, .memory = memory, .execute = execute } };
}

fn parseChipProtect(args: []const []const u8, index: *usize, opts: GlobalOptions, enable: bool) !Parsed {
    var parsed_opts = opts;
    var device: ?[]const u8 = null;
    var confirm_destructive: ?[]const u8 = null;
    var execute = false;
    while (index.* + 1 < args.len) {
        index.* += 1;
        const arg = args[index.*];
        if (std.mem.eql(u8, arg, "--device") or std.mem.eql(u8, arg, "-p")) {
            index.* += 1;
            if (index.* >= args.len) return error.MissingOptionValue;
            device = args[index.*];
        } else if (std.mem.eql(u8, arg, "--execute")) {
            execute = true;
        } else if (std.mem.eql(u8, arg, "--dry-run")) {
            execute = false;
        } else if (std.mem.eql(u8, arg, "--confirm-destructive")) {
            index.* += 1;
            if (index.* >= args.len) return error.MissingOptionValue;
            confirm_destructive = args[index.*];
        } else if (std.mem.eql(u8, arg, "--programmer") or std.mem.eql(u8, arg, "-q")) {
            index.* += 1;
            if (index.* >= args.len) return error.MissingOptionValue;
            parsed_opts.programmer = model.Programmer.parse(args[index.*]) orelse return error.UnknownProgrammer;
        } else if (std.mem.eql(u8, arg, "--db")) {
            index.* += 1;
            if (index.* >= args.len) return error.MissingOptionValue;
            parsed_opts.db_path = args[index.*];
        } else {
            return error.UnknownOption;
        }
    }
    return .{ .chip_protect = .{ .opts = parsed_opts, .device = device orelse return error.MissingRequiredOption, .enable = enable, .confirm_destructive = confirm_destructive, .execute = execute } };
}

fn parseDb(args: []const []const u8, index: *usize, opts: GlobalOptions) !Parsed {
    index.* += 1;
    if (index.* >= args.len) return error.UnknownCommand;
    const subcommand = args[index.*];
    if (std.mem.eql(u8, subcommand, "stats")) return .{ .db_stats = opts };
    if (std.mem.eql(u8, subcommand, "query")) {
        index.* += 1;
        if (index.* >= args.len) return error.MissingOptionValue;
        return .{ .db_query = .{ .opts = opts, .sql = args[index.*] } };
    }
    if (!std.mem.eql(u8, subcommand, "import")) return .{ .unsupported = "db" };

    var infoic: ?[]const u8 = null;
    var logicic: ?[]const u8 = null;
    var algorithms: ?[]const u8 = null;
    var out: ?[]const u8 = null;
    while (index.* + 1 < args.len) {
        index.* += 1;
        const arg = args[index.*];
        if (std.mem.eql(u8, arg, "--infoic")) {
            index.* += 1;
            if (index.* >= args.len) return error.MissingOptionValue;
            infoic = args[index.*];
        } else if (std.mem.eql(u8, arg, "--out")) {
            index.* += 1;
            if (index.* >= args.len) return error.MissingOptionValue;
            out = args[index.*];
        } else if (std.mem.eql(u8, arg, "--logicic")) {
            index.* += 1;
            if (index.* >= args.len) return error.MissingOptionValue;
            logicic = args[index.*];
        } else if (std.mem.eql(u8, arg, "--algorithms")) {
            index.* += 1;
            if (index.* >= args.len) return error.MissingOptionValue;
            algorithms = args[index.*];
        } else {
            return error.UnknownOption;
        }
    }
    return .{ .db_import = .{ .infoic = infoic orelse return error.MissingRequiredOption, .logicic = logicic, .algorithms = algorithms, .out = out orelse return error.MissingRequiredOption } };
}

fn parseDevice(args: []const []const u8, index: *usize, opts: GlobalOptions) !Parsed {
    index.* += 1;
    if (index.* >= args.len) return error.UnknownCommand;
    const subcommand = args[index.*];
    if (std.mem.eql(u8, subcommand, "list")) {
        const parsed = try parseDeviceOptions(args, index, opts, 100);
        return .{ .device_list = .{ .opts = parsed.opts, .limit = parsed.limit } };
    }
    if (std.mem.eql(u8, subcommand, "search")) {
        index.* += 1;
        if (index.* >= args.len) return error.MissingOptionValue;
        const term = args[index.*];
        const parsed = try parseDeviceOptions(args, index, opts, 100);
        return .{ .device_search = .{ .opts = parsed.opts, .term = term, .limit = parsed.limit } };
    }
    if (std.mem.eql(u8, subcommand, "info")) {
        index.* += 1;
        if (index.* >= args.len) return error.MissingOptionValue;
        const name = args[index.*];
        const parsed = try parseDeviceOptions(args, index, opts, 100);
        return .{ .device_info = .{ .opts = parsed.opts, .name = name } };
    }
    return .{ .unsupported = "device" };
}

fn parseLimitOption(args: []const []const u8, index: *usize, default: usize) !usize {
    var limit = default;
    while (index.* + 1 < args.len) {
        index.* += 1;
        const arg = args[index.*];
        if (!std.mem.eql(u8, arg, "--limit")) return error.UnknownOption;
        index.* += 1;
        if (index.* >= args.len) return error.MissingOptionValue;
        limit = std.fmt.parseInt(usize, args[index.*], 10) catch return error.InvalidLimit;
    }
    return limit;
}

const ParsedDeviceOptions = struct {
    opts: GlobalOptions,
    limit: usize,
};

fn parseDeviceOptions(args: []const []const u8, index: *usize, initial: GlobalOptions, default_limit: usize) !ParsedDeviceOptions {
    var opts = initial;
    var limit = default_limit;
    while (index.* + 1 < args.len) {
        index.* += 1;
        const arg = args[index.*];
        if (std.mem.eql(u8, arg, "--limit")) {
            index.* += 1;
            if (index.* >= args.len) return error.MissingOptionValue;
            limit = std.fmt.parseInt(usize, args[index.*], 10) catch return error.InvalidLimit;
        } else if (std.mem.eql(u8, arg, "--programmer") or std.mem.eql(u8, arg, "-q")) {
            index.* += 1;
            if (index.* >= args.len) return error.MissingOptionValue;
            opts.programmer = model.Programmer.parse(args[index.*]) orelse return error.UnknownProgrammer;
        } else if (std.mem.eql(u8, arg, "--db")) {
            index.* += 1;
            if (index.* >= args.len) return error.MissingOptionValue;
            opts.db_path = args[index.*];
        } else if (std.mem.eql(u8, arg, "--json")) {
            opts.json = true;
        } else if (std.mem.eql(u8, arg, "--verbose")) {
            opts.verbose = true;
        } else if (std.mem.eql(u8, arg, "--quiet")) {
            opts.quiet = true;
        } else {
            return error.UnknownOption;
        }
    }
    return .{ .opts = opts, .limit = limit };
}

fn parseFileFormat(text: []const u8) ?FileFormat {
    if (std.ascii.eqlIgnoreCase(text, "bin") or std.ascii.eqlIgnoreCase(text, "binary")) return .bin;
    if (std.ascii.eqlIgnoreCase(text, "ihex") or std.ascii.eqlIgnoreCase(text, "hex")) return .ihex;
    if (std.ascii.eqlIgnoreCase(text, "srec") or std.ascii.eqlIgnoreCase(text, "srecord")) return .srec;
    if (std.ascii.eqlIgnoreCase(text, "jedec") or std.ascii.eqlIgnoreCase(text, "jed")) return .jedec;
    if (std.ascii.eqlIgnoreCase(text, "config") or std.ascii.eqlIgnoreCase(text, "cfg")) return .config;
    return null;
}

fn parseMemoryKind(text: []const u8) ?model.MemoryKind {
    if (std.ascii.eqlIgnoreCase(text, "code")) return .code;
    if (std.ascii.eqlIgnoreCase(text, "data")) return .data;
    if (std.ascii.eqlIgnoreCase(text, "user")) return .user;
    return null;
}

fn parseAutodetectPackage(text: []const u8) !u8 {
    if (std.mem.eql(u8, text, "8")) return 8;
    if (std.mem.eql(u8, text, "16")) return 16;
    return error.InvalidLimit;
}

fn parseTrailingGlobalOptions(args: []const []const u8, index: *usize, initial: GlobalOptions) !GlobalOptions {
    var opts = initial;
    while (index.* + 1 < args.len) {
        index.* += 1;
        const arg = args[index.*];
        if (std.mem.eql(u8, arg, "--db")) {
            index.* += 1;
            if (index.* >= args.len) return error.MissingOptionValue;
            opts.db_path = args[index.*];
        } else if (std.mem.eql(u8, arg, "--programmer") or std.mem.eql(u8, arg, "-q")) {
            index.* += 1;
            if (index.* >= args.len) return error.MissingOptionValue;
            opts.programmer = model.Programmer.parse(args[index.*]) orelse return error.UnknownProgrammer;
        } else if (std.mem.eql(u8, arg, "--json")) {
            opts.json = true;
        } else if (std.mem.eql(u8, arg, "--verbose")) {
            opts.verbose = true;
        } else if (std.mem.eql(u8, arg, "--quiet")) {
            opts.quiet = true;
        } else {
            return error.UnknownOption;
        }
    }
    return opts;
}

fn parseErrorMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.UnknownOption => "Unknown option or command.",
        error.MissingOptionValue => "Missing option value.",
        error.UnknownProgrammer => "Unknown programmer. Expected tl866a, tl866ii, t48, t56, t76, or auto.",
        error.UnknownCommand => "Missing or unknown command.",
        error.NoCommand => "Missing command.",
        error.NoLegacyAction => "No action to perform.",
        error.MissingLegacySearchArgument => "minipro-zig: option requires an argument -- L",
        error.MissingRequiredOption => "Missing required option.",
        error.InvalidLimit => "Invalid limit.",
        error.InvalidOperationValue => "Invalid operation option value.",
        else => "Invalid arguments.",
    };
}

fn databasePath(opts: GlobalOptions) []const u8 {
    return opts.db_path orelse "minipro.sqlite";
}

fn destructiveConfirmed(confirm: ?[]const u8, canonical_name: []const u8) bool {
    const value = confirm orelse return false;
    return std.ascii.eqlIgnoreCase(value, canonical_name);
}

fn programmerFilter(programmer: model.Programmer) ?[]const u8 {
    return switch (programmer) {
        .auto => null,
        .tl866a, .tl866ii, .t48, .t56, .t76 => programmer.name(),
    };
}

fn programmerDatabaseFamily(programmer: model.Programmer) ?[]const u8 {
    return switch (programmer) {
        .auto => null,
        .tl866a => "tl866a",
        .tl866ii, .t48, .t56 => "tl866ii",
        .t76 => "t76",
    };
}

fn readFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    return try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1024 * 1024 * 1024));
}

fn writeLogicTestPlan(writer: anytype, command: LogicTest, device: sqlite.LogicDevice) !void {
    try writer.writeAll("Dry-run: logic IC test plan\n");
    try writer.print("Device: {s}\n", .{device.canonical_name});
    try writer.print("Programmer family: {s}\n", .{programmerDatabaseFamily(command.opts.programmer) orelse "auto"});
    try writer.print("Package: DIP{d}\n", .{device.pin_count});
    try writer.print("Vector count: {d}\n", .{device.vectors.len});
    try writer.print("Default VCC voltage: {s} V\n", .{logicVoltageName(device.vcc_index)});
    if (command.out) |out| try writer.print("Logicic output: {s}\n", .{out});
    if (device.vectors.len != 0) {
        try writer.writeAll("Vectors:\n");
        for (device.vectors) |vector| try writer.print("  {s}: {s}\n", .{ vector.id, vector.states });
    }
    try writer.writeAll("Hardware access: disabled (pass --execute to run the vector test on supported programmers)\n");
}

fn executeLogicTest(allocator: std.mem.Allocator, io: std.Io, command: LogicTest, device: sqlite.LogicDevice, writer: anytype) !usize {
    const usb_transport = usb.UsbTransport.open(allocator) catch |err| return err;
    const programmer_session = session.Session.open(usb_transport.transport()) catch |err| {
        usb_transport.transport().close();
        return err;
    };
    defer programmer_session.close();
    switch (programmer_session.info.programmer) {
        .t48, .tl866ii, .t56, .t76 => {},
        else => return error.UnsupportedProgrammer,
    }
    if (command.opts.programmer != .auto and command.opts.programmer != programmer_session.info.programmer) return error.ProgrammerMismatch;

    if (programmer_session.info.programmer == .t56) try uploadT56LogicBitstreams(allocator, command.opts, programmer_session.transport);

    const pin_len: usize = device.pin_count;
    const result_len = pin_len * device.vectors.len;
    const first_step = try allocator.alloc(u8, result_len);
    defer allocator.free(first_step);
    const second_step = try allocator.alloc(u8, result_len);
    defer allocator.free(second_step);

    try runLogicPhase(allocator, command.opts, programmer_session.info.programmer, programmer_session.transport, device, false, first_step);
    try runLogicPhase(allocator, command.opts, programmer_session.info.programmer, programmer_session.transport, device, true, second_step);

    if (command.out) |out| {
        try writeLogicObservedXml(allocator, io, out, device, first_step, second_step);
        return 0;
    }

    try writer.writeAll("      ");
    var pin: usize = 1;
    while (pin <= device.pin_count) : (pin += 1) try writer.print("{d:<3}", .{pin});
    try writer.writeAll("\n");

    var errors: usize = 0;
    for (device.vectors, 0..) |vector, vector_index| {
        const states = try logic.parseStates(allocator, vector.states);
        defer allocator.free(states);
        if (states.len != pin_len) return error.InvalidLogicVector;

        try writer.print("{d:0>4}: ", .{vector_index});
        for (states, 0..) |state, index| {
            const result_index = vector_index * pin_len + index;
            const failed = logicStateFailed(state, first_step[result_index], second_step[result_index]);
            if (failed) errors += 1;
            const marker: u8 = if (failed) '-' else ' ';
            try writer.print("{c}{c} ", .{ logic.stateChar(state), marker });
        }
        try writer.writeAll("\n");
    }
    return errors;
}

fn writeLogicObservedXml(allocator: std.mem.Allocator, io: std.Io, path: []const u8, device: sqlite.LogicDevice, first_step: []const u8, second_step: []const u8) !void {
    const pin_len: usize = device.pin_count;
    if (first_step.len != pin_len * device.vectors.len or second_step.len != pin_len * device.vectors.len) return error.InvalidLogicVector;
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    const writer = &output.writer;
    try writer.writeAll("<?xml version=\"1.0\" encoding=\"utf-8\"?>\n");
    try writer.writeAll("<logicic>\n");
    try writer.writeAll("  <database device=\"LOGIC\">\n");
    try writer.writeAll("    <manufacturer name=\"Logic Ic\">\n");
    try writer.print("      <ic name=\"{s}\" type=\"5\" voltage=\"{s}\" pins=\"{d}\">\n", .{ device.canonical_name, logicVoltageXmlName(device.vcc_index), device.pin_count });
    for (device.vectors, 0..) |vector, vector_index| {
        const states = try logic.parseStates(allocator, vector.states);
        defer allocator.free(states);
        if (states.len != pin_len) return error.InvalidLogicVector;
        try writer.print("        <vector id=\"{s}\"> ", .{vector.id});
        for (states, 0..) |state, pin_index| {
            const result_index = vector_index * pin_len + pin_index;
            try writer.print("{c} ", .{observedLogicState(state, first_step[result_index], second_step[result_index])});
        }
        try writer.writeAll("</vector>\n");
    }
    try writer.writeAll("      </ic>\n");
    try writer.writeAll("    </manufacturer>\n");
    try writer.writeAll("  </database>\n");
    try writer.writeAll("</logicic>\n");
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = writer.buffered() });
}

fn runLogicPhase(allocator: std.mem.Allocator, opts: GlobalOptions, programmer: model.Programmer, trans: anytype, device: sqlite.LogicDevice, pull_down: bool, results: []u8) !void {
    const pin_len: usize = device.pin_count;
    if (results.len != pin_len * device.vectors.len) return error.InvalidLogicVector;
    if (programmer == .t76) try uploadT76LogicBitstream(allocator, opts, trans, pull_down);
    for (device.vectors, 0..) |vector, vector_index| {
        const states = try logic.parseStates(allocator, vector.states);
        defer allocator.free(states);
        if (states.len != pin_len) return error.InvalidLogicVector;
        try testLogicVectorProtocol(programmer, trans, device.vcc_index, pull_down, device.pin_count, @intCast(vector_index), states, results[vector_index * pin_len ..][0..pin_len]);
    }
}

fn uploadT56LogicBitstreams(allocator: std.mem.Allocator, opts: GlobalOptions, trans: anytype) !void {
    const ttl1 = try loadUtilityAlgorithmBitstream(allocator, opts, .t56, 0);
    defer allocator.free(ttl1);
    try t56.uploadBitstream(trans, ttl1);
    const ttl2 = try loadUtilityAlgorithmBitstream(allocator, opts, .t56, 1);
    defer allocator.free(ttl2);
    try t56.uploadBitstream(trans, ttl2);
}

fn uploadT76LogicBitstream(allocator: std.mem.Allocator, opts: GlobalOptions, trans: anytype, pull_down: bool) !void {
    const variant: u8 = if (pull_down) 2 else 3;
    const bitstream = try loadUtilityAlgorithmBitstream(allocator, opts, .t76, variant);
    defer allocator.free(bitstream);
    try t76.uploadBitstream(trans, bitstream);
}

fn testLogicVectorProtocol(programmer: model.Programmer, trans: anytype, vcc_index: u8, pull_down: bool, pin_count: u16, vector_index: u32, states: []const logic.State, out: []u8) !void {
    return switch (programmer) {
        .t48 => t48.testLogicVector(trans, vcc_index, pull_down, pin_count, vector_index, states, out),
        .tl866ii => tl866ii.testLogicVector(trans, vcc_index, pull_down, pin_count, vector_index, states, out),
        .t56 => t56.testLogicVector(trans, vcc_index, pull_down, pin_count, vector_index, states, out),
        .t76 => t76.testLogicVector(trans, vcc_index, pull_down, pin_count, vector_index, states, out),
        else => error.UnsupportedProgrammer,
    };
}

fn logicStateFailed(state: logic.State, first_step: u8, second_step: u8) bool {
    return switch (state) {
        .low => first_step != 0 or second_step != 0,
        .high => first_step == 0 or second_step == 0,
        .z => first_step == 0 or second_step != 0,
        else => false,
    };
}

fn observedLogicState(state: logic.State, first_step: u8, second_step: u8) u8 {
    return switch (state) {
        .low, .high, .z => if (first_step != 0 and second_step != 0)
            'H'
        else if (first_step == 0 and second_step == 0)
            'L'
        else if (first_step != 0 and second_step == 0)
            'Z'
        else
            '?',
        else => logic.stateChar(state),
    };
}

fn logicVoltageXmlName(index: u8) []const u8 {
    return switch (index) {
        0 => "5V",
        1 => "3V3",
        2 => "2V5",
        3 => "1V8",
        else => "5V",
    };
}

fn logicVoltageName(index: u8) []const u8 {
    return switch (index) {
        0 => "5",
        1 => "3.3",
        2 => "2.5",
        3 => "1.8",
        else => "unknown",
    };
}

fn writeChipReadPlan(writer: anytype, command: ChipRead, device: sqlite.ProtocolDevice) !void {
    const descriptor = t48.deviceFromProtocolInfo(device, 0, 0);
    const size = switch (command.memory) {
        .code => device.code_memory_size,
        .data => device.data_memory_size,
        .user => device.data_memory2_size,
    };
    try writer.writeAll("Dry-run: chip read plan\n");
    try writer.print("Device: {s}\n", .{device.canonical_name});
    try writer.print("Programmer family: {s}\n", .{programmerDatabaseFamily(command.opts.programmer) orelse "auto"});
    try writer.print("Protocol: 0x{x:0>2}\n", .{descriptor.protocol_id});
    try writer.print("Variant: 0x{x}\n", .{descriptor.variant});
    try writer.print("Memory: {s}\n", .{memoryKindName(command.memory)});
    try writer.print("Size: {d} Bytes\n", .{size});
    try writer.print("Read buffer: {d} Bytes\n", .{descriptor.read_buffer_size});
    try writer.print("Output: {s}\n", .{command.out});
    try writer.print("Format: {s}\n", .{fileFormatName(command.format)});
    try writeOperationOptions(writer, command.op_opts);
    try writer.writeAll("Hardware access: disabled (pass --execute to read the inserted chip)\n");
}

fn writeChipFuseReadPlan(writer: anytype, command: ChipRead, device: sqlite.ProtocolDevice, fuse_items: sqlite.ConfigItems, lock_items: sqlite.ConfigItems) !void {
    try writer.writeAll("Dry-run: chip fuse read plan\n");
    try writer.print("Device: {s}\n", .{device.canonical_name});
    try writer.print("Programmer family: {s}\n", .{programmerDatabaseFamily(command.opts.programmer) orelse "auto"});
    try writer.print("Output: {s}\n", .{command.out});
    try writer.print("Format: {s}\n", .{fileFormatName(command.format)});
    try writer.print("Config ref: {s}\n", .{device.config_ref});
    try writer.print("Config fuses: {d}\n", .{fuse_items.items.len});
    try writer.print("Config locks: {d}\n", .{lock_items.items.len});
    try writeOperationOptions(writer, command.op_opts);
    try writer.writeAll("Hardware access: disabled (pass --execute to read config fuses)\n");
}

fn writeChipVerifyPlan(writer: anytype, command: ChipVerify, device: sqlite.ProtocolDevice, input: image.MemoryImage) !void {
    const descriptor = t48.deviceFromProtocolInfo(device, 0, 0);
    const expected_size = chipReadSize(command.memory, device);
    try writer.writeAll("Dry-run: chip verify plan\n");
    try writer.print("Device: {s}\n", .{device.canonical_name});
    try writer.print("Programmer family: {s}\n", .{programmerDatabaseFamily(command.opts.programmer) orelse "auto"});
    try writer.print("Protocol: 0x{x:0>2}\n", .{descriptor.protocol_id});
    try writer.print("Variant: 0x{x}\n", .{descriptor.variant});
    try writer.print("Memory: {s}\n", .{memoryKindName(command.memory)});
    try writer.print("Expected size: {d} Bytes\n", .{expected_size});
    try writer.print("Input: {s}\n", .{command.input});
    try writer.print("Input size: {d} Bytes\n", .{input.data.len});
    try writer.print("Format: {s}\n", .{fileFormatName(command.format)});
    if (command.format == .jedec) {
        try writer.print("Config ref: {s}\n", .{device.config_ref});
        try writer.print("Config fuses: {d}\n", .{device.config_fuse_count});
        if (device.config_fuse_details.len != 0) try writer.print("Config fuse details: {s}\n", .{device.config_fuse_details});
        try writer.print("Config locks: {d}\n", .{device.config_lock_count});
        if (device.config_lock_details.len != 0) try writer.print("Config lock details: {s}\n", .{device.config_lock_details});
    }
    try writer.print("Size check: {s}\n", .{sizeCheckName(sizeCheck(input.data.len, expected_size, command.op_opts))});
    try writeOperationOptions(writer, command.op_opts);
    if (command.format == .jedec) {
        if (device.chip_type == @intFromEnum(model.ChipType.pld)) {
            try writer.writeAll("Hardware access: disabled (pass --execute to read and compare JEDEC fuses)\n");
        } else {
            try writer.writeAll("Hardware access: disabled (JEDEC execution requires a PLD/GAL device)\n");
        }
    } else {
        try writer.writeAll("Hardware access: disabled (pass --execute to read and compare the inserted chip)\n");
    }
}

fn loadVerifyImage(allocator: std.mem.Allocator, io: std.Io, command: ChipVerify) !image.MemoryImage {
    const bytes = try readFile(allocator, io, command.input);
    defer allocator.free(bytes);
    return switch (command.format) {
        .bin => try image.MemoryImage.initCopy(allocator, bytes, .{ .kind = command.memory }),
        .ihex => try ihex.readAll(allocator, bytes, .{ .kind = command.memory }),
        .srec => try srec.readAll(allocator, bytes, .{ .kind = command.memory }),
        .jedec => try loadJedecAsImage(allocator, bytes, command.memory),
        .config => error.UnsupportedFormat,
    };
}

const FusePlan = struct {
    allocator: std.mem.Allocator,
    input_bytes: []u8,
    values: []fuses.NamedValue,
    fuse_items: sqlite.ConfigItems,
    lock_items: sqlite.ConfigItems,
    fuse_bytes: []u8,
    lock_bytes: []u8,

    fn deinit(self: *FusePlan) void {
        self.allocator.free(self.fuse_bytes);
        self.allocator.free(self.lock_bytes);
        self.fuse_items.deinit(self.allocator);
        self.lock_items.deinit(self.allocator);
        self.allocator.free(self.values);
        self.allocator.free(self.input_bytes);
        self.* = undefined;
    }
};

fn loadFusePlan(allocator: std.mem.Allocator, io: std.Io, db: sqlite.Database, device: sqlite.ProtocolDevice, input: []const u8) !FusePlan {
    const bytes = try readFile(allocator, io, input);
    errdefer allocator.free(bytes);
    const values = try fuses.parseNamedValues(allocator, bytes);
    errdefer allocator.free(values);
    const fuse_items = try db.configItems(allocator, device.config_ref, .fuse);
    errdefer fuse_items.deinit(allocator);
    const lock_items = try db.configItems(allocator, device.config_ref, .lock);
    errdefer lock_items.deinit(allocator);
    const decoded_flags = model.decodeFlags(device.flags_raw, device.voltages_raw, device.chip_info, device.protocol_id);
    const word_size = decoded_flags.word_size;
    const fuse_len = try fuses.packedLen(fuse_items.items, word_size);
    const lock_len = try fuses.packedLen(lock_items.items, word_size);
    const fuse_bytes = try allocator.alloc(u8, fuse_len);
    errdefer allocator.free(fuse_bytes);
    const lock_bytes = try allocator.alloc(u8, lock_len);
    errdefer allocator.free(lock_bytes);
    _ = try fuses.packItems(fuse_bytes, fuse_items.items, values, .{ .word_size = word_size, .compare_mask = device.compare_mask, .apply_compare_mask = true });
    _ = try fuses.packItems(lock_bytes, lock_items.items, values, .{ .word_size = word_size });
    return .{
        .allocator = allocator,
        .input_bytes = bytes,
        .values = values,
        .fuse_items = fuse_items,
        .lock_items = lock_items,
        .fuse_bytes = fuse_bytes,
        .lock_bytes = lock_bytes,
    };
}

fn writeChipFuseVerifyPlan(writer: anytype, command: ChipVerify, device: sqlite.ProtocolDevice, plan: FusePlan) !void {
    try writer.writeAll("Dry-run: chip fuse verify plan\n");
    try writer.print("Device: {s}\n", .{device.canonical_name});
    try writer.print("Programmer family: {s}\n", .{programmerDatabaseFamily(command.opts.programmer) orelse "auto"});
    try writer.print("Input: {s}\n", .{command.input});
    try writer.print("Format: {s}\n", .{fileFormatName(command.format)});
    try writer.print("Config ref: {s}\n", .{device.config_ref});
    try writer.print("Config fuses: {d} ({d} Bytes)\n", .{ plan.fuse_items.items.len, plan.fuse_bytes.len });
    try writer.print("Config locks: {d} ({d} Bytes)\n", .{ plan.lock_items.items.len, plan.lock_bytes.len });
    try writeOperationOptions(writer, command.op_opts);
    try writer.writeAll("Hardware access: disabled (pass --execute to read and compare config fuses)\n");
}

fn writeChipErasePlan(writer: anytype, command: ChipErase, device: sqlite.ProtocolDevice) !void {
    const descriptor = t48.deviceFromProtocolInfo(device, 0, 0);
    try writer.writeAll("Dry-run: chip erase plan\n");
    try writer.print("Device: {s}\n", .{device.canonical_name});
    try writer.print("Programmer family: {s}\n", .{programmerDatabaseFamily(command.opts.programmer) orelse "auto"});
    try writer.print("Protocol: 0x{x:0>2}\n", .{descriptor.protocol_id});
    try writer.print("Variant: 0x{x}\n", .{descriptor.variant});
    try writer.print("Code memory: {d} Bytes\n", .{device.code_memory_size});
    try writer.print("Data memory: {d} Bytes\n", .{device.data_memory_size});
    try writer.print("User memory: {d} Bytes\n", .{device.data_memory2_size});
    try writeOperationOptions(writer, command.op_opts);
    try writer.writeAll("Hardware access: disabled (pass --execute --confirm-destructive <device> to erase)\n");
}

fn writeChipWritePlan(writer: anytype, command: ChipWrite, device: sqlite.ProtocolDevice, input: image.MemoryImage) !void {
    const descriptor = t48.deviceFromProtocolInfo(device, 0, 0);
    const expected_size = chipReadSize(command.memory, device);
    try writer.writeAll("Dry-run: chip write plan\n");
    try writer.print("Device: {s}\n", .{device.canonical_name});
    try writer.print("Programmer family: {s}\n", .{programmerDatabaseFamily(command.opts.programmer) orelse "auto"});
    try writer.print("Protocol: 0x{x:0>2}\n", .{descriptor.protocol_id});
    try writer.print("Variant: 0x{x}\n", .{descriptor.variant});
    try writer.print("Memory: {s}\n", .{memoryKindName(command.memory)});
    try writer.print("Target size: {d} Bytes\n", .{expected_size});
    try writer.print("Input: {s}\n", .{command.input});
    try writer.print("Input size: {d} Bytes\n", .{input.data.len});
    try writer.print("Format: {s}\n", .{fileFormatName(command.format)});
    if (command.format == .jedec) {
        try writer.print("Config ref: {s}\n", .{device.config_ref});
        try writer.print("Config fuses: {d}\n", .{device.config_fuse_count});
        if (device.config_fuse_details.len != 0) try writer.print("Config fuse details: {s}\n", .{device.config_fuse_details});
        try writer.print("Config locks: {d}\n", .{device.config_lock_count});
        if (device.config_lock_details.len != 0) try writer.print("Config lock details: {s}\n", .{device.config_lock_details});
    }
    try writer.print("Size check: {s}\n", .{sizeCheckName(sizeCheck(input.data.len, expected_size, command.op_opts))});
    try writer.print("Write buffer: {d} Bytes\n", .{descriptor.write_buffer_size});
    try writer.print("Unprotect before write: {s}\n", .{if (command.unprotect_before) "yes" else "no"});
    try writer.print("Protect after write: {s}\n", .{if (command.protect_after) "yes" else "no"});
    try writeOperationOptions(writer, command.op_opts);
    if (command.format == .jedec) {
        if (device.chip_type == @intFromEnum(model.ChipType.pld)) {
            try writer.writeAll("Hardware access: disabled (pass --execute --confirm-destructive <device> to write JEDEC fuses)\n");
        } else {
            try writer.writeAll("Hardware access: disabled (JEDEC execution requires a PLD/GAL device)\n");
        }
    } else {
        try writer.writeAll("Hardware access: disabled (pass --execute --confirm-destructive <device> to write)\n");
    }
}

fn loadWriteImage(allocator: std.mem.Allocator, io: std.Io, command: ChipWrite) !image.MemoryImage {
    const bytes = try readFile(allocator, io, command.input);
    defer allocator.free(bytes);
    return switch (command.format) {
        .bin => try image.MemoryImage.initCopy(allocator, bytes, .{ .kind = command.memory }),
        .ihex => try ihex.readAll(allocator, bytes, .{ .kind = command.memory }),
        .srec => try srec.readAll(allocator, bytes, .{ .kind = command.memory }),
        .jedec => try loadJedecAsImage(allocator, bytes, command.memory),
        .config => error.UnsupportedFormat,
    };
}

fn writeChipFuseWritePlan(writer: anytype, command: ChipWrite, device: sqlite.ProtocolDevice, plan: FusePlan) !void {
    try writer.writeAll("Dry-run: chip fuse write plan\n");
    try writer.print("Device: {s}\n", .{device.canonical_name});
    try writer.print("Programmer family: {s}\n", .{programmerDatabaseFamily(command.opts.programmer) orelse "auto"});
    try writer.print("Input: {s}\n", .{command.input});
    try writer.print("Format: {s}\n", .{fileFormatName(command.format)});
    try writer.print("Config ref: {s}\n", .{device.config_ref});
    try writer.print("Config fuses: {d} ({d} Bytes)\n", .{ plan.fuse_items.items.len, plan.fuse_bytes.len });
    try writer.print("Config locks: {d} ({d} Bytes)\n", .{ plan.lock_items.items.len, plan.lock_bytes.len });
    try writeOperationOptions(writer, command.op_opts);
    try writer.writeAll("Hardware access: disabled (pass --execute --confirm-destructive <device> to write config fuses)\n");
}

fn writeChipJedecGalPlan(writer: anytype, gal: sqlite.GalConfig) !void {
    try writer.print("JEDEC rows: {d}\n", .{gal.fuses_size});
    try writer.print("JEDEC row width: {d} bits\n", .{gal.row_width});
    try writer.print("JEDEC UES: address 0x{x:0>4}, {d} bits\n", .{ gal.ues_address, gal.ues_size });
    try writer.print("JEDEC ACW: row 0x{x:0>2}, {d} bits\n", .{ gal.acw_address, gal.acw_bits.len });
    if (gal.powerdown_row != 0) try writer.print("JEDEC power-down row: 0x{x:0>2}\n", .{gal.powerdown_row});
}

fn loadJedecAsImage(allocator: std.mem.Allocator, bytes: []const u8, memory: model.MemoryKind) !image.MemoryImage {
    var fuse_file = try jedec.readAll(allocator, bytes);
    defer fuse_file.deinit();
    return try image.MemoryImage.initCopy(allocator, fuse_file.fuses, .{ .kind = memory });
}

fn writeChipReadIdPlan(writer: anytype, command: ChipReadId, device: sqlite.ProtocolDevice) !void {
    const descriptor = t48.deviceFromProtocolInfo(device, 0, 0);
    try writer.writeAll("Dry-run: chip read-id plan\n");
    try writer.print("Device: {s}\n", .{device.canonical_name});
    try writer.print("Programmer family: {s}\n", .{programmerDatabaseFamily(command.opts.programmer) orelse "auto"});
    try writer.print("Protocol: 0x{x:0>2}\n", .{descriptor.protocol_id});
    try writer.print("Variant: 0x{x}\n", .{descriptor.variant});
    try writer.print("Expected chip ID: 0x{x}\n", .{device.chip_id});
    try writer.print("Chip ID bytes: {d}\n", .{device.chip_id_bytes_count});
    try writeOperationOptions(writer, command.op_opts);
    try writer.writeAll("Hardware access: disabled (pass --execute to read the inserted chip ID)\n");
}

fn writeChipAutodetectPlan(writer: anytype, command: ChipAutodetect) !void {
    try writer.writeAll("Dry-run: chip autodetect plan\n");
    try writer.print("Programmer family: {s}\n", .{programmerDatabaseFamily(command.opts.programmer) orelse "auto"});
    try writer.print("Package: {d}-pin SPI\n", .{command.package_pins});
    try writer.writeAll("Hardware access: disabled (pass --execute to read SPI flash ID and list matching devices)\n");
}

fn writeChipBlankPlan(writer: anytype, command: ChipBlank, device: sqlite.ProtocolDevice) !void {
    const descriptor = t48.deviceFromProtocolInfo(device, 0, 0);
    const size = chipReadSize(command.memory, device);
    try writer.writeAll("Dry-run: chip blank-check plan\n");
    try writer.print("Device: {s}\n", .{device.canonical_name});
    try writer.print("Programmer family: {s}\n", .{programmerDatabaseFamily(command.opts.programmer) orelse "auto"});
    try writer.print("Protocol: 0x{x:0>2}\n", .{descriptor.protocol_id});
    try writer.print("Variant: 0x{x}\n", .{descriptor.variant});
    try writer.print("Memory: {s}\n", .{memoryKindName(command.memory)});
    try writer.print("Size: {d} Bytes\n", .{size});
    try writer.print("Blank value: 0x{x}\n", .{device.blank_value});
    try writeOperationOptions(writer, command.op_opts);
    try writer.writeAll("Hardware access: disabled (pass --execute to read and blank-check the inserted chip)\n");
}

fn writeChipPinCheckPlan(writer: anytype, command: ChipPinCheck, device: sqlite.ProtocolDevice, map_index: u32, pin_map: sqlite.PinMap) !void {
    const package = model.decodePackageDetails(device.package_details_raw);
    try writer.writeAll("Dry-run: chip pin-contact test plan\n");
    try writer.print("Device: {s}\n", .{device.canonical_name});
    try writer.print("Programmer family: {s}\n", .{programmerDatabaseFamily(command.opts.programmer) orelse "auto"});
    try writer.print("Package pins: {d}\n", .{package.pin_count});
    try writer.print("Pin map: {d}\n", .{map_index});
    try writer.print("GND pins: {d}\n", .{pin_map.gnd_pins.len});
    try writer.print("Pins to check: {d}\n", .{pin_map.masks.len});
    try writer.writeAll("Hardware access: disabled (pass --execute to run the pin-contact test on supported programmers)\n");
}

fn writeChipProtectPlan(writer: anytype, command: ChipProtect, device: sqlite.ProtocolDevice) !void {
    const descriptor = t48.deviceFromProtocolInfo(device, 0, 0);
    try writer.print("Dry-run: chip {s} plan\n", .{if (command.enable) "protect" else "unprotect"});
    try writer.print("Device: {s}\n", .{device.canonical_name});
    try writer.print("Programmer family: {s}\n", .{programmerDatabaseFamily(command.opts.programmer) orelse "auto"});
    try writer.print("Protocol: 0x{x:0>2}\n", .{descriptor.protocol_id});
    try writer.print("Variant: 0x{x}\n", .{descriptor.variant});
    try writer.print("Operation: {s}\n", .{if (command.enable) "protect on" else "protect off"});
    try writeOperationOptions(writer, command.op_opts);
    try writer.writeAll("Hardware access: disabled (pass --execute --confirm-destructive <device> to change protection)\n");
}

fn writeOperationOptions(writer: anytype, options: OperationOptions) !void {
    if (!options.hasAny()) return;
    try writer.writeAll("Advanced options:\n");
    if (options.no_erase) try writer.writeAll("  no erase: yes\n");
    if (options.no_verify) try writer.writeAll("  no verify: yes\n");
    if (options.idcheck_skip) try writer.writeAll("  skip ID check: yes\n");
    if (options.idcheck_continue) try writer.writeAll("  continue on ID mismatch: yes\n");
    if (options.pincheck) try writer.writeAll("  pin check: yes\n");
    if (options.size_error) try writer.writeAll("  size mismatch is error: yes\n");
    if (options.size_nowarn) try writer.writeAll("  suppress size warning: yes\n");
    if (options.force_erase) try writer.writeAll("  force erase before write: yes\n");
    if (options.pulse) |value| try writer.print("  pulse: {s}\n", .{value});
    if (options.vpp) |value| try writer.print("  vpp: {s}\n", .{value});
    if (options.vdd) |value| try writer.print("  vdd: {s}\n", .{value});
    if (options.vcc) |value| try writer.print("  vcc: {s}\n", .{value});
    if (options.spi_clock) |value| try writer.print("  spi_clock: {s}\n", .{value});
    if (options.address) |value| try writer.print("  address: {s}\n", .{value});
}

fn sizeCheck(actual: usize, expected: usize, options: OperationOptions) SizeCheck {
    if (actual == expected) return .ok;
    if (!options.size_error) return .mismatch_error;
    if (options.size_nowarn) return .mismatch_silent;
    return .mismatch_warn;
}

fn sizeCheckName(check: SizeCheck) []const u8 {
    return switch (check) {
        .ok => "ok",
        .mismatch_error => "mismatch (error; use -s/-S to ignore)",
        .mismatch_warn => "mismatch (warning; continuing)",
        .mismatch_silent => "mismatch (ignored)",
    };
}

fn reportInputSizeMismatch(writer: anytype, options: OperationOptions, actual: usize, expected: usize) !bool {
    switch (sizeCheck(actual, expected, options)) {
        .ok, .mismatch_silent => return false,
        .mismatch_error => {
            try writer.print("Incorrect file size: {d} (needed {d}, use -s/S to ignore)\n", .{ actual, expected });
            return true;
        },
        .mismatch_warn => {
            try writer.print("Warning: Incorrect file size: {d} (needed {d})\n", .{ actual, expected });
            return false;
        },
    }
}

fn rejectAdvancedOperationOptions(writer: anytype, options: OperationOptions) !bool {
    if (!options.pincheck and !options.force_erase) return false;
    try writer.writeAll("Pin-check and force-erase operation options are parsed for dry-run compatibility but are not wired for --execute yet.\n");
    return true;
}

const Parameter = struct {
    name: []const u8,
    value: u8,
};

const tl866a_vpp_voltages = [_]Parameter{ .{ .name = "10", .value = 0x40 }, .{ .name = "12.5", .value = 0x00 }, .{ .name = "13.5", .value = 0x30 }, .{ .name = "14", .value = 0x50 }, .{ .name = "16", .value = 0x10 }, .{ .name = "17", .value = 0x70 }, .{ .name = "18", .value = 0x60 }, .{ .name = "21", .value = 0x20 } };
const tl866a_vcc_voltages = [_]Parameter{ .{ .name = "3.3", .value = 0x02 }, .{ .name = "4", .value = 0x01 }, .{ .name = "4.5", .value = 0x05 }, .{ .name = "5", .value = 0x00 }, .{ .name = "5.5", .value = 0x04 }, .{ .name = "6.5", .value = 0x03 } };
const tl866ii_vpp_voltages = [_]Parameter{ .{ .name = "9", .value = 0x10 }, .{ .name = "9.5", .value = 0x20 }, .{ .name = "10", .value = 0x30 }, .{ .name = "11", .value = 0x40 }, .{ .name = "11.5", .value = 0x50 }, .{ .name = "12", .value = 0x00 }, .{ .name = "12.5", .value = 0x60 }, .{ .name = "13", .value = 0x70 }, .{ .name = "13.5", .value = 0x80 }, .{ .name = "14", .value = 0x90 }, .{ .name = "14.5", .value = 0xa0 }, .{ .name = "15.5", .value = 0xb0 }, .{ .name = "16", .value = 0xc0 }, .{ .name = "16.5", .value = 0xd0 }, .{ .name = "17", .value = 0xe0 }, .{ .name = "18", .value = 0xf0 } };
const tl866ii_vcc_voltages = [_]Parameter{ .{ .name = "3.3", .value = 0x01 }, .{ .name = "4", .value = 0x02 }, .{ .name = "4.5", .value = 0x03 }, .{ .name = "5", .value = 0x00 }, .{ .name = "5.5", .value = 0x04 }, .{ .name = "6.5", .value = 0x05 } };
const xg_vpp_voltages = [_]Parameter{ .{ .name = "9", .value = 0x10 }, .{ .name = "9.5", .value = 0x20 }, .{ .name = "10", .value = 0x30 }, .{ .name = "11", .value = 0x40 }, .{ .name = "11.5", .value = 0x50 }, .{ .name = "12", .value = 0x00 }, .{ .name = "12.5", .value = 0x60 }, .{ .name = "13", .value = 0x70 }, .{ .name = "13.5", .value = 0x80 }, .{ .name = "14", .value = 0x90 }, .{ .name = "14.5", .value = 0xa0 }, .{ .name = "15.5", .value = 0xb0 }, .{ .name = "16", .value = 0xc0 }, .{ .name = "16.5", .value = 0xd0 }, .{ .name = "17", .value = 0xe0 }, .{ .name = "18", .value = 0xf0 }, .{ .name = "21", .value = 0xf2 }, .{ .name = "25", .value = 0xf1 } };
const xg_pld_vpp_voltages = [_]Parameter{ .{ .name = "9", .value = 0x10 }, .{ .name = "9.5", .value = 0x20 }, .{ .name = "10", .value = 0x30 }, .{ .name = "11", .value = 0x40 }, .{ .name = "11.5", .value = 0x50 }, .{ .name = "12", .value = 0x00 }, .{ .name = "12.5", .value = 0x60 }, .{ .name = "13", .value = 0x70 }, .{ .name = "13.5", .value = 0x80 }, .{ .name = "14", .value = 0x90 }, .{ .name = "14.5", .value = 0xa0 }, .{ .name = "15.5", .value = 0xb0 }, .{ .name = "16", .value = 0xc0 }, .{ .name = "16.5", .value = 0xd0 }, .{ .name = "17", .value = 0xe0 }, .{ .name = "18", .value = 0xf0 } };
const xg_vcc_voltages = [_]Parameter{ .{ .name = "1.2", .value = 0x09 }, .{ .name = "1.8", .value = 0x06 }, .{ .name = "2.5", .value = 0x07 }, .{ .name = "3", .value = 0x08 }, .{ .name = "3.3", .value = 0x01 }, .{ .name = "4", .value = 0x02 }, .{ .name = "4.5", .value = 0x03 }, .{ .name = "4.75", .value = 0x0a }, .{ .name = "5", .value = 0x00 }, .{ .name = "5.25", .value = 0x0b }, .{ .name = "5.5", .value = 0x04 }, .{ .name = "5.75", .value = 0x0c }, .{ .name = "6", .value = 0x0d }, .{ .name = "6.25", .value = 0x0e }, .{ .name = "6.5", .value = 0x05 } };
const t48_spi_clock = [_]Parameter{ .{ .name = "4", .value = 0x00 }, .{ .name = "8", .value = 0x01 }, .{ .name = "15", .value = 0x02 }, .{ .name = "30", .value = 0x03 } };
const t56_spi_clock = [_]Parameter{ .{ .name = "8", .value = 0x00 }, .{ .name = "16", .value = 0x01 }, .{ .name = "25", .value = 0x02 }, .{ .name = "50", .value = 0x03 } };
const t76_spi_clock_1 = [_]Parameter{ .{ .name = "4", .value = 0x00 }, .{ .name = "8", .value = 0x01 }, .{ .name = "16", .value = 0x02 }, .{ .name = "24", .value = 0x03 }, .{ .name = "30", .value = 0x04 }, .{ .name = "40", .value = 0x05 }, .{ .name = "50", .value = 0x06 }, .{ .name = "60", .value = 0x07 } };
const t76_spi_clock_2 = [_]Parameter{ .{ .name = "0.5", .value = 0x00 }, .{ .name = "1", .value = 0x01 }, .{ .name = "2", .value = 0x02 } };

fn descriptorForOperation(device: sqlite.ProtocolDevice, programmer: model.Programmer, options: OperationOptions) !t48.Device {
    var descriptor = t48.deviceFromProtocolInfo(device, 0, defaultSpiClock(programmer, device.protocol_id));
    descriptor.can_adjust_clock = canAdjustClock(programmer, device.protocol_id);
    descriptor.can_adjust_address = canAdjustAddress(programmer, device.protocol_id);
    descriptor.i2c_address = 0xa0;

    var voltages = model.decodeVoltages(device.voltages_raw);
    if (options.pulse) |value| descriptor.pulse_delay = try parseBoundedU32(value, 0xffff);
    if (options.vpp) |value| voltages.vpp = try parameterValue(vppTable(programmer, device), value);
    if (options.vdd) |value| voltages.vdd = try parameterValue(vccTable(programmer), value);
    if (options.vcc) |value| voltages.vcc = try parameterValue(vccTable(programmer), value);
    descriptor.voltages_raw = model.encodeVoltages(voltages);

    if (options.spi_clock) |value| {
        if (descriptor.can_adjust_clock) descriptor.spi_clock = try parameterValue(spiClockTable(programmer, device.protocol_id) orelse return error.InvalidOperationValue, value);
    }
    if (options.address) |value| {
        if (descriptor.can_adjust_address) descriptor.i2c_address = @intCast(try parseBoundedU32(value, 0xff));
    }
    return descriptor;
}

fn parameterValue(table: []const Parameter, name: []const u8) !u8 {
    for (table) |entry| {
        if (std.ascii.eqlIgnoreCase(entry.name, name)) return entry.value;
    }
    return error.InvalidOperationValue;
}

fn parseBoundedU32(text: []const u8, max: u32) !u32 {
    const value = try parseIntAuto(text);
    if (value > max) return error.InvalidOperationValue;
    return value;
}

fn parseIntAuto(text: []const u8) !u32 {
    if (text.len == 0) return error.InvalidOperationValue;
    if (std.mem.startsWith(u8, text, "0x") or std.mem.startsWith(u8, text, "0X")) return std.fmt.parseInt(u32, text[2..], 16) catch error.InvalidOperationValue;
    return std.fmt.parseInt(u32, text, 10) catch error.InvalidOperationValue;
}

fn vppTable(programmer: model.Programmer, device: sqlite.ProtocolDevice) []const Parameter {
    return switch (programmer) {
        .tl866a => &tl866a_vpp_voltages,
        .tl866ii => &tl866ii_vpp_voltages,
        .t76 => if (device.chip_type == @intFromEnum(model.ChipType.pld)) &xg_pld_vpp_voltages else &xg_vpp_voltages,
        .t48, .t56 => &xg_vpp_voltages,
        else => &tl866ii_vpp_voltages,
    };
}

fn vccTable(programmer: model.Programmer) []const Parameter {
    return switch (programmer) {
        .tl866a => &tl866a_vcc_voltages,
        .tl866ii => &tl866ii_vcc_voltages,
        .t48, .t56, .t76 => &xg_vcc_voltages,
        else => &tl866ii_vcc_voltages,
    };
}

fn spiClockTable(programmer: model.Programmer, protocol_id: u8) ?[]const Parameter {
    if (!canAdjustClock(programmer, protocol_id)) return null;
    return switch (programmer) {
        .t48 => &t48_spi_clock,
        .t56 => &t56_spi_clock,
        .t76 => if (protocol_id == 0x03) &t76_spi_clock_1 else &t76_spi_clock_2,
        else => null,
    };
}

fn defaultSpiClock(programmer: model.Programmer, protocol_id: u8) u8 {
    return switch (programmer) {
        .t48 => 0x01,
        .t56 => 0x01,
        .t76 => if (protocol_id == 0x03) 0x02 else 0x01,
        else => 0,
    };
}

fn canAdjustClock(programmer: model.Programmer, protocol_id: u8) bool {
    return switch (programmer) {
        .t48, .t56, .t76 => protocol_id == 0x03 or protocol_id == 0x04 or protocol_id == 0x0f,
        else => false,
    };
}

fn canAdjustAddress(programmer: model.Programmer, protocol_id: u8) bool {
    return programmer == .t76 and protocol_id == 0x01;
}

fn rejectInvalidIdCheckSkip(writer: anytype, options: OperationOptions) !bool {
    if (!options.idcheck_skip) return false;
    try writer.writeAll("Skipping the ID check is not permitted for this action.\n");
    return true;
}

fn ensureExecutedProgrammer(programmer: model.Programmer) !void {
    switch (programmer) {
        .t48, .tl866ii, .t56, .t76 => {},
        else => return error.UnsupportedProgrammer,
    }
}

fn beginProtocol(allocator: std.mem.Allocator, opts: GlobalOptions, programmer: model.Programmer, trans: anytype, descriptor: t48.Device, device: sqlite.ProtocolDevice) !?[]u8 {
    const bitstream = try loadAlgorithmBitstream(allocator, opts, programmer, device);
    errdefer if (bitstream) |bytes| allocator.free(bytes);
    return switch (programmer) {
        .t48 => {
            try t48.beginTransaction(trans, descriptor);
            return null;
        },
        .tl866ii => {
            try tl866ii.beginTransaction(trans, descriptor);
            return null;
        },
        .t56 => {
            try t56.beginTransaction(trans, descriptor, bitstream orelse return error.AlgorithmUnavailable);
            return bitstream;
        },
        .t76 => {
            try t76.beginTransaction(trans, descriptor, bitstream orelse return error.AlgorithmUnavailable);
            return bitstream;
        },
        else => error.UnsupportedProgrammer,
    };
}

fn endProtocol(programmer: model.Programmer, trans: anytype) void {
    switch (programmer) {
        .t48 => t48.endTransaction(trans) catch {},
        .tl866ii => tl866ii.endTransaction(trans) catch {},
        else => {},
    }
}

fn readBlockProtocol(programmer: model.Programmer, trans: anytype, kind: model.MemoryKind, address: u32, out: []u8) !void {
    return switch (programmer) {
        .t48 => t48.readBlock(trans, kind, address, out),
        .tl866ii => tl866ii.readBlock(trans, kind, address, out),
        .t56 => t56.readBlock(trans, kind, address, out),
        .t76 => t76.readBlock(trans, kind, address, out),
        else => error.UnsupportedProgrammer,
    };
}

fn writeBlockProtocol(programmer: model.Programmer, trans: anytype, descriptor: t48.Device, kind: model.MemoryKind, address: u32, data: []const u8) !void {
    return switch (programmer) {
        .t48 => t48.writeBlock(trans, kind, address, data),
        .tl866ii => tl866ii.writeBlock(trans, descriptor, kind, address, data),
        .t56 => t56.writeBlock(trans, descriptor, kind, address, data),
        .t76 => t76.writeBlock(trans, kind, address, data),
        else => error.UnsupportedProgrammer,
    };
}

fn getChipIdProtocol(programmer: model.Programmer, trans: anytype, chip_id_bytes_count: u8) !t48.ChipId {
    return switch (programmer) {
        .t48 => t48.getChipId(trans, chip_id_bytes_count),
        .tl866ii => tl866ii.getChipId(trans, chip_id_bytes_count),
        .t56 => t56.getChipId(trans, chip_id_bytes_count),
        .t76 => t76.getChipId(trans, chip_id_bytes_count),
        else => error.UnsupportedProgrammer,
    };
}

fn eraseProtocol(programmer: model.Programmer, trans: anytype, num_fuses: u8, pld: u8) !void {
    return switch (programmer) {
        .t48 => t48.erase(trans, num_fuses, pld),
        .tl866ii => tl866ii.erase(trans, num_fuses, pld),
        .t56 => t56.erase(trans, num_fuses, pld),
        .t76 => t76.erase(trans, num_fuses, pld),
        else => error.UnsupportedProgrammer,
    };
}

fn protectOnProtocol(programmer: model.Programmer, trans: anytype) !void {
    return switch (programmer) {
        .t48 => t48.protectOn(trans),
        .tl866ii => tl866ii.protectOn(trans),
        .t56 => t56.protectOn(trans),
        .t76 => t76.protectOn(trans),
        else => error.UnsupportedProgrammer,
    };
}

fn protectOffProtocol(programmer: model.Programmer, trans: anytype) !void {
    return switch (programmer) {
        .t48 => t48.protectOff(trans),
        .tl866ii => tl866ii.protectOff(trans),
        .t56 => t56.protectOff(trans),
        .t76 => t76.protectOff(trans),
        else => error.UnsupportedProgrammer,
    };
}

fn requestStatusProtocol(programmer: model.Programmer, trans: anytype) !t48.Status {
    return switch (programmer) {
        .t48 => t48.requestStatus(trans),
        .tl866ii => tl866ii.requestStatus(trans),
        .t56 => t56.requestStatus(trans),
        .t76 => t76.requestStatus(trans),
        else => error.UnsupportedProgrammer,
    };
}

fn readFusesProtocol(programmer: model.Programmer, trans: anytype, descriptor: t48.Device, kind: t48.FuseKind, items_count: u8, out: []u8) !void {
    return switch (programmer) {
        .t48 => t48.readFuses(trans, descriptor, kind, items_count, out),
        .tl866ii => tl866ii.readFuses(trans, descriptor, kind, items_count, out),
        .t56 => t56.readFuses(trans, descriptor, kind, items_count, out),
        .t76 => t76.readFuses(trans, descriptor, kind, items_count, out),
        else => error.UnsupportedProgrammer,
    };
}

fn writeFusesProtocol(programmer: model.Programmer, trans: anytype, descriptor: t48.Device, kind: t48.FuseKind, items_count: u8, data: []const u8) !void {
    return switch (programmer) {
        .t48 => t48.writeFuses(trans, descriptor, kind, items_count, data),
        .tl866ii => tl866ii.writeFuses(trans, descriptor, kind, items_count, data),
        .t56 => t56.writeFuses(trans, descriptor, kind, items_count, data),
        .t76 => t76.writeFuses(trans, descriptor, kind, items_count, data),
        else => error.UnsupportedProgrammer,
    };
}

fn readJedecRowProtocol(programmer: model.Programmer, trans: anytype, descriptor: t48.Device, row: t48.JedecRow) !void {
    return switch (programmer) {
        .t48 => t48.readJedecRow(trans, descriptor, row),
        .tl866ii => tl866ii.readJedecRow(trans, descriptor, row),
        .t56 => t56.readJedecRow(trans, descriptor, row),
        .t76 => t76.readJedecRow(trans, row),
        else => error.UnsupportedProgrammer,
    };
}

fn writeJedecRowProtocol(programmer: model.Programmer, trans: anytype, descriptor: t48.Device, row: t48.JedecRow) !void {
    return switch (programmer) {
        .t48 => t48.writeJedecRow(trans, descriptor, row),
        .tl866ii => tl866ii.writeJedecRow(trans, descriptor, row),
        .t56 => t56.writeJedecRow(trans, descriptor, row),
        .t76 => t76.writeJedecRow(trans, row),
        else => error.UnsupportedProgrammer,
    };
}

fn spiAutodetectProtocol(programmer: model.Programmer, trans: anytype, package_pins: u8) !u32 {
    return switch (programmer) {
        .t48 => t48.spiAutodetect(trans, package_pins),
        .tl866ii => tl866ii.spiAutodetect(trans, package_pins),
        .t56 => t56.spiAutodetect(trans, package_pins),
        .t76 => t76.spiAutodetect(trans, package_pins),
        else => error.UnsupportedProgrammer,
    };
}

fn loadAlgorithmBitstream(allocator: std.mem.Allocator, opts: GlobalOptions, programmer: model.Programmer, device: sqlite.ProtocolDevice) !?[]u8 {
    switch (programmer) {
        .t56, .t76 => {},
        else => return null,
    }

    var name_buffer: [64]u8 = undefined;
    const flags = model.decodeFlags(device.flags_raw, device.voltages_raw, device.chip_info, device.protocol_id);
    const name = try algorithm_name.resolve(&name_buffer, .{
        .programmer = programmer,
        .protocol_id = device.protocol_id,
        .variant = device.variant,
        .reversed_package = flags.reversed_package,
    });

    var db = try sqlite.Database.open(databasePath(opts));
    defer db.close();
    const encoded = try db.algorithmBase64(allocator, programmer.name(), name) orelse return error.AlgorithmUnavailable;
    defer allocator.free(encoded);
    return try algorithm_payload.decode(allocator, programmer, encoded);
}

fn loadUtilityAlgorithmBitstream(allocator: std.mem.Allocator, opts: GlobalOptions, programmer: model.Programmer, algorithm_number: u8) ![]u8 {
    var name_buffer: [64]u8 = undefined;
    const name = try algorithm_name.resolve(&name_buffer, .{
        .programmer = programmer,
        .protocol_id = 0,
        .variant = @as(u32, algorithm_number) << 8,
    });
    var db = try sqlite.Database.open(databasePath(opts));
    defer db.close();
    const encoded = try db.algorithmBase64(allocator, programmer.name(), name) orelse return error.AlgorithmUnavailable;
    defer allocator.free(encoded);
    return try algorithm_payload.decode(allocator, programmer, encoded);
}

fn loadSpiAutodetectBitstream(allocator: std.mem.Allocator, opts: GlobalOptions, programmer: model.Programmer, package_pins: u8) ![]u8 {
    const algorithm_number: u8 = if (package_pins == 16) 0x21 else 0x11;
    var name_buffer: [64]u8 = undefined;
    const name = try algorithm_name.resolve(&name_buffer, .{
        .programmer = programmer,
        .protocol_id = 0x03,
        .variant = @as(u32, algorithm_number) << 8,
    });
    var db = try sqlite.Database.open(databasePath(opts));
    defer db.close();
    const encoded = try db.algorithmBase64(allocator, programmer.name(), name) orelse return error.AlgorithmUnavailable;
    defer allocator.free(encoded);
    return try algorithm_payload.decode(allocator, programmer, encoded);
}

fn executeChipRead(allocator: std.mem.Allocator, command: ChipRead, device: sqlite.ProtocolDevice) ![]u8 {
    const size = chipReadSize(command.memory, device);
    if (size == 0) return error.EmptyMemoryRegion;

    const usb_transport = try usb.UsbTransport.open(allocator);
    const programmer_session = session.Session.open(usb_transport.transport()) catch |err| {
        usb_transport.transport().close();
        return err;
    };
    defer programmer_session.close();

    try ensureExecutedProgrammer(programmer_session.info.programmer);

    var data = try allocator.alloc(u8, size);
    errdefer allocator.free(data);

    const descriptor = try descriptorForOperation(device, programmer_session.info.programmer, command.op_opts);
    const bitstream = try beginProtocol(allocator, command.opts, programmer_session.info.programmer, programmer_session.transport, descriptor, device);
    defer if (bitstream) |bytes| allocator.free(bytes);
    defer endProtocol(programmer_session.info.programmer, programmer_session.transport);

    if (!command.op_opts.idcheck_skip and device.chip_id != 0 and device.chip_id_bytes_count != 0) {
        const actual = try getChipIdProtocol(programmer_session.info.programmer, programmer_session.transport, device.chip_id_bytes_count);
        if (actual.value != device.chip_id and !command.op_opts.idcheck_continue) return error.ChipIdMismatch;
    }

    var offset: usize = 0;
    const chunk_size = @max(@as(usize, descriptor.read_buffer_size), 1);
    while (offset < data.len) {
        const len = @min(chunk_size, data.len - offset);
        try readBlockProtocol(programmer_session.info.programmer, programmer_session.transport, command.memory, @intCast(offset), data[offset .. offset + len]);
        offset += len;
    }
    return data;
}

fn executeChipFuseRead(allocator: std.mem.Allocator, opts: GlobalOptions, op_opts: OperationOptions, device: sqlite.ProtocolDevice, fuse_items: sqlite.ConfigItems, lock_items: sqlite.ConfigItems) ![]u8 {
    const usb_transport = try usb.UsbTransport.open(allocator);
    const programmer_session = session.Session.open(usb_transport.transport()) catch |err| {
        usb_transport.transport().close();
        return err;
    };
    defer programmer_session.close();

    try ensureExecutedProgrammer(programmer_session.info.programmer);

    const descriptor = try descriptorForOperation(device, programmer_session.info.programmer, op_opts);
    const word_size = descriptorWordSize(device);
    const bitstream = try beginProtocol(allocator, opts, programmer_session.info.programmer, programmer_session.transport, descriptor, device);
    defer if (bitstream) |bytes| allocator.free(bytes);
    defer endProtocol(programmer_session.info.programmer, programmer_session.transport);

    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    if (fuse_items.items.len != 0) {
        const bytes = try allocator.alloc(u8, fuse_items.items.len * word_size);
        defer allocator.free(bytes);
        try readFusesProtocol(programmer_session.info.programmer, programmer_session.transport, descriptor, .config, @intCast(fuse_items.items.len), bytes);
        normalizeFuseBytes(bytes, fuse_items.items, word_size, device.compare_mask, true);
        try writeFuseValues(&output.writer, bytes, fuse_items.items, word_size);
    }
    if (lock_items.items.len != 0) {
        const flags = model.decodeFlags(device.flags_raw, device.voltages_raw, device.chip_info, device.protocol_id);
        if (flags.lock_bit_write_only) return error.LockBitsWriteOnly;
        const bytes = try allocator.alloc(u8, lock_items.items.len * word_size);
        defer allocator.free(bytes);
        try readFusesProtocol(programmer_session.info.programmer, programmer_session.transport, descriptor, .lock, word_size, bytes);
        normalizeFuseBytes(bytes, lock_items.items, word_size, device.compare_mask, false);
        try writeFuseValues(&output.writer, bytes, lock_items.items, word_size);
    }
    return try output.toOwnedSlice();
}

fn writeFuseValues(writer: anytype, bytes: []const u8, items: []const fuses.ConfigItem, word_size: u8) !void {
    for (items, 0..) |item, index| {
        const start = index * word_size;
        const value = endian.loadInt(bytes[start..][0..word_size], .little);
        if (word_size == 1) {
            try writer.print("{s}=0x{x:0>2}\n", .{ item.name, value });
        } else {
            try writer.print("{s}=0x{x:0>4}\n", .{ item.name, value });
        }
    }
}

fn executeChipReadId(allocator: std.mem.Allocator, opts: GlobalOptions, op_opts: OperationOptions, device: sqlite.ProtocolDevice) !t48.ChipId {
    const usb_transport = try usb.UsbTransport.open(allocator);
    const programmer_session = session.Session.open(usb_transport.transport()) catch |err| {
        usb_transport.transport().close();
        return err;
    };
    defer programmer_session.close();

    try ensureExecutedProgrammer(programmer_session.info.programmer);

    const descriptor = try descriptorForOperation(device, programmer_session.info.programmer, op_opts);
    const bitstream = try beginProtocol(allocator, opts, programmer_session.info.programmer, programmer_session.transport, descriptor, device);
    defer if (bitstream) |bytes| allocator.free(bytes);
    defer endProtocol(programmer_session.info.programmer, programmer_session.transport);
    return try getChipIdProtocol(programmer_session.info.programmer, programmer_session.transport, device.chip_id_bytes_count);
}

fn executeChipAutodetect(allocator: std.mem.Allocator, opts: GlobalOptions, package_pins: u8) !u32 {
    const usb_transport = try usb.UsbTransport.open(allocator);
    const programmer_session = session.Session.open(usb_transport.transport()) catch |err| {
        usb_transport.transport().close();
        return err;
    };
    defer programmer_session.close();
    try ensureExecutedProgrammer(programmer_session.info.programmer);
    if (opts.programmer != .auto and opts.programmer != programmer_session.info.programmer) return error.ProgrammerMismatch;
    switch (programmer_session.info.programmer) {
        .t56 => {
            const bitstream = try loadSpiAutodetectBitstream(allocator, opts, .t56, package_pins);
            defer allocator.free(bitstream);
            try t56.uploadBitstream(programmer_session.transport, bitstream);
        },
        .t76 => {
            const bitstream = try loadSpiAutodetectBitstream(allocator, opts, .t76, package_pins);
            defer allocator.free(bitstream);
            try t76.uploadBitstream(programmer_session.transport, bitstream);
        },
        else => {},
    }
    return try spiAutodetectProtocol(programmer_session.info.programmer, programmer_session.transport, package_pins);
}

fn executeChipBlank(allocator: std.mem.Allocator, command: ChipBlank, device: sqlite.ProtocolDevice) !bool {
    const read_command = ChipRead{
        .opts = command.opts,
        .device = command.device,
        .out = "",
        .memory = command.memory,
        .op_opts = command.op_opts,
        .execute = true,
    };
    const bytes = try executeChipRead(allocator, read_command, device);
    defer allocator.free(bytes);
    const blank: u8 = @truncate(device.blank_value);
    for (bytes) |byte| {
        if (byte != blank) return false;
    }
    return true;
}

fn executeChipPinCheck(allocator: std.mem.Allocator, opts: GlobalOptions, device: sqlite.ProtocolDevice, pin_map: sqlite.PinMap) ![]u8 {
    const usb_transport = try usb.UsbTransport.open(allocator);
    const programmer_session = session.Session.open(usb_transport.transport()) catch |err| {
        usb_transport.transport().close();
        return err;
    };
    defer programmer_session.close();

    if (opts.programmer != .auto and opts.programmer != programmer_session.info.programmer) return error.ProgrammerMismatch;
    // Upstream T76 has a pin-test hook, but its visible code ignores the
    // firmware response and reports every mapped pin as bad. Keep execute
    // limited to the TL866II path until the T76 response format is verified.
    if (programmer_session.info.programmer != .tl866ii) return error.UnsupportedProgrammer;

    const descriptor = t48.deviceFromProtocolInfo(device, 0, 0);
    try tl866ii.beginTransaction(programmer_session.transport, descriptor);
    const package = model.decodePackageDetails(device.package_details_raw);
    return try tl866ii.pinContactTest(allocator, programmer_session.transport, .{ .gnd_pins = pin_map.gnd_pins, .masks = pin_map.masks }, @intCast(package.pin_count));
}

fn executeChipProtect(allocator: std.mem.Allocator, command: ChipProtect, device: sqlite.ProtocolDevice) !void {
    const usb_transport = try usb.UsbTransport.open(allocator);
    const programmer_session = session.Session.open(usb_transport.transport()) catch |err| {
        usb_transport.transport().close();
        return err;
    };
    defer programmer_session.close();

    try ensureExecutedProgrammer(programmer_session.info.programmer);

    const descriptor = try descriptorForOperation(device, programmer_session.info.programmer, command.op_opts);
    const bitstream = try beginProtocol(allocator, command.opts, programmer_session.info.programmer, programmer_session.transport, descriptor, device);
    defer if (bitstream) |bytes| allocator.free(bytes);
    defer endProtocol(programmer_session.info.programmer, programmer_session.transport);
    if (command.enable) {
        try protectOnProtocol(programmer_session.info.programmer, programmer_session.transport);
    } else {
        try protectOffProtocol(programmer_session.info.programmer, programmer_session.transport);
    }
}

fn executeChipVerify(allocator: std.mem.Allocator, command: ChipVerify, device: sqlite.ProtocolDevice, input: image.MemoryImage) !?usize {
    const read_command = ChipRead{
        .opts = command.opts,
        .device = command.device,
        .out = command.input,
        .format = command.format,
        .memory = command.memory,
        .op_opts = command.op_opts,
        .execute = true,
    };
    const device_size = chipReadSize(command.memory, device);
    if (input.data.len > device_size) return 0;
    const actual = try executeChipRead(allocator, read_command, device);
    defer allocator.free(actual);
    for (input.data, 0..) |expected, index| {
        if (actual[index] != expected) return index;
    }
    return null;
}

const FuseMismatch = struct {
    section: []const u8,
    index: usize,
};

fn executeChipFuseVerify(allocator: std.mem.Allocator, opts: GlobalOptions, op_opts: OperationOptions, device: sqlite.ProtocolDevice, plan: FusePlan) !?FuseMismatch {
    const usb_transport = try usb.UsbTransport.open(allocator);
    const programmer_session = session.Session.open(usb_transport.transport()) catch |err| {
        usb_transport.transport().close();
        return err;
    };
    defer programmer_session.close();

    try ensureExecutedProgrammer(programmer_session.info.programmer);

    const descriptor = try descriptorForOperation(device, programmer_session.info.programmer, op_opts);
    const bitstream = try beginProtocol(allocator, opts, programmer_session.info.programmer, programmer_session.transport, descriptor, device);
    defer if (bitstream) |bytes| allocator.free(bytes);
    defer endProtocol(programmer_session.info.programmer, programmer_session.transport);

    return try verifyFusePlanWithTransport(allocator, programmer_session.info.programmer, programmer_session.transport, descriptor, device, plan);
}

fn executeChipFuseWrite(allocator: std.mem.Allocator, opts: GlobalOptions, op_opts: OperationOptions, device: sqlite.ProtocolDevice, plan: FusePlan) !void {
    const usb_transport = try usb.UsbTransport.open(allocator);
    const programmer_session = session.Session.open(usb_transport.transport()) catch |err| {
        usb_transport.transport().close();
        return err;
    };
    defer programmer_session.close();

    try ensureExecutedProgrammer(programmer_session.info.programmer);

    const descriptor = try descriptorForOperation(device, programmer_session.info.programmer, op_opts);
    const bitstream = try beginProtocol(allocator, opts, programmer_session.info.programmer, programmer_session.transport, descriptor, device);
    defer if (bitstream) |bytes| allocator.free(bytes);
    defer endProtocol(programmer_session.info.programmer, programmer_session.transport);

    if (plan.fuse_bytes.len != 0) {
        try writeFusesProtocol(programmer_session.info.programmer, programmer_session.transport, descriptor, .config, @intCast(plan.fuse_items.items.len), plan.fuse_bytes);
    }
    if (plan.lock_bytes.len != 0) {
        try writeFusesProtocol(programmer_session.info.programmer, programmer_session.transport, descriptor, .lock, descriptorWordSize(device), plan.lock_bytes);
    }

    if (try verifyFusePlanWithTransport(allocator, programmer_session.info.programmer, programmer_session.transport, descriptor, device, plan)) |mismatch| {
        _ = mismatch;
        return error.FuseVerifyFailed;
    }
}

fn executeChipJedecVerify(allocator: std.mem.Allocator, opts: GlobalOptions, op_opts: OperationOptions, device: sqlite.ProtocolDevice, gal: sqlite.GalConfig, expected: []const u8) !?usize {
    const actual = try executeChipJedecRead(allocator, opts, op_opts, device, gal, expected.len);
    defer allocator.free(actual);
    for (expected, 0..) |fuse, index| {
        if (actual[index] != fuse) return index;
    }
    return null;
}

fn executeChipJedecRead(allocator: std.mem.Allocator, opts: GlobalOptions, op_opts: OperationOptions, device: sqlite.ProtocolDevice, gal: sqlite.GalConfig, fuse_count: usize) ![]u8 {
    const usb_transport = try usb.UsbTransport.open(allocator);
    const programmer_session = session.Session.open(usb_transport.transport()) catch |err| {
        usb_transport.transport().close();
        return err;
    };
    defer programmer_session.close();

    try ensureExecutedProgrammer(programmer_session.info.programmer);

    const descriptor = try descriptorForOperation(device, programmer_session.info.programmer, op_opts);
    const bitstream = try beginProtocol(allocator, opts, programmer_session.info.programmer, programmer_session.transport, descriptor, device);
    defer if (bitstream) |bytes| allocator.free(bytes);
    defer endProtocol(programmer_session.info.programmer, programmer_session.transport);

    var fuses_data = try allocator.alloc(u8, fuse_count);
    errdefer allocator.free(fuses_data);
    @memset(fuses_data, 0);
    var row_data = [_]u8{0} ** 32;
    for (0..gal.fuses_size) |row| {
        try readJedecRowProtocol(programmer_session.info.programmer, programmer_session.transport, descriptor, .{ .data = &row_data, .size_bits = gal.row_width, .row = @intCast(row), .flags = 0, .row_type = 2 });
        try gal_core.unpackFuseRow(fuses_data, &row_data, gal.fuses_size, gal.row_width, row);
    }
    if (gal.ues_address != 0 and gal.ues_size != 0 and @as(usize, gal.ues_address) + gal.ues_size <= fuses_data.len) {
        try readJedecRowProtocol(programmer_session.info.programmer, programmer_session.transport, descriptor, .{ .data = &row_data, .size_bits = gal.ues_size, .row = 0, .flags = 0, .row_type = 1 });
        for (0..gal.ues_size) |index| {
            fuses_data[@as(usize, gal.ues_address) + index] = if (row_data[index / 8] & (@as(u8, 0x80) >> @intCast(index & 0x07)) != 0) 1 else 0;
        }
    }
    try readJedecRowProtocol(programmer_session.info.programmer, programmer_session.transport, descriptor, .{ .data = &row_data, .size_bits = @intCast(gal.acw_bits.len), .row = gal.acw_address, .flags = gal.acw_address, .row_type = 2 });
    try gal_core.unpackIndexedBits(fuses_data, &row_data, gal.acw_bits, gal.acw_bits.len);
    const flags = model.decodeFlags(device.flags_raw, device.voltages_raw, device.chip_info, device.protocol_id);
    if (gal.powerdown_row != 0 and flags.has_power_down and fuses_data.len != 0) {
        try readJedecRowProtocol(programmer_session.info.programmer, programmer_session.transport, descriptor, .{ .data = &row_data, .size_bits = 1, .row = gal.powerdown_row, .flags = 0, .row_type = 2 });
        fuses_data[fuses_data.len - 1] = (row_data[0] >> 7) & 0x01;
    }
    return fuses_data;
}

fn executeChipJedecWrite(allocator: std.mem.Allocator, opts: GlobalOptions, op_opts: OperationOptions, device: sqlite.ProtocolDevice, gal: sqlite.GalConfig, fuses_data: []const u8) !void {
    const usb_transport = try usb.UsbTransport.open(allocator);
    const programmer_session = session.Session.open(usb_transport.transport()) catch |err| {
        usb_transport.transport().close();
        return err;
    };
    defer programmer_session.close();

    try ensureExecutedProgrammer(programmer_session.info.programmer);

    const descriptor = try descriptorForOperation(device, programmer_session.info.programmer, op_opts);
    const first_bitstream = try beginProtocol(allocator, opts, programmer_session.info.programmer, programmer_session.transport, descriptor, device);
    defer if (first_bitstream) |bytes| allocator.free(bytes);
    errdefer endProtocol(programmer_session.info.programmer, programmer_session.transport);
    try eraseProtocol(programmer_session.info.programmer, programmer_session.transport, 0, if (device.protocol_id == 0x2c) 0x3d else 0x3f);
    endProtocol(programmer_session.info.programmer, programmer_session.transport);
    const second_bitstream = try beginProtocol(allocator, opts, programmer_session.info.programmer, programmer_session.transport, descriptor, device);
    defer if (second_bitstream) |bytes| allocator.free(bytes);
    defer endProtocol(programmer_session.info.programmer, programmer_session.transport);

    var row_data = [_]u8{0} ** 32;
    for (0..gal.fuses_size) |row| {
        const row_bytes = try gal_core.packFuseRow(&row_data, fuses_data, gal.fuses_size, gal.row_width, row);
        try writeJedecRowProtocol(programmer_session.info.programmer, programmer_session.transport, descriptor, .{ .data = row_bytes, .size_bits = gal.row_width, .row = @intCast(row), .flags = 0, .row_type = 0 });
    }

    @memset(&row_data, 0);
    if (gal.ues_address != 0 and gal.ues_size != 0 and @as(usize, gal.ues_address) + gal.ues_size <= fuses_data.len) {
        for (0..gal.ues_size) |index| {
            if (fuses_data[@as(usize, gal.ues_address) + index] == 1) row_data[index / 8] |= @as(u8, 0x80) >> @intCast(index & 0x07);
        }
    }
    try writeJedecRowProtocol(programmer_session.info.programmer, programmer_session.transport, descriptor, .{ .data = &row_data, .size_bits = gal.ues_size, .row = 0, .flags = 0, .row_type = 0 });

    const acw = try gal_core.packIndexedBits(&row_data, fuses_data, gal.acw_bits, gal.acw_bits.len);
    try writeJedecRowProtocol(programmer_session.info.programmer, programmer_session.transport, descriptor, .{ .data = acw, .size_bits = @intCast(gal.acw_bits.len), .row = gal.acw_address, .flags = gal.acw_address, .row_type = 2 });

    const flags = model.decodeFlags(device.flags_raw, device.voltages_raw, device.chip_info, device.protocol_id);
    if (gal.powerdown_row != 0 and ((flags.has_power_down and fuses_data.len != 0 and fuses_data[fuses_data.len - 1] == 0) or flags.is_powerdown_disabled)) {
        row_data[0] = 0;
        try writeJedecRowProtocol(programmer_session.info.programmer, programmer_session.transport, descriptor, .{ .data = row_data[0..1], .size_bits = 1, .row = gal.powerdown_row, .flags = 0, .row_type = 2 });
    }
}

fn verifyFusePlanWithTransport(allocator: std.mem.Allocator, programmer: model.Programmer, trans: anytype, descriptor: t48.Device, device: sqlite.ProtocolDevice, plan: FusePlan) !?FuseMismatch {
    const word_size = descriptorWordSize(device);
    if (plan.fuse_bytes.len != 0) {
        const actual = try allocator.alloc(u8, plan.fuse_bytes.len);
        defer allocator.free(actual);
        try readFusesProtocol(programmer, trans, descriptor, .config, @intCast(plan.fuse_items.items.len), actual);
        normalizeFuseBytes(actual, plan.fuse_items.items, word_size, device.compare_mask, true);
        if (firstMismatch(plan.fuse_bytes, actual)) |index| return .{ .section = "config", .index = index / word_size };
    }

    if (plan.lock_bytes.len != 0) {
        const flags = model.decodeFlags(device.flags_raw, device.voltages_raw, device.chip_info, device.protocol_id);
        if (!flags.lock_bit_write_only) {
            const actual = try allocator.alloc(u8, plan.lock_bytes.len);
            defer allocator.free(actual);
            try readFusesProtocol(programmer, trans, descriptor, .lock, word_size, actual);
            normalizeFuseBytes(actual, plan.lock_items.items, word_size, device.compare_mask, false);
            if (firstMismatch(plan.lock_bytes, actual)) |index| return .{ .section = "lock", .index = index / word_size };
        }
    }
    return null;
}

fn normalizeFuseBytes(bytes: []u8, items: []const fuses.ConfigItem, word_size: u8, compare_mask: u16, apply_compare_mask: bool) void {
    for (items, 0..) |item, index| {
        const start = index * word_size;
        const value: u16 = @intCast(endian.loadInt(bytes[start..][0..word_size], .little));
        endian.storeInt(bytes[start..][0..word_size], fuses.normalizeValue(value, item.mask, .{ .word_size = word_size, .compare_mask = compare_mask, .apply_compare_mask = apply_compare_mask }), .little);
    }
}

fn firstMismatch(expected: []const u8, actual: []const u8) ?usize {
    for (expected, 0..) |byte, index| {
        if (actual[index] != byte) return index;
    }
    return null;
}

fn descriptorWordSize(device: sqlite.ProtocolDevice) u8 {
    return model.decodeFlags(device.flags_raw, device.voltages_raw, device.chip_info, device.protocol_id).word_size;
}

fn executeChipErase(allocator: std.mem.Allocator, opts: GlobalOptions, op_opts: OperationOptions, device: sqlite.ProtocolDevice) !void {
    const usb_transport = try usb.UsbTransport.open(allocator);
    const programmer_session = session.Session.open(usb_transport.transport()) catch |err| {
        usb_transport.transport().close();
        return err;
    };
    defer programmer_session.close();

    try ensureExecutedProgrammer(programmer_session.info.programmer);

    const descriptor = try descriptorForOperation(device, programmer_session.info.programmer, op_opts);
    const bitstream = try beginProtocol(allocator, opts, programmer_session.info.programmer, programmer_session.transport, descriptor, device);
    defer if (bitstream) |bytes| allocator.free(bytes);
    defer endProtocol(programmer_session.info.programmer, programmer_session.transport);
    try eraseProtocol(programmer_session.info.programmer, programmer_session.transport, 0, 0);
}

fn executeChipWrite(allocator: std.mem.Allocator, command: ChipWrite, device: sqlite.ProtocolDevice, input: image.MemoryImage) !void {
    const size = chipReadSize(command.memory, device);
    if (input.data.len > size) return error.InputTooLarge;
    if (size == 0) return error.EmptyMemoryRegion;

    const usb_transport = try usb.UsbTransport.open(allocator);
    const programmer_session = session.Session.open(usb_transport.transport()) catch |err| {
        usb_transport.transport().close();
        return err;
    };
    defer programmer_session.close();

    try ensureExecutedProgrammer(programmer_session.info.programmer);

    const descriptor = try descriptorForOperation(device, programmer_session.info.programmer, command.op_opts);
    var protocol_open = false;
    defer if (protocol_open) endProtocol(programmer_session.info.programmer, programmer_session.transport);
    const first_bitstream = try beginProtocol(allocator, command.opts, programmer_session.info.programmer, programmer_session.transport, descriptor, device);
    protocol_open = true;
    defer if (first_bitstream) |bytes| allocator.free(bytes);
    var second_bitstream: ?[]u8 = null;
    defer if (second_bitstream) |bytes| allocator.free(bytes);

    if (!command.op_opts.idcheck_skip and device.chip_id != 0 and device.chip_id_bytes_count != 0) {
        const actual = try getChipIdProtocol(programmer_session.info.programmer, programmer_session.transport, device.chip_id_bytes_count);
        if (actual.value != device.chip_id and !command.op_opts.idcheck_continue) return error.ChipIdMismatch;
    }

    if (!command.op_opts.no_erase) {
        try eraseProtocol(programmer_session.info.programmer, programmer_session.transport, 0, 0);
        endProtocol(programmer_session.info.programmer, programmer_session.transport);
        protocol_open = false;
        second_bitstream = try beginProtocol(allocator, command.opts, programmer_session.info.programmer, programmer_session.transport, descriptor, device);
        protocol_open = true;
    }

    if (command.unprotect_before) try protectOffProtocol(programmer_session.info.programmer, programmer_session.transport);

    var offset: usize = 0;
    const chunk_size = @max(@as(usize, descriptor.write_buffer_size), 1);
    while (offset < input.data.len) {
        const len = @min(chunk_size, input.data.len - offset);
        try writeBlockProtocol(programmer_session.info.programmer, programmer_session.transport, descriptor, command.memory, @intCast(offset), input.data[offset .. offset + len]);
        const status = try requestStatusProtocol(programmer_session.info.programmer, programmer_session.transport);
        if (status.overcurrent != 0) return error.Overcurrent;
        if (status.error_code != 0) return error.ProgrammerStatusError;
        offset += len;
    }
    if (command.protect_after) try protectOnProtocol(programmer_session.info.programmer, programmer_session.transport);
}

fn writeChipReadOutput(allocator: std.mem.Allocator, io: std.Io, command: ChipRead, bytes: []const u8) !void {
    var memory = try image.MemoryImage.initCopy(allocator, bytes, .{ .kind = command.memory });
    defer memory.deinit();

    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    switch (command.format) {
        .bin => try bin.writeAll(&output.writer, memory),
        .ihex => try ihex.writeAll(&output.writer, memory, true),
        .srec => try srec.writeAll(&output.writer, memory, true),
        .jedec => return error.UnsupportedFormat,
        .config => return error.UnsupportedFormat,
    }
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = command.out, .data = output.writer.buffered() });
}

fn chipReadSize(memory: model.MemoryKind, device: sqlite.ProtocolDevice) usize {
    return switch (memory) {
        .code => device.code_memory_size,
        .data => device.data_memory_size,
        .user => device.data_memory2_size,
    };
}

fn memoryKindName(kind: model.MemoryKind) []const u8 {
    return switch (kind) {
        .code => "code",
        .data => "data",
        .user => "user",
    };
}

fn fileFormatName(format: FileFormat) []const u8 {
    return switch (format) {
        .bin => "bin",
        .ihex => "ihex",
        .srec => "srec",
        .jedec => "jedec",
        .config => "config",
    };
}

fn writeShortUsage(writer: anytype) !void {
    try writer.writeAll("Usage: minipro-zig [global-options] <command> [command-options]\n");
    try writer.writeAll("Try 'minipro-zig --help' for more information.\n");
}

fn writeLegacyShortHelp(writer: anytype) !void {
    try writer.print("minipro-zig version {s}     Zig port of the minipro CLI\n", .{version});
    try writer.writeAll("Usage: minipro-zig [options]\n");
    try writer.writeAll("See the manual page (type \"man minipro-zig\" for documentation)\n");
}

fn writeHelp(writer: anytype) !void {
    try writer.writeAll(
        \\minipro-zig - Zig port of the minipro CLI
        \\
        \\Usage:
        \\  minipro-zig [global-options] <command> [command-options]
        \\  minipro-zig -Q
        \\
        \\Global options:
        \\  --db <path>                 SQLite database path
        \\  --programmer, -q <model>    tl866a, tl866ii, t48, t56, t76, auto
        \\  --json                      Emit JSON where supported
        \\  --verbose
        \\  --quiet
        \\  --help, -h
        \\  --version, -V
        \\
        \\Commands:
        \\  programmer list             List supported programmer families
        \\  programmer detect           Detect a connected programmer
        \\  programmer info             Show connected programmer information
        \\  db import                   Import upstream XML chip databases
        \\    --infoic <path>           Required chip database XML
        \\    --logicic <path>          Optional logic IC database XML
        \\    --algorithms <path>       Optional T56/T76 algorithm XML
        \\    --out <path>              Output SQLite database
        \\  device list/search/info     Query imported chip databases
        \\  chip read                   Plan or execute a chip read
        \\  chip read-id                Plan or execute a chip ID read
        \\  chip autodetect             Plan or execute SPI chip autodetect
        \\  chip blank                  Plan or execute a blank check
        \\  chip verify                 Plan or execute a chip verify
        \\  chip erase                  Plan or execute a chip erase
        \\  chip write                  Plan or execute a chip write
        \\  chip protect/unprotect      Plan or execute protection change
        \\  --confirm-destructive <dev> Required with destructive --execute operations
        \\  logic test                  Plan a logic IC vector test
        \\
        \\Chip formats:
        \\  bin, ihex, srec              Code/data/user memory images
        \\  config                      MCU fuse config files (name=value)
        \\  jedec                       PLD/GAL JEDEC fuse files (execution not ported yet)
        \\
        \\Legacy aliases:
        \\  -Q, --query_supported       programmer list
        \\  -k, --presence_check        programmer detect
        \\  -p <dev> -r <file>          chip read --device <dev> --out <file>
        \\  -p <dev> -w <file>          chip write --device <dev> --in <file>
        \\  -p <dev> -m <file>          chip verify --device <dev> --in <file>
        \\  -p <dev> -E                 chip erase --device <dev>
        \\  -p <dev> -P                 chip protect --device <dev>
        \\  -p <dev> -u                 chip unprotect --device <dev>
        \\  -p <dev> -D                 chip read-id --device <dev>
        \\  -p <dev> -b                 chip blank --device <dev>
        \\  -p <dev> -T                 logic test --device <dev>
        \\  -a 8|16                     chip autodetect --package 8|16
        \\
    );
}

fn writeProgrammerList(writer: anytype) !void {
    try writer.writeAll(
        \\tl866a:  TL866CS/A
        \\tl866ii: TL866II+
        \\t48:     T48  (mostly complete)
        \\t56:     T56  (experimental)
        \\t76:     T76  (experimental)
        \\
    );
}

fn writeProgrammerListJson(writer: anytype) !void {
    try writer.writeAll("{\"programmers\":[");
    for (model.Programmer.supported, 0..) |programmer, index| {
        if (index != 0) try writer.writeAll(",");
        try writer.print("\"{s}\"", .{programmer.name()});
    }
    try writer.writeAll("]}\n");
}

fn writeProgrammerInfo(writer: anytype, info: session.SystemInfo) !void {
    if (info.status == .bootloader) {
        try writer.print("Found {s} in bootloader mode.\n", .{info.model_name});
        return;
    }

    const expected = expectedFirmware(info.programmer);
    const firmware = std.mem.sliceTo(&info.firmware_string, 0);
    try writer.print("Found {s} {s} (0x{x})\n", .{ info.model_name, firmware, info.firmware });
    if (supportWarning(info.programmer)) |warning| try writer.print("{s}\n", .{warning});
    if (expected.version != 0 and info.firmware < expected.version) {
        try writer.writeAll("Warning: Firmware is out of date.\n");
        try writer.print("  Expected  {s} (0x{x})\n", .{ expected.label, expected.version });
        try writer.print("  Found     {s} (0x{x})\n", .{ firmware, info.firmware });
    } else if (expected.version != 0 and info.firmware > expected.version) {
        try writer.writeAll("Warning: Firmware is newer than expected.\n");
        try writer.print("  Expected  {s} (0x{x})\n", .{ expected.label, expected.version });
        try writer.print("  Found     {s} (0x{x})\n", .{ firmware, info.firmware });
    }
    try writer.print("Device code: {s}\n", .{std.mem.trimEnd(u8, &info.device_code, "\x00 ")});
    try writer.print("Serial code: {s}\n", .{std.mem.trimEnd(u8, &info.serial_number, "\x00 ")});
    const manufacture_date = std.mem.trimEnd(u8, &info.manufacture_date, "\x00 ");
    if (manufacture_date.len != 0) try writer.print("Manufactured: {s}\n", .{manufacture_date});
    try writer.print("USB speed: {s}\n", .{speedLabel(info.speed)});
    if (info.voltage > 0) try writer.print("Supply voltage: {d:.2} V {s}\n", .{ info.voltage, powerLabel(info) });
}

fn writeProgrammerInfoJson(writer: anytype, info: session.SystemInfo) !void {
    try writer.print(
        "{{\"model\":\"{s}\",\"status\":\"{s}\",\"firmware\":\"{s}\",\"device_code\":\"{s}\",\"serial_number\":\"{s}\",\"voltage\":{d:.2},\"usb_speed\":\"{s}\",\"external_power\":{s}}}\n",
        .{
            info.model_name,
            statusLabel(info.status),
            std.mem.sliceTo(&info.firmware_string, 0),
            std.mem.trimEnd(u8, &info.device_code, "\x00 "),
            std.mem.trimEnd(u8, &info.serial_number, "\x00 "),
            info.voltage,
            speedLabel(info.speed),
            if (info.external_power != 0) "true" else "false",
        },
    );
}

fn statusLabel(status: session.Status) []const u8 {
    return switch (status) {
        .normal => "normal",
        .bootloader => "bootloader",
        .unknown => "unknown",
    };
}

fn speedLabel(speed: u8) []const u8 {
    return switch (speed) {
        0 => "12Mbps (USB 1.1)",
        3 => "5Gbps (USB 3.0)",
        else => "480Mbps (USB 2.0)",
    };
}

const FirmwareExpectation = struct {
    version: u16,
    label: []const u8,
};

fn expectedFirmware(programmer: model.Programmer) FirmwareExpectation {
    return switch (programmer) {
        .tl866a => .{ .version = 0x0256, .label = "03.2.86" },
        .tl866ii => .{ .version = 0x0284, .label = "04.2.132" },
        .t48 => .{ .version = 0x0126, .label = "01.1.38" },
        .t56 => .{ .version = 0x0149, .label = "01.1.73" },
        .t76 => .{ .version = 0x010d, .label = "00.1.13" },
        .auto => .{ .version = 0, .label = "" },
    };
}

fn supportWarning(programmer: model.Programmer) ?[]const u8 {
    return switch (programmer) {
        .t48 => "Warning: T48 support is not yet complete!",
        .t56 => "Warning: T56 support is experimental!",
        .t76 => "Warning: T76 support is experimental!",
        else => null,
    };
}

fn powerLabel(info: session.SystemInfo) []const u8 {
    return switch (info.programmer) {
        .t56, .t76 => if (info.external_power != 0) "(External)" else "(USB)",
        else => "",
    };
}

test "parse help and version" {
    try expectParsedTag(.help, try parse(&.{ "minipro-zig", "--help" }));
    try expectParsedTag(.version, try parse(&.{ "minipro-zig", "-V" }));
}

test "parse programmer list aliases" {
    try std.testing.expectEqualDeep(Parsed{ .programmer_list = .{ .legacy = true } }, try parse(&.{ "minipro-zig", "-Q" }));
    try std.testing.expectEqualDeep(Parsed{ .programmer_list = .{ .opts = .{ .programmer = .t48 } } }, try parse(&.{ "minipro-zig", "-q", "t48", "programmer", "list" }));
    try std.testing.expectEqualDeep(Parsed{ .programmer_detect = .{} }, try parse(&.{ "minipro-zig", "programmer", "detect" }));
    try std.testing.expectEqualDeep(Parsed{ .programmer_detect = .{ .opts = .{ .json = true }, .legacy = true } }, try parse(&.{ "minipro-zig", "-k", "--json" }));
    try std.testing.expectEqualDeep(Parsed{ .programmer_info = .{ .json = true } }, try parse(&.{ "minipro-zig", "programmer", "info", "--json" }));
}

test "parse db and device commands" {
    try std.testing.expectEqualDeep(Parsed{ .db_import = .{ .infoic = "infoic.xml", .out = "devices.sqlite" } }, try parse(&.{ "minipro-zig", "db", "import", "--infoic", "infoic.xml", "--out", "devices.sqlite" }));
    try std.testing.expectEqualDeep(Parsed{ .db_import = .{ .infoic = "infoic.xml", .logicic = "logicic.xml", .out = "devices.sqlite" } }, try parse(&.{ "minipro-zig", "db", "import", "--infoic", "infoic.xml", "--logicic", "logicic.xml", "--out", "devices.sqlite" }));
    try std.testing.expectEqualDeep(Parsed{ .db_import = .{ .infoic = "infoic.xml", .algorithms = "algorithm.xml", .out = "devices.sqlite" } }, try parse(&.{ "minipro-zig", "db", "import", "--infoic", "infoic.xml", "--algorithms", "algorithm.xml", "--out", "devices.sqlite" }));
    try std.testing.expectEqualDeep(Parsed{ .db_stats = .{ .db_path = "devices.sqlite" } }, try parse(&.{ "minipro-zig", "--db", "devices.sqlite", "db", "stats" }));
    try std.testing.expectEqualDeep(Parsed{ .db_query = .{ .opts = .{ .db_path = "devices.sqlite" }, .sql = "select 1" } }, try parse(&.{ "minipro-zig", "--db", "devices.sqlite", "db", "query", "select 1" }));
    try std.testing.expectEqualDeep(Parsed{ .device_list = .{ .opts = .{ .db_path = "devices.sqlite" }, .limit = 5 } }, try parse(&.{ "minipro-zig", "--db", "devices.sqlite", "device", "list", "--limit", "5" }));
    try std.testing.expectEqualDeep(Parsed{ .device_search = .{ .opts = .{ .db_path = "devices.sqlite" }, .term = "AT28", .limit = 3 } }, try parse(&.{ "minipro-zig", "--db", "devices.sqlite", "device", "search", "AT28", "--limit", "3" }));
    try std.testing.expectEqualDeep(Parsed{ .device_info = .{ .opts = .{ .db_path = "devices.sqlite" }, .name = "AT28C64B" } }, try parse(&.{ "minipro-zig", "--db", "devices.sqlite", "device", "info", "AT28C64B" }));
    try std.testing.expectEqualDeep(Parsed{ .chip_read = .{ .opts = .{ .db_path = "devices.sqlite", .programmer = .t48 }, .device = "AT28C64B", .out = "rom.bin", .format = .ihex, .memory = .code } }, try parse(&.{ "minipro-zig", "--db", "devices.sqlite", "chip", "read", "--device", "AT28C64B", "--out", "rom.bin", "--format", "ihex", "--programmer", "t48" }));
    try std.testing.expectEqualDeep(Parsed{ .chip_verify = .{ .opts = .{ .db_path = "devices.sqlite", .programmer = .t48 }, .device = "AT28C64B", .input = "rom.bin", .format = .bin, .memory = .code } }, try parse(&.{ "minipro-zig", "--db", "devices.sqlite", "chip", "verify", "--device", "AT28C64B", "--in", "rom.bin", "--programmer", "t48" }));
    try std.testing.expectEqualDeep(Parsed{ .chip_verify = .{ .opts = .{ .db_path = "devices.sqlite", .programmer = .t48 }, .device = "AT89C1051@DIP20", .input = "fuses.jed", .format = .jedec, .memory = .code } }, try parse(&.{ "minipro-zig", "--db", "devices.sqlite", "chip", "verify", "--device", "AT89C1051@DIP20", "--in", "fuses.jed", "--format", "jedec", "--programmer", "t48" }));
    try std.testing.expectEqualDeep(Parsed{ .chip_verify = .{ .opts = .{ .db_path = "devices.sqlite", .programmer = .t48 }, .device = "AT89C1051@DIP20", .input = "fuses.cfg", .format = .config, .memory = .code } }, try parse(&.{ "minipro-zig", "--db", "devices.sqlite", "chip", "verify", "--device", "AT89C1051@DIP20", "--in", "fuses.cfg", "--format", "config", "--programmer", "t48" }));
    try std.testing.expectEqualDeep(Parsed{ .chip_write = .{ .opts = .{ .db_path = "devices.sqlite", .programmer = .t48 }, .device = "AT28C64B", .input = "rom.bin", .format = .bin, .memory = .code, .unprotect_before = true, .protect_after = true } }, try parse(&.{ "minipro-zig", "--db", "devices.sqlite", "chip", "write", "--device", "AT28C64B", "--in", "rom.bin", "--programmer", "t48", "--unprotect", "--protect" }));
    try std.testing.expectEqualDeep(Parsed{ .chip_write = .{ .opts = .{ .db_path = "devices.sqlite", .programmer = .t48 }, .device = "AT28C64B", .input = "rom.bin", .format = .bin, .memory = .code, .op_opts = .{ .size_error = true, .size_nowarn = true } } }, try parse(&.{ "minipro-zig", "--db", "devices.sqlite", "chip", "write", "--device", "AT28C64B", "--in", "rom.bin", "--programmer", "t48", "-S" }));
    try std.testing.expectEqualDeep(Parsed{ .chip_verify = .{ .opts = .{ .db_path = "devices.sqlite", .programmer = .t48 }, .device = "AT28C64B", .input = "rom.bin", .format = .bin, .memory = .code, .op_opts = .{ .size_error = true } } }, try parse(&.{ "minipro-zig", "--db", "devices.sqlite", "chip", "verify", "--device", "AT28C64B", "--in", "rom.bin", "--programmer", "t48", "-s" }));
    try std.testing.expectEqualDeep(Parsed{ .chip_read_id = .{ .opts = .{ .db_path = "devices.sqlite", .programmer = .t48 }, .device = "AT28C64B", .op_opts = .{ .idcheck_skip = true } } }, try parse(&.{ "minipro-zig", "--db", "devices.sqlite", "-p", "AT28C64B", "-D", "-x", "-q", "t48" }));
    try std.testing.expectEqualDeep(Parsed{ .chip_write = .{ .opts = .{ .db_path = "devices.sqlite", .programmer = .t48 }, .device = "AT28C64B", .input = "rom.bin", .format = .bin, .memory = .code, .unprotect_before = true, .protect_after = true } }, try parse(&.{ "minipro-zig", "--db", "devices.sqlite", "-p", "AT28C64B", "-w", "rom.bin", "-P", "-u", "-q", "t48" }));
    try std.testing.expectEqualDeep(Parsed{ .chip_write = .{ .opts = .{ .db_path = "devices.sqlite", .programmer = .t48 }, .device = "AT28C64B", .input = "rom.bin", .format = .bin, .memory = .code, .op_opts = .{ .no_erase = true, .no_verify = true, .idcheck_continue = true, .size_error = true, .size_nowarn = true, .pulse = "100", .vpp = "12", .vdd = "5", .vcc = "5", .spi_clock = "1", .address = "0x50" } } }, try parse(&.{ "minipro-zig", "--db", "devices.sqlite", "-p", "AT28C64B", "-w", "rom.bin", "-q", "t48", "-e", "-v", "-y", "-s", "-S", "--pulse", "100", "--vpp", "12", "--vdd", "5", "--vcc", "5", "--spi_clock", "1", "--address", "0x50" }));
    try std.testing.expectEqualDeep(Parsed{ .chip_read = .{ .opts = .{ .db_path = "devices.sqlite", .programmer = .t48 }, .device = "AT28C64B", .out = "rom.bin", .format = .bin, .memory = .code, .op_opts = .{ .vpp = "12.5" } } }, try parse(&.{ "minipro-zig", "--db", "devices.sqlite", "-p", "AT28C64B", "-r", "rom.bin", "-q", "t48", "-c", "code", "-o", "vpp=12.5" }));
    try std.testing.expectEqualDeep(Parsed{ .chip_pin_check = .{ .opts = .{ .db_path = "devices.sqlite", .programmer = .t48 }, .device = "AT28C64B", .legacy = true } }, try parse(&.{ "minipro-zig", "--db", "devices.sqlite", "-p", "AT28C64B", "-z", "-q", "t48" }));
    try std.testing.expectEqualDeep(Parsed{ .chip_protect = .{ .opts = .{ .db_path = "devices.sqlite", .programmer = .t48 }, .device = "AT28C64B", .enable = true } }, try parse(&.{ "minipro-zig", "--db", "devices.sqlite", "-p", "AT28C64B", "-P", "-q", "t48" }));
    try std.testing.expectEqualDeep(Parsed{ .logic_test = .{ .opts = .{ .db_path = "devices.sqlite", .programmer = .t48 }, .device = "40106", .out = "logicic-out.xml" } }, try parse(&.{ "minipro-zig", "--db", "devices.sqlite", "logic", "test", "--device", "40106", "--out", "logicic-out.xml", "--programmer", "t48" }));
    try std.testing.expectEqualDeep(Parsed{ .logic_test = .{ .opts = .{ .db_path = "devices.sqlite", .programmer = .t48 }, .device = "40106", .out = "logicic-out.xml", .legacy = true } }, try parse(&.{ "minipro-zig", "--db", "devices.sqlite", "-p", "40106", "-T", "--logicic_out", "logicic-out.xml", "-q", "t48" }));
    try std.testing.expectEqualDeep(Parsed{ .chip_autodetect = .{ .opts = .{ .db_path = "devices.sqlite", .programmer = .t48 }, .package_pins = 8 } }, try parse(&.{ "minipro-zig", "--db", "devices.sqlite", "chip", "autodetect", "--package", "8", "--programmer", "t48" }));
    try std.testing.expectEqualDeep(Parsed{ .chip_autodetect = .{ .opts = .{ .db_path = "devices.sqlite", .programmer = .t48 }, .package_pins = 16, .legacy = true } }, try parse(&.{ "minipro-zig", "--db", "devices.sqlite", "-a", "16", "-q", "t48" }));
}

test "operation size check follows upstream -s and -S modes" {
    try std.testing.expectEqual(SizeCheck.ok, sizeCheck(8192, 8192, .{}));
    try std.testing.expectEqual(SizeCheck.mismatch_error, sizeCheck(4, 8192, .{}));
    try std.testing.expectEqual(SizeCheck.mismatch_warn, sizeCheck(4, 8192, .{ .size_error = true }));
    try std.testing.expectEqual(SizeCheck.mismatch_silent, sizeCheck(4, 8192, .{ .size_error = true, .size_nowarn = true }));
    try std.testing.expect(!(OperationOptions{ .size_error = true }).hasAdvanced());
    try std.testing.expect(!(OperationOptions{ .no_erase = true }).hasAdvanced());
    try std.testing.expect(!(OperationOptions{ .no_verify = true }).hasAdvanced());
    try std.testing.expect(!(OperationOptions{ .idcheck_skip = true }).hasAdvanced());
    try std.testing.expect(!(OperationOptions{ .idcheck_continue = true }).hasAdvanced());
    try std.testing.expect((OperationOptions{ .no_erase = true }).hasAny());
    try std.testing.expect((OperationOptions{ .no_verify = true }).hasAny());
    try std.testing.expect((OperationOptions{ .idcheck_skip = true }).hasAny());
    try std.testing.expect((OperationOptions{ .idcheck_continue = true }).hasAny());
}

test "ID check skip is locally rejected for ID-only style actions" {
    var bytes = [_]u8{0} ** 128;
    var buffer: std.Io.Writer = .fixed(&bytes);
    try std.testing.expect(try rejectInvalidIdCheckSkip(&buffer, .{ .idcheck_skip = true }));
    try std.testing.expectEqualStrings("Skipping the ID check is not permitted for this action.\n", buffer.buffered());

    var empty_bytes = [_]u8{0} ** 1;
    var empty: std.Io.Writer = .fixed(&empty_bytes);
    try std.testing.expect(!try rejectInvalidIdCheckSkip(&empty, .{}));
    try std.testing.expectEqualStrings("", empty.buffered());
}

test "operation numeric options validate fixed upstream ranges" {
    try std.testing.expectError(error.InvalidOperationValue, parse(&.{ "minipro-zig", "--db", "devices.sqlite", "-p", "AT28C64B", "-w", "rom.bin", "--pulse", "65536" }));
    try std.testing.expectError(error.InvalidOperationValue, parse(&.{ "minipro-zig", "--db", "devices.sqlite", "-p", "AT28C64B", "-w", "rom.bin", "--address", "0x100" }));
    try std.testing.expectError(error.InvalidOperationValue, parse(&.{ "minipro-zig", "--db", "devices.sqlite", "-p", "AT28C64B", "-w", "rom.bin", "-o", "pulse=not-a-number" }));
}

test "operation options mutate protocol descriptor" {
    const device = sqlite.ProtocolDevice{
        .canonical_name = "25SPI",
        .chip_type = @intFromEnum(model.ChipType.memory),
        .protocol_id = 0x03,
        .variant = 0,
        .voltages_raw = 0x0500,
        .chip_info = 0x06,
        .pin_map = 0,
        .data_memory_size = 0,
        .data_memory2_size = 0,
        .page_size = 0,
        .pulse_delay = 100,
        .code_memory_size = 0,
        .package_details_raw = 0,
        .read_buffer_size = 0,
        .write_buffer_size = 0,
        .flags_raw = 0,
        .can_adjust_clock = true,
        .chip_id = 0,
        .chip_id_bytes_count = 0,
        .blank_value = 0xff,
        .compare_mask = 0xffff,
        .config_ref = "NULL",
        .config_fuse_count = 0,
        .config_lock_count = 0,
        .config_fuse_details = "",
        .config_lock_details = "",
    };

    const descriptor = try descriptorForOperation(device, .t48, .{ .pulse = "250", .vpp = "12.5", .vdd = "3.3", .vcc = "5", .spi_clock = "30" });
    const voltages = model.decodeVoltages(descriptor.voltages_raw);
    try std.testing.expectEqual(@as(u32, 250), descriptor.pulse_delay);
    try std.testing.expectEqual(@as(u8, 0x60), voltages.vpp);
    try std.testing.expectEqual(@as(u8, 0x01), voltages.vdd);
    try std.testing.expectEqual(@as(u8, 0x00), voltages.vcc);
    try std.testing.expectEqual(@as(u8, 0x03), descriptor.spi_clock);
    try std.testing.expect(descriptor.can_adjust_clock);

    const ignored_spi = try descriptorForOperation(device, .tl866ii, .{ .spi_clock = "30" });
    try std.testing.expect(!ignored_spi.can_adjust_clock);
    try std.testing.expectEqual(@as(u8, 0), ignored_spi.spi_clock);
}

test "operation options apply T76 I2C address" {
    const device = sqlite.ProtocolDevice{
        .canonical_name = "24C02",
        .chip_type = @intFromEnum(model.ChipType.memory),
        .protocol_id = 0x01,
        .variant = 0,
        .voltages_raw = 0x0500,
        .chip_info = 0x06,
        .pin_map = 0,
        .data_memory_size = 0,
        .data_memory2_size = 0,
        .page_size = 0,
        .pulse_delay = 100,
        .code_memory_size = 0,
        .package_details_raw = 0,
        .read_buffer_size = 0,
        .write_buffer_size = 0,
        .flags_raw = 0,
        .can_adjust_clock = false,
        .chip_id = 0,
        .chip_id_bytes_count = 0,
        .blank_value = 0xff,
        .compare_mask = 0xffff,
        .config_ref = "NULL",
        .config_fuse_count = 0,
        .config_lock_count = 0,
        .config_fuse_details = "",
        .config_lock_details = "",
    };

    const descriptor = try descriptorForOperation(device, .t76, .{ .address = "0xa2" });
    try std.testing.expect(descriptor.can_adjust_address);
    try std.testing.expectEqual(@as(u8, 0xa2), descriptor.i2c_address);
    try std.testing.expectError(error.InvalidOperationValue, descriptorForOperation(device, .t76, .{ .address = "0x100" }));
}

test "legacy parser reports targeted option errors" {
    try std.testing.expectError(error.MissingLegacySearchArgument, parse(&.{ "minipro-zig", "-L" }));
    try std.testing.expectError(error.NoLegacyAction, parse(&.{ "minipro-zig", "-p", "AT28C64B" }));
    try std.testing.expectError(error.UnknownOption, parse(&.{ "minipro-zig", "-p", "AT28C64B", "-w", "rom.bin", "-o", "vpp" }));
    try std.testing.expectError(error.MissingOptionValue, parse(&.{ "minipro-zig", "-p", "AT28C64B", "-w", "rom.bin", "-o", "vpp=" }));
    try std.testing.expectError(error.MissingOptionValue, parse(&.{ "minipro-zig", "-p", "AT28C64B", "-w", "rom.bin", "--pulse" }));
}

test "unknown programmer is rejected" {
    try std.testing.expectError(error.UnknownProgrammer, parse(&.{ "minipro-zig", "--programmer", "bad", "programmer", "list" }));
}

test "observed logic state maps pull-up and pull-down results" {
    try std.testing.expectEqual(@as(u8, 'H'), observedLogicState(.high, 1, 1));
    try std.testing.expectEqual(@as(u8, 'L'), observedLogicState(.low, 0, 0));
    try std.testing.expectEqual(@as(u8, 'Z'), observedLogicState(.z, 1, 0));
    try std.testing.expectEqual(@as(u8, '?'), observedLogicState(.z, 0, 1));
    try std.testing.expectEqual(@as(u8, 'G'), observedLogicState(.ground, 0, 1));
}

test "programmer list text matches C oracle format" {
    var bytes = [_]u8{0} ** 256;
    var buffer: std.Io.Writer = .fixed(&bytes);
    try writeProgrammerList(&buffer);
    try std.testing.expectEqualStrings(
        \\tl866a:  TL866CS/A
        \\tl866ii: TL866II+
        \\t48:     T48  (mostly complete)
        \\t56:     T56  (experimental)
        \\t76:     T76  (experimental)
        \\
    , buffer.buffered());
}

fn expectParsedTag(expected: std.meta.Tag(Parsed), actual: Parsed) !void {
    try std.testing.expectEqual(expected, std.meta.activeTag(actual));
}
