// SPDX-License-Identifier: GPL-3.0-or-later

const std = @import("std");
const model = @import("model.zig");

pub const Options = struct {
    programmer: model.Programmer,
    protocol_id: u8,
    variant: u32,
    reversed_package: bool = false,
    icsp: bool = false,
    v_1v8: bool = false,
};

pub fn resolve(buffer: []u8, options: Options) ![]const u8 {
    if (options.programmer != .t56 and options.programmer != .t76) return error.UnsupportedProgrammer;

    const algorithm_number: u8 = @intCast((options.variant >> 8) & 0xff);
    if (options.protocol_id == 0) return resolveUtility(buffer, options.programmer, algorithm_number);
    if (options.protocol_id > algorithm_prefixes.len) return error.InvalidAlgorithmNumber;

    const prefix = algorithm_prefixes[options.protocol_id - 1];
    if (prefix.len == 0) return error.InvalidAlgorithmNumber;

    return switch (options.protocol_id) {
        0x1d => if (options.icsp) std.fmt.bufPrint(buffer, "{s}11S", .{prefix}) else std.fmt.bufPrint(buffer, "{s}{X:0>2}", .{ prefix, algorithm_number }),
        0x21 => if (options.icsp) std.fmt.bufPrint(buffer, "{s}2S", .{prefix}) else std.fmt.bufPrint(buffer, "{s}{X:0>2}", .{ prefix, algorithm_number }),
        0x31 => std.fmt.bufPrint(buffer, "{s}{x:0>2}_{s}", .{ prefix, algorithm_number, if (options.v_1v8) "18" else "33" }),
        else => if (options.reversed_package)
            std.fmt.bufPrint(buffer, "{s}{X:0>2}R", .{ prefix, algorithm_number })
        else
            std.fmt.bufPrint(buffer, "{s}{X:0>2}", .{ prefix, algorithm_number }),
    };
}

fn resolveUtility(buffer: []u8, programmer: model.Programmer, algorithm_number: u8) ![]const u8 {
    const table = switch (programmer) {
        .t56 => t56_utility_algorithms[0..],
        .t76 => t76_utility_algorithms[0..],
        else => return error.UnsupportedProgrammer,
    };
    if (algorithm_number >= table.len) return error.InvalidAlgorithmNumber;
    return std.fmt.bufPrint(buffer, "{s}", .{table[algorithm_number]});
}

const algorithm_prefixes = [_][]const u8{
    "IIC24C", "MW93ALG", "SPI25F", "AT45D", "F29EE", "W29F32P",
    "ROM28P", "ROM32P", "ROM40P", "R28TO32P", "ROM24P", "ROM44",
    "EE28C32P", "RAM32", "SPI25F", "28F32P", "FWH", "T48",
    "T40A", "T40B", "T88V", "PIC32X", "P18F87J", "P16F",
    "P18F2", "P16F5X", "P16CX", "", "ATMGA_", "ATTINY_",
    "AT89P20_", "", "AT89C_", "P87C_", "SST89_", "W78E_",
    "", "", "ROM24P", "ROM28P", "RAM32", "GAL16",
    "GAL20", "GAL22", "NAND_", "PIC32X", "RAM36", "KB90",
    "EMMC_", "VGA_", "CPLD_", "GEN_", "ITE_",
};

const t56_utility_algorithms = [_][]const u8{
    "TTL1", "TTL2", "Pindect100M", "STGND", "StPVGI", "uart_vga", "vga_11", "vga_21",
    "vga1024x768", "vga1152x864", "vga1280x1024", "vga1280x800", "vga1440x900", "vga1920x1080", "vga640x480", "vga800x600", "vga_hdmi",
};

const t76_utility_algorithms = [_][]const u8{
    "Test_100M", "TestGND", "TestLgcDown", "TestLgcPull", "TestVcc",
};

test "resolve normal T56/T76 algorithm names" {
    var buffer: [32]u8 = undefined;
    try std.testing.expectEqualStrings("ROM28P00", try resolve(&buffer, .{ .programmer = .t56, .protocol_id = 0x07, .variant = 0x0000 }));
    try std.testing.expectEqualStrings("ROM28P02R", try resolve(&buffer, .{ .programmer = .t76, .protocol_id = 0x07, .variant = 0x0200, .reversed_package = true }));
    try std.testing.expectEqualStrings("ATMGA_11S", try resolve(&buffer, .{ .programmer = .t56, .protocol_id = 0x1d, .variant = 0x0500, .icsp = true }));
    try std.testing.expectEqualStrings("AT89C_2S", try resolve(&buffer, .{ .programmer = .t76, .protocol_id = 0x21, .variant = 0x0100, .icsp = true }));
    try std.testing.expectEqualStrings("EMMC_03_18", try resolve(&buffer, .{ .programmer = .t76, .protocol_id = 0x31, .variant = 0x0300, .v_1v8 = true }));
}

test "resolve utility algorithm names" {
    var buffer: [32]u8 = undefined;
    try std.testing.expectEqualStrings("TTL2", try resolve(&buffer, .{ .programmer = .t56, .protocol_id = 0, .variant = 0x0100 }));
    try std.testing.expectEqualStrings("TestLgcPull", try resolve(&buffer, .{ .programmer = .t76, .protocol_id = 0, .variant = 0x0300 }));
}
