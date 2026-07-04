// SPDX-License-Identifier: GPL-3.0-or-later

pub const core = struct {
    pub const algorithm_name = @import("core/algorithm_name.zig");
    pub const algorithm_payload = @import("core/algorithm_payload.zig");
    pub const crc = @import("core/crc.zig");
    pub const endian = @import("core/endian.zig");
    pub const fuses = @import("core/fuses.zig");
    pub const gal = @import("core/gal.zig");
    pub const logic = @import("core/logic.zig");
    pub const model = @import("core/model.zig");
};
pub const programmer = struct {
    pub const protocol = @import("programmer/protocol.zig");
    pub const session = @import("programmer/session.zig");
    pub const t48 = @import("programmer/t48.zig");
    pub const t56 = @import("programmer/t56.zig");
    pub const transport = @import("programmer/transport.zig");
};
pub const catalog = @import("catalog/catalog.zig");
pub const rom = @import("ops/rom.zig");
pub const wasm = @import("wasm/abi.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
