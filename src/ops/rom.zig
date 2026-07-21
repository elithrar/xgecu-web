// SPDX-License-Identifier: Apache-2.0

const std = @import("std");
const catalog = @import("../catalog/catalog.zig");
const model = @import("../core/model.zig");
const session = @import("../programmer/session.zig");
const protocol_bytes = @import("../programmer/protocol_bytes.zig");
const protocol = @import("../programmer/protocol.zig");
const t48 = @import("../programmer/t48.zig");
const transport_mod = @import("../programmer/transport.zig");

pub const Error = catalog.Error || protocol.Error || error{
    ProgrammerMismatch,
    UnsupportedProgrammer,
    ChipIdMismatch,
    VerifyFailed,
    InputEmpty,
    EraseUnsupported,
    TargetNotBlank,
    PinCheckUnavailable,
    ProtectionUnsupported,
};

pub const PinCheckResult = struct {
    checked_pins: []u8,
    bad_pins: []u8,

    pub fn deinit(self: PinCheckResult, allocator: std.mem.Allocator) void {
        allocator.free(self.checked_pins);
        allocator.free(self.bad_pins);
    }

    pub fn passed(self: PinCheckResult) bool {
        return self.bad_pins.len == 0;
    }
};

pub const ReadOptions = struct {
    programmer: model.Programmer = .auto,
    memory: model.MemoryKind = .code,
    skip_id_check: bool = false,
    continue_on_id_mismatch: bool = false,
};

pub const WriteOptions = struct {
    programmer: model.Programmer = .auto,
    memory: model.MemoryKind = .code,
    erase: bool = true,
    erase_num_fuses: u8 = 0,
    erase_pld: u8 = 0,
    verify: bool = true,
    skip_id_check: bool = false,
    continue_on_id_mismatch: bool = false,
    unprotect_before: bool = false,
    protect_after: bool = false,
};

pub fn deviceList(allocator: std.mem.Allocator, query: ?[]const u8, programmer: model.Programmer, limit: usize) ![]catalog.DeviceSummary {
    return catalog.list(allocator, query, programmer, limit);
}

pub fn checkPinContacts(
    allocator: std.mem.Allocator,
    trans: transport_mod.Transport,
    device_name: []const u8,
    requested_programmer: model.Programmer,
) Error!PinCheckResult {
    const info = try openSupportedSession(trans, requested_programmer);
    if (info.programmer != .t48) return Error.PinCheckUnavailable;
    const device = try catalog.find(device_name, info.programmer);
    const map = device.pin_check orelse return Error.PinCheckUnavailable;
    const package = model.decodePackageDetails(device.package_details_raw);
    if (package.pin_count == 0 or package.pin_count > protocol_bytes.packet.main_zif_pin_count or package.pin_count % 2 != 0) return Error.PinCheckUnavailable;
    for (map.gnd_pins) |zif_pin| _ = try devicePinNumber(zif_pin, package.pin_count);
    for (map.mask) |zif_pin| _ = try devicePinNumber(zif_pin, package.pin_count);

    const read = try t48.checkPinContacts(trans, map.gnd_pins);
    const checked_pins = try allocator.alloc(u8, map.mask.len);
    errdefer allocator.free(checked_pins);
    var bad: std.ArrayListUnmanaged(u8) = .empty;
    errdefer bad.deinit(allocator);

    for (map.mask, 0..) |zif_pin, index| {
        const device_pin = try devicePinNumber(zif_pin, package.pin_count);
        checked_pins[index] = device_pin;
        if (read.high & (@as(u64, 1) << @intCast(zif_pin - 1)) == 0) try bad.append(allocator, device_pin);
    }
    return .{
        .checked_pins = checked_pins,
        .bad_pins = try bad.toOwnedSlice(allocator),
    };
}

