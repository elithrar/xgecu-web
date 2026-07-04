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
    verify: bool = true,
    skip_id_check: bool = false,
    continue_on_id_mismatch: bool = false,
    unprotect_before: bool = false,
    protect_after: bool = false,
};

pub fn deviceList(allocator: std.mem.Allocator, query: ?[]const u8, programmer: model.Programmer, limit: usize) ![]catalog.DeviceSummary {
    return catalog.list(allocator, query, programmer, limit);
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
    defer protocol.end(info.programmer, trans);

    try checkChipId(info.programmer, trans, device, .{
        .skip = options.skip_id_check,
        .continue_on_mismatch = options.continue_on_id_mismatch,
    });

    var offset: usize = 0;
    const chunk_size = readChunkSize(info.programmer, descriptor);
    while (offset < out.len) {
        const len = @min(chunk_size, out.len - offset);
        try protocol.readBlock(info.programmer, trans, options.memory, @intCast(offset), out[offset .. offset + len]);
        offset += len;
    }
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

    const descriptor = device.descriptor(info.programmer);
    var protocol_open = false;
    const first_ctx = try protocol.begin(allocator, info.programmer, trans, descriptor, device.algorithmFor(info.programmer));
    defer first_ctx.deinit(allocator);
    protocol_open = true;
    defer if (protocol_open) protocol.end(info.programmer, trans);

    try checkChipId(info.programmer, trans, device, .{
        .skip = options.skip_id_check,
        .continue_on_mismatch = options.continue_on_id_mismatch,
    });

    var second_ctx: ?protocol.BeginContext = null;
    defer if (second_ctx) |ctx| ctx.deinit(allocator);
    if (options.erase) {
        try protocol.erase(info.programmer, trans, 0, 0);
        protocol.end(info.programmer, trans);
        protocol_open = false;
        second_ctx = try protocol.begin(allocator, info.programmer, trans, descriptor, device.algorithmFor(info.programmer));
        protocol_open = true;
    }

    if (options.unprotect_before) try protectOff(info.programmer, trans);

    var offset: usize = 0;
    const chunk_size = @max(@as(usize, descriptor.write_buffer_size), 1);
    while (offset < data.len) {
        const len = @min(chunk_size, data.len - offset);
        try protocol.writeBlock(info.programmer, trans, descriptor, options.memory, @intCast(offset), data[offset .. offset + len]);
        const status = try protocol.requestStatus(info.programmer, trans);
        if (status.overcurrent != 0) return Error.Overcurrent;
        if (status.error_code != 0) return Error.ProgrammerStatusError;
        offset += len;
    }

    if (options.protect_after) try protectOn(info.programmer, trans);

    if (options.verify) {
        var actual = try allocator.alloc(u8, data.len);
        defer allocator.free(actual);
        offset = 0;
        const read_chunk = readChunkSize(info.programmer, descriptor);
        while (offset < actual.len) {
            const len = @min(read_chunk, actual.len - offset);
            try protocol.readBlock(info.programmer, trans, options.memory, @intCast(offset), actual[offset .. offset + len]);
            offset += len;
        }
        if (!std.mem.eql(u8, data, actual)) return Error.VerifyFailed;
    }
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
    if (policy.skip or device.chip_id == 0 or device.chip_id_bytes_count == 0) return;
    const actual = try protocol.getChipId(programmer, trans, device.chip_id_bytes_count);
    if (actual.value != device.chip_id and !policy.continue_on_mismatch) return Error.ChipIdMismatch;
}

fn memorySize(device: catalog.DeviceRecord, memory: model.MemoryKind) usize {
    return switch (memory) {
        .code => device.code_memory_size,
        .data => device.data_memory_size,
        .user => device.data_memory2_size,
    };
}

fn readChunkSize(programmer: model.Programmer, descriptor: t48.Device) usize {
    const descriptor_chunk = @max(@as(usize, descriptor.read_buffer_size), 1);
    return if (programmer == .t56)
        @min(descriptor_chunk, protocol_bytes.packet.t56_read_payload_max)
    else
        descriptor_chunk;
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

test "writeROM uses T48 erase write status and verify sequence" {
    var response = [_]u8{0} ** 80;
    response[4] = 1;
    response[5] = 2;
    response[6] = 7;
    @memcpy(response[8..24], "2026-07-04......");
    response[12] = 0;
    @memcpy(response[24..32], "T48CODE!");
    @memcpy(response[32..54], "SERIAL-T48-00000000000");
    var verify_payload = [_]u8{ 0x12, 0x34, 0x56, 0x78 };
    var fake = transport_mod.FakeTransport.init(std.testing.allocator, &response);
    fake.payload_response = &verify_payload;
    defer fake.deinit();

    try writeROM(std.testing.allocator, fake.transport(), "AT28C64B", &verify_payload, .{ .programmer = .t48, .skip_id_check = true });

    try std.testing.expect(std.mem.indexOfScalar(u8, fake.sent.items, protocol_bytes.command.erase) != null);
    try std.testing.expect(std.mem.indexOfScalar(u8, fake.sent.items, protocol_bytes.command.write_code) != null);
    try std.testing.expect(std.mem.indexOfScalar(u8, fake.sent.items, protocol_bytes.command.read_code) != null);
    try std.testing.expectEqualSlices(u8, &verify_payload, fake.payload_sent.items);
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
    var verify_payload = [_]u8{ 0xff, 0xff, 0xff, 0xff };
    var data = [_]u8{ 0x12, 0x34, 0x56, 0x78 };
    var fake = transport_mod.FakeTransport.init(std.testing.allocator, &response);
    fake.payload_response = &verify_payload;
    defer fake.deinit();

    try std.testing.expectError(Error.VerifyFailed, writeROM(std.testing.allocator, fake.transport(), "AT28C64B", &data, .{ .programmer = .t48, .skip_id_check = true }));
}
