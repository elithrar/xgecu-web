// SPDX-License-Identifier: Apache-2.0

const model = @import("../core/model.zig");
const t48 = @import("../programmer/t48.zig");
const protocol = @import("../programmer/protocol.zig");

pub const DeviceRecord = struct {
    canonical_name: []const u8,
    aliases: []const []const u8,
    programmers: []const model.Programmer,
    chip_type: model.ChipType,
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
    can_adjust_clock: bool = false,
    chip_id: u32 = 0,
    chip_id_bytes_count: u8 = 0,
    blank_value: u8 = 0xff,
    t56_algorithm: ?[]const u8 = null,

    pub fn supports(self: DeviceRecord, programmer: model.Programmer) bool {
        if (programmer == .auto) return true;
        if (programmer == .t56 and self.t56_algorithm == null) return false;
        for (self.programmers) |entry| {
            if (entry == programmer) return true;
        }
        return false;
    }

    pub fn algorithmFor(self: DeviceRecord, programmer: model.Programmer) ?[]const u8 {
        return switch (programmer) {
            .t56 => self.t56_algorithm,
            else => null,
        };
    }

    pub fn descriptor(self: DeviceRecord, programmer: model.Programmer) t48.Device {
        var out = t48.deviceFromProtocolInfo(self, 0, protocol.defaultSpiClock(programmer, self.protocol_id));
        out.can_adjust_clock = protocol.canAdjustClock(programmer, self.protocol_id);
        return out;
    }
};

pub const DeviceSummary = struct {
    name: []const u8,
    code_memory_size: u32,
    data_memory_size: u32,
    package_pins: u8,
    supports_t48: bool,
    supports_t56: bool,
};