pub fn readROM(
    allocator: std.mem.Allocator,
    trans: transport_mod.Transport,
    device_name: []const u8,
    options: ReadOptions,
) Error![]u8 {
    const info = try openSupportedSession(trans, options.programmer);
    const device = try catalog.find(device_name, info.programmer);
    const size = memorySize(device, options.memory);
    if (size == 0) return Error.EmptyMemoryRegion;

    var out = try allocator.alloc(u8, size);
    errdefer allocator.free(out);

    const descriptor = device.descriptor(info.programmer);
    const ctx = try protocol.begin(allocator, info.programmer, trans, descriptor, device.algorithmFor(info.programmer));
    defer ctx.deinit(allocator);
    var read_ctx: ?protocol.BeginContext = null;
    defer if (read_ctx) |restart| restart.deinit(allocator);
    var protocol_open = true;
    errdefer if (protocol_open) protocol.end(info.programmer, trans) catch {};

    const check_id = shouldCheckChipId(device, .{
        .skip = options.skip_id_check,
        .continue_on_mismatch = options.continue_on_id_mismatch,
    });
    try checkChipId(info.programmer, trans, device, .{
        .skip = options.skip_id_check,
        .continue_on_mismatch = options.continue_on_id_mismatch,
    });
    if (check_id) {
        try protocol.end(info.programmer, trans);
        protocol_open = false;
        read_ctx = try protocol.begin(allocator, info.programmer, trans, descriptor, device.algorithmFor(info.programmer));
        protocol_open = true;
    }

    var offset: usize = 0;
    const chunk_size = readChunkSize(info.programmer, descriptor);
    while (offset < out.len) {
        const len = @min(chunk_size, out.len - offset);
        try protocol.readBlock(info.programmer, trans, options.memory, @intCast(offset), out[offset .. offset + len]);
        try checkReadStatus(info.programmer, trans);
        offset += len;
    }
    try protocol.end(info.programmer, trans);
    protocol_open = false;
    return out;
}

pub fn writeROM(
    allocator: std.mem.Allocator,
    trans: transport_mod.Transport,
    device_name: []const u8,
    data: []const u8,
    options: WriteOptions,
) Error!void {
    if (data.len == 0) return Error.InputEmpty;
    const info = try openSupportedSession(trans, options.programmer);
    const device = try catalog.find(device_name, info.programmer);
    const size = memorySize(device, options.memory);
    if (size == 0) return Error.EmptyMemoryRegion;
    if (data.len > size) return Error.InputTooLarge;
    if (options.erase and options.memory != .code) return Error.InputTooLarge;
    if (options.erase and data.len != size) return Error.InputTooLarge;
    if (options.erase and !device.can_erase) return Error.EraseUnsupported;
    const flags = model.decodeFlags(device.flags_raw, device.voltages_raw, device.chip_info, device.protocol_id);
    if (options.unprotect_before and !flags.off_protect_before) return Error.ProtectionUnsupported;
    if (options.protect_after and !flags.protect_after) return Error.ProtectionUnsupported;

    const descriptor = device.descriptor(info.programmer);
    // Reserve blank-check storage before erase so allocation failure cannot strand an erased target.
    var blank_buffer: ?[]u8 = null;
    if (options.erase or !device.can_erase) {
        blank_buffer = try allocator.alloc(u8, readChunkSize(info.programmer, descriptor));
    }
    defer if (blank_buffer) |buffer| allocator.free(buffer);
    var protocol_open = false;
    const first_ctx = try protocol.begin(allocator, info.programmer, trans, descriptor, device.algorithmFor(info.programmer));
    defer first_ctx.deinit(allocator);
    protocol_open = true;
    errdefer if (protocol_open) protocol.end(info.programmer, trans) catch {};

    const chip_id_policy = ChipIdPolicy{
        .skip = options.skip_id_check,
        .continue_on_mismatch = options.continue_on_id_mismatch,
    };
    const check_id = shouldCheckChipId(device, chip_id_policy);
    try checkChipId(info.programmer, trans, device, chip_id_policy);

    var post_id_ctx: ?protocol.BeginContext = null;
    defer if (post_id_ctx) |ctx| ctx.deinit(allocator);
    var second_ctx: ?protocol.BeginContext = null;
    defer if (second_ctx) |ctx| ctx.deinit(allocator);
    var post_blank_ctx: ?protocol.BeginContext = null;
    defer if (post_blank_ctx) |ctx| ctx.deinit(allocator);
    var verify_ctx: ?protocol.BeginContext = null;
    defer if (verify_ctx) |ctx| ctx.deinit(allocator);
    if (check_id) {
        try protocol.end(info.programmer, trans);
        protocol_open = false;
        post_id_ctx = try protocol.begin(allocator, info.programmer, trans, descriptor, device.algorithmFor(info.programmer));
        protocol_open = true;
    }
    if (options.erase) {
        try protocol.erase(info.programmer, trans, options.erase_num_fuses, options.erase_pld);
        try protocol.end(info.programmer, trans);
        protocol_open = false;
        second_ctx = try protocol.begin(allocator, info.programmer, trans, descriptor, device.algorithmFor(info.programmer));
        protocol_open = true;
    }

    if (options.erase or !device.can_erase) {
        try ensureBlank(info.programmer, trans, device, options.memory, size, blank_buffer.?);
        try protocol.end(info.programmer, trans);
        protocol_open = false;
        post_blank_ctx = try protocol.begin(allocator, info.programmer, trans, descriptor, device.algorithmFor(info.programmer));
        protocol_open = true;
    }

    if (options.unprotect_before) {
        try protectOff(info.programmer, trans);
        try checkProgrammerStatus(info.programmer, trans);
    }

    var offset: usize = 0;
    const chunk_size = @max(@as(usize, descriptor.write_buffer_size), 1);
    while (offset < data.len) {
        const len = @min(chunk_size, data.len - offset);
        try protocol.writeBlock(allocator, info.programmer, trans, descriptor, options.memory, @intCast(offset), data[offset .. offset + len]);
        const status = try protocol.requestStatus(info.programmer, trans);
        if (status.overcurrent != 0) return Error.Overcurrent;
        if (status.error_code != 0) return Error.ProgrammerStatusError;
        offset += len;
    }

    if (options.verify) {
        try protocol.end(info.programmer, trans);
        protocol_open = false;
        verify_ctx = try protocol.begin(allocator, info.programmer, trans, descriptor, device.algorithmFor(info.programmer));
        protocol_open = true;
        var actual = try allocator.alloc(u8, data.len);
        defer allocator.free(actual);
        offset = 0;
        const read_chunk = readChunkSize(info.programmer, descriptor);
        while (offset < actual.len) {
            const len = @min(read_chunk, actual.len - offset);
            try protocol.readBlock(info.programmer, trans, options.memory, @intCast(offset), actual[offset .. offset + len]);
            try checkReadStatus(info.programmer, trans);
            offset += len;
        }
        if (!std.mem.eql(u8, data, actual)) return Error.VerifyFailed;
    }
    if (options.protect_after) {
        try protectOn(info.programmer, trans);
        try checkProgrammerStatus(info.programmer, trans);
    }
    try protocol.end(info.programmer, trans);
    protocol_open = false;
}

