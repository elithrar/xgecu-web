// SPDX-License-Identifier: Apache-2.0
//! Programmer-specific protocol guardrails shared by native Zig and Wasm.
//!
//! Packet encoding remains in the model modules, while this table owns the
//! safety-relevant differences that control sequencing and response validation.

const endian = @import("../core/endian.zig");
const model = @import("../core/model.zig");
const protocol_bytes = @import("protocol_bytes.zig");

const packet = protocol_bytes.packet;

pub const EraseResponse = enum {
    t48_short_ack_or_status,
    status,
    full_frame_status,
};

pub const ProtocolCapabilities = struct {
    requires_algorithm: bool,
    requires_verified_write: bool,
    status_after_read_block: bool,
    status_after_write_block: bool,
    status_after_protection: bool,
    erase_response: EraseResponse,
    reset_fpga_after_operation: bool,
    supports_pin_check: bool,
};

pub fn forProgrammer(programmer: model.Programmer) ?ProtocolCapabilities {
    return switch (programmer) {
        .t48 => .{
            .requires_algorithm = false,
            .requires_verified_write = false,
            .status_after_read_block = true,
            .status_after_write_block = true,
            .status_after_protection = true,
            .erase_response = .t48_short_ack_or_status,
            .reset_fpga_after_operation = false,
            .supports_pin_check = true,
        },
        .t56 => .{
            .requires_algorithm = true,
            .requires_verified_write = false,
            .status_after_read_block = true,
            .status_after_write_block = true,
            .status_after_protection = true,
            .erase_response = .status,
            .reset_fpga_after_operation = false,
            .supports_pin_check = false,
        },
        .t76 => .{
            .requires_algorithm = true,
            .requires_verified_write = true,
            .status_after_read_block = false,
            .status_after_write_block = false,
            .status_after_protection = false,
            .erase_response = .full_frame_status,
            .reset_fpga_after_operation = true,
            .supports_pin_check = false,
        },
        .auto => null,
    };
}

pub const Status = struct {
    error_code: u8,
    address: u32,
    c1: u16,
    c2: u16,
    overcurrent: u8,
};

pub const ResponseValidation = union(enum) {
    ok,
    short: usize,
    overcurrent,
    programmer_status_error,
};

pub fn validateStatusResponse(data: []const u8) ResponseValidation {
    if (data.len < 13) return .{ .short = 13 };
    if (data[12] != 0) return .overcurrent;
    if (data[0] != 0) return .programmer_status_error;
    return .ok;
}

pub fn validateEraseResponse(programmer: model.Programmer, data: []const u8) ResponseValidation {
    const capabilities = forProgrammer(programmer) orelse return .programmer_status_error;
    switch (capabilities.erase_response) {
        .t48_short_ack_or_status => {
            if (data.len == packet.t48_erase_ack_len) return .ok;
            if (data.len < packet.t48_erase_ack_len) return .{ .short = packet.t48_erase_ack_len };
        },
        .status => {},
        .full_frame_status => {
            if (data.len < packet.erase_response_len) return .{ .short = packet.erase_response_len };
        },
    }
    return validateStatusResponse(data);
}

pub fn parseStatus(data: []const u8) ?Status {
    if (data.len < 13) return null;
    return .{
        .error_code = data[0],
        .address = @intCast(endian.loadInt(data[8..12], .little)),
        .c1 = @intCast(endian.loadInt(data[2..4], .little)),
        .c2 = @intCast(endian.loadInt(data[4..6], .little)),
        .overcurrent = data[12],
    };
}

test "protocol capability table captures programmer guardrail differences" {
    const t48 = forProgrammer(.t48).?;
    const t56 = forProgrammer(.t56).?;
    const t76 = forProgrammer(.t76).?;

    try @import("std").testing.expect(t48.status_after_read_block);
    try @import("std").testing.expect(t56.status_after_read_block);
    try @import("std").testing.expect(!t76.status_after_read_block);
    try @import("std").testing.expect(t48.status_after_write_block);
    try @import("std").testing.expect(t56.status_after_write_block);
    try @import("std").testing.expect(!t76.status_after_write_block);
    try @import("std").testing.expect(!t48.requires_algorithm);
    try @import("std").testing.expect(t56.requires_algorithm);
    try @import("std").testing.expect(t76.requires_algorithm);
    try @import("std").testing.expect(!t48.requires_verified_write);
    try @import("std").testing.expect(!t56.requires_verified_write);
    try @import("std").testing.expect(t76.requires_verified_write);
    try @import("std").testing.expect(t48.supports_pin_check);
    try @import("std").testing.expect(!t56.supports_pin_check);
    try @import("std").testing.expect(!t76.supports_pin_check);
}

test "erase response validation preserves each programmer's contract" {
    const testing = @import("std").testing;
    var response = [_]u8{0} ** packet.erase_response_len;

    try testing.expectEqual(ResponseValidation{ .short = 8 }, validateEraseResponse(.t48, response[0..7]));
    try testing.expectEqual(ResponseValidation.ok, validateEraseResponse(.t48, response[0..8]));
    try testing.expectEqual(ResponseValidation{ .short = 13 }, validateEraseResponse(.t48, response[0..12]));
    try testing.expectEqual(ResponseValidation.ok, validateEraseResponse(.t48, response[0..13]));

    try testing.expectEqual(ResponseValidation{ .short = 13 }, validateEraseResponse(.t56, response[0..12]));
    try testing.expectEqual(ResponseValidation.ok, validateEraseResponse(.t56, response[0..13]));

    try testing.expectEqual(ResponseValidation{ .short = packet.erase_response_len }, validateEraseResponse(.t76, response[0 .. packet.erase_response_len - 1]));
    try testing.expectEqual(ResponseValidation.ok, validateEraseResponse(.t76, &response));

    response[12] = 1;
    try testing.expectEqual(ResponseValidation.overcurrent, validateEraseResponse(.t56, response[0..13]));
    try testing.expectEqual(ResponseValidation.overcurrent, validateEraseResponse(.t76, &response));
}
