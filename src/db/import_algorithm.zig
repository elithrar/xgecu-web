// SPDX-License-Identifier: GPL-3.0-or-later

const std = @import("std");
const xml_scan = @import("xml_scan.zig");

pub const Algorithm = struct {
    programmer: []const u8,
    name: []const u8,
    gzip_base64: []const u8,
};

pub const Iterator = struct {
    scanner: xml_scan.Scanner,
    programmer: ?[]const u8 = null,

    pub fn next(self: *Iterator) !?Algorithm {
        while (self.scanner.next()) |tag| {
            if (tag.closing) {
                if (std.mem.eql(u8, tag.name, "algorithms_T56") or std.mem.eql(u8, tag.name, "algorithms_T76")) {
                    self.programmer = null;
                }
                continue;
            }

            if (std.mem.eql(u8, tag.name, "algorithms_T56")) {
                self.programmer = "t56";
                continue;
            }
            if (std.mem.eql(u8, tag.name, "algorithms_T76")) {
                self.programmer = "t76";
                continue;
            }
            if (!std.mem.eql(u8, tag.name, "algorithm")) continue;
            const programmer = self.programmer orelse continue;
            return .{
                .programmer = programmer,
                .name = xml_scan.attr(tag.attrs, "name") orelse return error.InvalidAlgorithmXml,
                .gzip_base64 = xml_scan.attr(tag.attrs, "bitstream") orelse return error.InvalidAlgorithmXml,
            };
        }
        return null;
    }
};

pub fn iterator(xml: []const u8) Iterator {
    return .{ .scanner = .{ .xml = xml } };
}

test "parse T56 and T76 algorithms" {
    const xml =
        \\<database type="ALGORITHMS">
        \\  <algorithms_T56>
        \\    <algorithm name="ROM28P00" bitstream="H4sI" />
        \\  </algorithms_T56>
        \\  <algorithms_T76>
        \\    <algorithm name="IIC24C00" bitstream="AAAA" />
        \\  </algorithms_T76>
        \\</database>
    ;

    var it = iterator(xml);
    const first = (try it.next()).?;
    try std.testing.expectEqualStrings("t56", first.programmer);
    try std.testing.expectEqualStrings("ROM28P00", first.name);
    try std.testing.expectEqualStrings("H4sI", first.gzip_base64);

    const second = (try it.next()).?;
    try std.testing.expectEqualStrings("t76", second.programmer);
    try std.testing.expectEqualStrings("IIC24C00", second.name);
    try std.testing.expectEqualStrings("AAAA", second.gzip_base64);
    try std.testing.expect((try it.next()) == null);
}