fn openSupportedSession(trans: transport_mod.Transport, requested: model.Programmer) Error!session.SystemInfo {
    const info = try session.getSystemInfo(trans);
    switch (info.programmer) {
        .t48, .t56 => {},
        else => return Error.UnsupportedProgrammer,
    }
    if (info.status == .bootloader) return Error.ProgrammerInBootloader;
    if (requested != .auto and requested != info.programmer) return Error.ProgrammerMismatch;
    return info;
}

const ChipIdPolicy = struct {
    skip: bool,
    continue_on_mismatch: bool,
};

fn checkChipId(programmer: model.Programmer, trans: transport_mod.Transport, device: catalog.DeviceRecord, policy: ChipIdPolicy) Error!void {
    if (!shouldCheckChipId(device, policy)) return;
    const actual = try protocol.getChipId(programmer, trans, device.chip_id_bytes_count);
    if (actual.value != device.chip_id and !policy.continue_on_mismatch) return Error.ChipIdMismatch;
}

fn shouldCheckChipId(device: catalog.DeviceRecord, policy: ChipIdPolicy) bool {
    return !policy.skip and device.chip_id != 0 and device.chip_id_bytes_count != 0;
}

fn ensureBlank(
    programmer: model.Programmer,
    trans: transport_mod.Transport,
    device: catalog.DeviceRecord,
    memory: model.MemoryKind,
    size: usize,
    buffer: []u8,
) Error!void {
    std.debug.assert(buffer.len != 0);
    var offset: usize = 0;
    while (offset < size) {
        const len = @min(buffer.len, size - offset);
        try protocol.readBlock(programmer, trans, memory, @intCast(offset), buffer[0..len]);
        try checkReadStatus(programmer, trans);
        for (buffer[0..len]) |byte| {
            if (byte != device.blank_value) return Error.TargetNotBlank;
        }
        offset += len;
    }
}

fn memorySize(device: catalog.DeviceRecord, memory: model.MemoryKind) usize {
    return switch (memory) {
        .code => device.code_memory_size,
        .data => device.data_memory_size,
        .user => device.data_memory2_size,
    };
}

