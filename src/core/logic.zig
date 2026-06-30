// SPDX-License-Identifier: GPL-3.0-or-later

const std = @import("std");

pub const State = enum(u4) {
    zero = 0,
    one = 1,
    low = 2,
    high = 3,
    clock = 4,
    z = 5,
    x = 6,
    ground = 7,
    vcc = 8,
};

pub const Error = error{
    InvalidLogicState,
    TooManyPins,
    ShortVector,
};

pub fn parseStates(allocator: std.mem.Allocator, text: []const u8) ![]State {
    var states: std.ArrayListUnmanaged(State) = .empty;
    errdefer states.deinit(allocator);
    var parts = std.mem.tokenizeAny(u8, text, " \t\r\n");
    while (parts.next()) |part| {
        if (part.len != 1) return Error.InvalidLogicState;
        try states.append(allocator, try parseState(part[0]));
    }
    return try states.toOwnedSlice(allocator);
}

pub fn parseState(ch: u8) !State {
    return switch (ch) {
        '0' => .zero,
        '1' => .one,
        'L', 'l' => .low,
        'H', 'h' => .high,
        'C', 'c' => .clock,
        'Z', 'z' => .z,
        'X', 'x' => .x,
        'G', 'g' => .ground,
        'V', 'v' => .vcc,
        else => Error.InvalidLogicState,
    };
}

pub fn stateChar(state: State) u8 {
    return switch (state) {
        .zero => '0',
        .one => '1',
        .low => 'L',
        .high => 'H',
        .clock => 'C',
        .z => 'Z',
        .x => 'X',
        .ground => 'G',
        .vcc => 'V',
    };
}

pub fn packNibbles(out: []u8, states: []const State) !void {
    const byte_count = (states.len + 1) / 2;
    if (out.len < byte_count) return Error.TooManyPins;
    @memset(out[0..byte_count], 0xff);
    for (states, 0..) |state, index| {
        const value: u8 = @intFromEnum(state);
        if ((index & 1) == 0) {
            out[index / 2] = (out[index / 2] & 0xf0) | value;
        } else {
            out[index / 2] = (out[index / 2] & 0x0f) | (value << 4);
        }
    }
}

pub fn unpackNibbles(out: []u8, bytes: []const u8, pin_count: usize) !void {
    if (out.len < pin_count) return Error.ShortVector;
    if (bytes.len < (pin_count + 1) / 2) return Error.ShortVector;
    for (out[0..pin_count], 0..) |*value, index| {
        value.* = (bytes[index / 2] >> @intCast(4 * (index & 1))) & 0x0f;
    }
}

test "parse logic vector states" {
    const states = try parseStates(std.testing.allocator, "0 H C Z X G V");
    defer std.testing.allocator.free(states);
    try std.testing.expectEqualSlices(State, &.{ .zero, .high, .clock, .z, .x, .ground, .vcc }, states);
}

test "pack and unpack two pins per byte" {
    const states = [_]State{ .zero, .high, .ground, .vcc, .one };
    var encoded = [_]u8{0} ** 3;
    try packNibbles(&encoded, &states);
    try std.testing.expectEqualSlices(u8, &.{ 0x30, 0x87, 0xf1 }, &encoded);
    var unpacked = [_]u8{0} ** states.len;
    try unpackNibbles(&unpacked, &encoded, states.len);
    try std.testing.expectEqualSlices(u8, &.{ 0, 3, 7, 8, 1 }, &unpacked);
}
