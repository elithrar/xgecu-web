// SPDX-License-Identifier: GPL-3.0-or-later

pub const cli = @import("cli.zig");
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
pub const formats = struct {
    pub const bin = @import("formats/bin.zig");
    pub const ihex = @import("formats/ihex.zig");
    pub const image = @import("formats/image.zig");
    pub const jedec = @import("formats/jedec.zig");
    pub const srec = @import("formats/srec.zig");
};
pub const db = struct {
    pub const import_algorithm = @import("db/import_algorithm.zig");
    pub const import_infoic = @import("db/import_infoic.zig");
    pub const import_logicic = @import("db/import_logicic.zig");
    pub const sqlite = @import("db/sqlite.zig");
    pub const xml_scan = @import("db/xml_scan.zig");
};
pub const programmer = struct {
    pub const session = @import("programmer/session.zig");
    pub const t48 = @import("programmer/t48.zig");
    pub const t56 = @import("programmer/t56.zig");
    pub const t76 = @import("programmer/t76.zig");
    pub const tl866ii = @import("programmer/tl866ii.zig");
    pub const transport = @import("programmer/transport.zig");
    pub const usb = @import("programmer/usb.zig");
};

test {
    @import("std").testing.refAllDecls(@This());
}