fn devicePinNumber(zif_pin: u8, package_pins: u8) Error!u8 {
    if (zif_pin == 0 or zif_pin > protocol_bytes.packet.main_zif_pin_count) return Error.PinCheckUnavailable;
    const half = package_pins / 2;
    const gap = protocol_bytes.packet.main_zif_pin_count - package_pins;
    const device_pin = if (zif_pin <= half)
        zif_pin
    else if (zif_pin > protocol_bytes.packet.main_zif_pin_count - half)
        zif_pin - gap
    else
        return Error.PinCheckUnavailable;
    if (device_pin == 0 or device_pin > package_pins) return Error.PinCheckUnavailable;
    return device_pin;
}

fn readChunkSize(programmer: model.Programmer, descriptor: t48.Device) usize {
    const descriptor_chunk = @max(@as(usize, descriptor.read_buffer_size), 1);
    return if (programmer == .t56)
        @min(descriptor_chunk, protocol_bytes.packet.t56_read_payload_max)
    else
        descriptor_chunk;
}

fn checkReadStatus(programmer: model.Programmer, trans: transport_mod.Transport) Error!void {
    if (programmer != .t48) return;
    try checkProgrammerStatus(programmer, trans);
}

fn checkProgrammerStatus(programmer: model.Programmer, trans: transport_mod.Transport) Error!void {
    const status = try protocol.requestStatus(programmer, trans);
    if (status.overcurrent != 0) return Error.Overcurrent;
    if (status.error_code != 0) return Error.ProgrammerStatusError;
}

fn protectOff(programmer: model.Programmer, trans: transport_mod.Transport) Error!void {
    return switch (programmer) {
        .t48 => @import("../programmer/t48.zig").protectOff(trans),
        .t56 => @import("../programmer/t56.zig").protectOff(trans),
        else => Error.UnsupportedProgrammer,
    };
}

fn protectOn(programmer: model.Programmer, trans: transport_mod.Transport) Error!void {
    return switch (programmer) {
        .t48 => @import("../programmer/t48.zig").protectOn(trans),
        .t56 => @import("../programmer/t56.zig").protectOn(trans),
        else => Error.UnsupportedProgrammer,
    };
}

test "deviceList exposes catalog summaries" {
    const found = try deviceList(std.testing.allocator, "AT28", .t48, 5);
    defer std.testing.allocator.free(found);
    try std.testing.expectEqual(@as(usize, 1), found.len);
    try std.testing.expectEqual(@as(u32, 8192), found[0].code_memory_size);
    try std.testing.expect(found[0].supports_unprotect);
    try std.testing.expect(found[0].supports_protect);
    try std.testing.expect(found[0].supports_pin_check);
}

test "checkPinContacts reports T48 device pin numbers" {
    try std.testing.expectError(Error.PinCheckUnavailable, devicePinNumber(15, 28));

    var response = [_]u8{0xff} ** protocol_bytes.packet.system_info_response_len;
    response[4] = 1;
    response[5] = 2;
    response[6] = 7;
    response[1] = 0;
    response[8] &= ~@as(u8, 0x02);
    var fake = transport_mod.FakeTransport.init(std.testing.allocator, &response);
    defer fake.deinit();

    const result = try checkPinContacts(std.testing.allocator, fake.transport(), "AT28C64B", .t48);
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(!result.passed());
    try std.testing.expectEqualSlices(u8, &.{2}, result.bad_pins);
    try std.testing.expectEqual(@as(u8, 2), result.checked_pins[0]);
    try std.testing.expectEqual(@as(u8, 28), result.checked_pins[result.checked_pins.len - 1]);
}

test "writeROM rejects unsupported protection commands before a transaction" {
    var response = [_]u8{0} ** 80;
    response[4] = 1;
    response[6] = 7;
    var fake = transport_mod.FakeTransport.init(std.testing.allocator, &response);
    defer fake.deinit();
    const data = [_]u8{0xff} ** 8192;

    try std.testing.expectError(Error.ProtectionUnsupported, writeROM(std.testing.allocator, fake.transport(), "M27C64A", &data, .{
        .programmer = .t48,
        .erase = false,
        .unprotect_before = true,
    }));
    try std.testing.expectEqual(@as(usize, protocol_bytes.packet.system_info_request_len), fake.sent.items.len);
}

test "readROM uses session, begin transaction, and chunked reads" {
    var response = [_]u8{0} ** 80;
    response[4] = 1;
    response[5] = 2;
    response[6] = 7;
    @memcpy(response[8..24], "2026-07-04......");
    response[12] = 0;
    @memcpy(response[24..32], "T48CODE!");
    @memcpy(response[32..54], "SERIAL-T48-00000000000");
    var payload = [_]u8{0xaa} ** 8192;
    var fake = transport_mod.FakeTransport.init(std.testing.allocator, &response);
    fake.payload_response = &payload;
    defer fake.deinit();

    const bytes = try readROM(std.testing.allocator, fake.transport(), "AT28C64B", .{ .programmer = .t48, .skip_id_check = true });
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqual(@as(usize, 8192), bytes.len);
    try std.testing.expectEqual(@as(u8, 0xaa), bytes[0]);
}

