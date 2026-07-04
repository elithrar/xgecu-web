// SPDX-License-Identifier: Apache-2.0

const std = @import("std");
const model = @import("../core/model.zig");
const algorithm_name = @import("../core/algorithm_name.zig");
const t48 = @import("t48.zig");
const t56 = @import("t56.zig");
const transport = @import("transport.zig");

pub const Error = t48.Error || t56.Error || std.mem.Allocator.Error || error{
    UnsupportedProgrammer,
    ProgrammerInBootloader,
    AlgorithmUnavailable,
    ChipIdMismatch,
    ProgrammerStatusError,
    Overcurrent,
    EmptyMemoryRegion,
    InputTooLarge,
};

pub const BeginContext = struct {
    bitstream: ?[]u8 = null,

    pub fn deinit(self: BeginContext, allocator: std.mem.Allocator) void {
        if (self.bitstream) |bytes| allocator.free(bytes);
    }
};

pub fn begin(
    allocator: std.mem.Allocator,
    programmer: model.Programmer,
    trans: transport.Transport,
    descriptor: t48.Device,
    t56_bitstream: ?[]const u8,
) Error!BeginContext {
    return switch (programmer) {
        .t48 => {
            try t48.beginTransaction(trans, descriptor);
            return .{};
        },
        .t56 => {
            const source = t56_bitstream orelse return Error.AlgorithmUnavailable;
            if (source.len == 0) return Error.AlgorithmUnavailable;
            const owned = try allocator.dupe(u8, source);
            errdefer allocator.free(owned);
            try t56.beginTransaction(trans, descriptor, owned);
            return .{ .bitstream = owned };
        },
        else => Error.UnsupportedProgrammer,
    };
}

pub fn end(programmer: model.Programmer, trans: transport.Transport) void {
    switch (programmer) {
        .t48 => t48.endTransaction(trans) catch {},
        .t56 => t56.endTransaction(trans) catch {},
        else => {},
    }
}

pub fn readBlock(programmer: model.Programmer, trans: transport.Transport, kind: model.MemoryKind, address: u32, out: []u8) Error!void {
    return switch (programmer) {
        .t48 => t48.readBlock(trans, kind, address, out),
        .t56 => t56.readBlock(trans, kind, address, out),
        else => Error.UnsupportedProgrammer,
    };
}

pub fn writeBlock(programmer: model.Programmer, trans: transport.Transport, descriptor: t48.Device, kind: model.MemoryKind, address: u32, data: []const u8) Error!void {
    return switch (programmer) {
        .t48 => t48.writeBlock(trans, kind, address, data),
        .t56 => t56.writeBlock(trans, descriptor, kind, address, data),
        else => Error.UnsupportedProgrammer,
    };
}

pub fn getChipId(programmer: model.Programmer, trans: transport.Transport, chip_id_bytes_count: u8) Error!t48.ChipId {
    return switch (programmer) {
        .t48 => t48.getChipId(trans, chip_id_bytes_count),
        .t56 => t56.getChipId(trans, chip_id_bytes_count),
        else => Error.UnsupportedProgrammer,
    };
}

pub fn erase(programmer: model.Programmer, trans: transport.Transport, num_fuses: u8, pld: u8) Error!void {
    return switch (programmer) {
        .t48 => t48.erase(trans, num_fuses, pld),
        .t56 => t56.erase(trans, num_fuses, pld),
        else => Error.UnsupportedProgrammer,
    };
}

pub fn requestStatus(programmer: model.Programmer, trans: transport.Transport) Error!t48.Status {
    return switch (programmer) {
        .t48 => t48.requestStatus(trans),
        .t56 => t56.requestStatus(trans),
        else => Error.UnsupportedProgrammer,
    };
}

pub fn defaultSpiClock(programmer: model.Programmer, protocol_id: u8) u8 {
    _ = protocol_id;
    return switch (programmer) {
        .t48, .t56 => 0x01,
        else => 0,
    };
}

pub fn canAdjustClock(programmer: model.Programmer, protocol_id: u8) bool {
    return switch (programmer) {
        .t48, .t56 => protocol_id == 0x03 or protocol_id == 0x04 or protocol_id == 0x0f,
        else => false,
    };
}

pub fn algorithmName(buffer: []u8, programmer: model.Programmer, device: anytype) !?[]const u8 {
    if (programmer != .t56) return null;
    const flags = model.decodeFlags(device.flags_raw, device.voltages_raw, device.chip_info, device.protocol_id);
    return try algorithm_name.resolve(buffer, .{
        .programmer = programmer,
        .protocol_id = device.protocol_id,
        .variant = device.variant,
        .reversed_package = flags.reversed_package,
    });
}

test "protocol rejects unsupported programmer at dispatch boundary" {
    var fake = transport.FakeTransport.init(std.testing.allocator, &.{});
    defer fake.deinit();
    var out = [_]u8{0} ** 1;
    try std.testing.expectError(Error.UnsupportedProgrammer, readBlock(.auto, fake.transport(), .code, 0, &out));
}

test "T56 begin requires a non-empty algorithm bitstream" {
    var fake = transport.FakeTransport.init(std.testing.allocator, &.{});
    defer fake.deinit();
    const device = t48.Device{
        .protocol_id = 0,
        .variant = 0,
        .voltages_raw = 0,
        .chip_info = 0,
        .pin_map = 0,
        .data_memory_size = 0,
        .data_memory2_size = 0,
        .page_size = 0,
        .pulse_delay = 0,
        .code_memory_size = 0,
        .package_details_raw = 0,
        .read_buffer_size = 0,
        .write_buffer_size = 0,
        .flags_raw = 0,
    };
    try std.testing.expectError(Error.AlgorithmUnavailable, begin(std.testing.allocator, .t56, fake.transport(), device, null));
    try std.testing.expectError(Error.AlgorithmUnavailable, begin(std.testing.allocator, .t56, fake.transport(), device, &.{}));
}