test "writeROM rejects empty data before touching transport" {
    var fake = transport_mod.FakeTransport.init(std.testing.allocator, &.{});
    defer fake.deinit();

    try std.testing.expectError(Error.InputEmpty, writeROM(std.testing.allocator, fake.transport(), "AT28C64B", &.{}, .{ .programmer = .t48 }));
    try std.testing.expectEqual(@as(usize, 0), fake.sent.items.len);
}

test "T56 read chunk size is capped to protocol payload window" {
    var descriptor = catalog.devices[0].descriptor(.t56);
    descriptor.read_buffer_size = 512;
    try std.testing.expectEqual(@as(usize, protocol_bytes.packet.t56_read_payload_max), readChunkSize(.t56, descriptor));
    try std.testing.expectEqual(@as(usize, 512), readChunkSize(.t48, descriptor));
}

test "readROM reports chip ID mismatch before reading payload" {
    var response = [_]u8{0} ** 80;
    response[4] = 1;
    response[5] = 2;
    response[6] = 7;
    @memcpy(response[8..24], "2026-07-04......");
    response[12] = 0;
    @memcpy(response[24..32], "T48CODE!");
    @memcpy(response[32..54], "SERIAL-T48-00000000000");
    var fake = transport_mod.FakeTransport.init(std.testing.allocator, &response);
    defer fake.deinit();

    try std.testing.expectError(Error.ChipIdMismatch, readROM(std.testing.allocator, fake.transport(), "M27C64A@DIP28", .{ .programmer = .t48 }));
    try std.testing.expectEqual(@as(usize, 0), fake.payload_sent.items.len);
}

test "writeROM uses T48 write status and verify sequence" {
    var response = [_]u8{0} ** 80;
    response[4] = 1;
    response[5] = 2;
    response[6] = 7;
    @memcpy(response[8..24], "2026-07-04......");
    response[12] = 0;
    @memcpy(response[24..32], "T48CODE!");
    @memcpy(response[32..54], "SERIAL-T48-00000000000");
    const write_data = [_]u8{ 0x12, 0x34, 0x56, 0x78 };
    var verify_payload = [_]u8{0} ** protocol_bytes.packet.t48_min_read_payload_len;
    @memcpy(verify_payload[0..write_data.len], &write_data);
    var fake = transport_mod.FakeTransport.init(std.testing.allocator, &response);
    fake.payload_response = &verify_payload;
    defer fake.deinit();

    try writeROM(std.testing.allocator, fake.transport(), "AT28C64B", &write_data, .{ .programmer = .t48, .erase = false, .skip_id_check = true });

    try std.testing.expect(std.mem.indexOfScalar(u8, fake.sent.items, protocol_bytes.command.write_code) != null);
    try std.testing.expect(std.mem.indexOfScalar(u8, fake.sent.items, protocol_bytes.command.read_code) != null);
    try std.testing.expectEqualSlices(u8, &write_data, fake.payload_sent.items[0..write_data.len]);
    try std.testing.expect(std.mem.allEqual(u8, fake.payload_sent.items[write_data.len..], 0));
    try std.testing.expectEqual(protocol_bytes.command.end_transaction, fake.sent.items[93]);
    try std.testing.expectEqual(protocol_bytes.command.begin_transaction, fake.sent.items[101]);
    try std.testing.expectEqual(protocol_bytes.command.read_code, fake.sent.items[173]);
}

test "writeROM reports verify mismatch for T48" {
    var response = [_]u8{0} ** 80;
    response[4] = 1;
    response[5] = 2;
    response[6] = 7;
    @memcpy(response[8..24], "2026-07-04......");
    response[12] = 0;
    @memcpy(response[24..32], "T48CODE!");
    @memcpy(response[32..54], "SERIAL-T48-00000000000");
    var verify_payload = [_]u8{0xff} ** protocol_bytes.packet.t48_min_read_payload_len;
    var data = [_]u8{ 0x12, 0x34, 0x56, 0x78 };
    var fake = transport_mod.FakeTransport.init(std.testing.allocator, &response);
    fake.payload_response = &verify_payload;
    defer fake.deinit();

    try std.testing.expectError(Error.VerifyFailed, writeROM(std.testing.allocator, fake.transport(), "AT28C64B", &data, .{ .programmer = .t48, .erase = false, .skip_id_check = true }));
}

test "writeROM rejects partial data before an erase transaction" {
    var response = [_]u8{0} ** 80;
    response[4] = 1;
    response[6] = 7;
    var fake = transport_mod.FakeTransport.init(std.testing.allocator, &response);
    defer fake.deinit();

    try std.testing.expectError(Error.InputTooLarge, writeROM(std.testing.allocator, fake.transport(), "AT28C64B", &.{0xaa}, .{ .programmer = .t48 }));
    try std.testing.expectEqual(@as(usize, protocol_bytes.packet.system_info_request_len), fake.sent.items.len);
}

test "writeROM rejects electrical erase for UV EPROM before begin transaction" {
    var response = [_]u8{0} ** 80;
    response[4] = 1;
    response[6] = 7;
    var data = [_]u8{0xff} ** 8192;
    var fake = transport_mod.FakeTransport.init(std.testing.allocator, &response);
    defer fake.deinit();

    try std.testing.expectError(
        Error.EraseUnsupported,
        writeROM(std.testing.allocator, fake.transport(), "M27C64A@DIP28", &data, .{ .programmer = .t48 }),
    );
    try std.testing.expectEqual(@as(usize, protocol_bytes.packet.system_info_request_len), fake.sent.items.len);
}

test "writeROM rejects a nonblank UV EPROM before programming" {
    var response = [_]u8{0} ** 80;
    response[4] = 1;
    response[6] = 7;
    var target = [_]u8{0xff} ** 8192;
    target[0] = 0;
    var data = [_]u8{0xaa} ** 8192;
    var fake = transport_mod.FakeTransport.init(std.testing.allocator, &response);
    fake.payload_response = &target;
    defer fake.deinit();

    try std.testing.expectError(
        Error.TargetNotBlank,
        writeROM(std.testing.allocator, fake.transport(), "M27C64A@DIP28", &data, .{
            .programmer = .t48,
            .erase = false,
            .skip_id_check = true,
        }),
    );
    try std.testing.expect(std.mem.indexOfScalar(u8, fake.sent.items, protocol_bytes.command.read_code) != null);
    try std.testing.expect(std.mem.indexOfScalar(u8, fake.sent.items, protocol_bytes.command.write_code) == null);
}

test "writeROM blank-checks an electrically erased target before programming" {
    var response = [_]u8{0} ** 80;
    response[4] = 1;
    response[6] = 7;
    var target = [_]u8{0xff} ** 8192;
    target[0] = 0;
    var data = [_]u8{0xaa} ** 8192;
    var fake = transport_mod.FakeTransport.init(std.testing.allocator, &response);
    fake.payload_response = &target;
    defer fake.deinit();

    try std.testing.expectError(
        Error.TargetNotBlank,
        writeROM(std.testing.allocator, fake.transport(), "AT28C64B", &data, .{
            .programmer = .t48,
            .skip_id_check = true,
        }),
    );
    try std.testing.expect(std.mem.indexOfScalar(u8, fake.sent.items, protocol_bytes.command.erase) != null);
    try std.testing.expect(std.mem.indexOfScalar(u8, fake.sent.items, protocol_bytes.command.read_code) != null);
    try std.testing.expect(std.mem.indexOfScalar(u8, fake.sent.items, protocol_bytes.command.write_code) == null);
}

test "writeROM allocates blank-check storage before electrical erase" {
    var response = [_]u8{0} ** 80;
    response[4] = 1;
    response[6] = 7;
    var data = [_]u8{0xaa} ** 8192;
    var fake = transport_mod.FakeTransport.init(std.testing.allocator, &response);
    defer fake.deinit();
    var storage: [0]u8 = .{};
    var fixed = std.heap.FixedBufferAllocator.init(&storage);

    try std.testing.expectError(
        error.OutOfMemory,
        writeROM(fixed.allocator(), fake.transport(), "AT28C64B", &data, .{
            .programmer = .t48,
            .skip_id_check = true,
        }),
    );
    try std.testing.expect(std.mem.indexOfScalar(u8, fake.sent.items, protocol_bytes.command.erase) == null);
    try std.testing.expect(std.mem.indexOfScalar(u8, fake.sent.items, protocol_bytes.command.write_code) == null);
}
