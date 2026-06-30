// SPDX-License-Identifier: GPL-3.0-or-later

const std = @import("std");

pub const Tag = struct {
    name: []const u8,
    attrs: []const u8,
    self_closing: bool,
    start: usize,
    end: usize,
    closing: bool,
};

pub const Scanner = struct {
    xml: []const u8,
    index: usize = 0,

    pub fn next(self: *Scanner) ?Tag {
        while (self.index < self.xml.len) {
            const open_rel = std.mem.indexOfScalar(u8, self.xml[self.index..], '<') orelse return null;
            const open = self.index + open_rel;
            const close_rel = std.mem.indexOfScalar(u8, self.xml[open..], '>') orelse return null;
            const close = open + close_rel;
            self.index = close + 1;

            var body = std.mem.trim(u8, self.xml[open + 1 .. close], " \t\r\n");
            if (body.len == 0) continue;
            if (body[0] == '?' or body[0] == '!') continue;

            const closing = body[0] == '/';
            if (closing) body = std.mem.trimStart(u8, body[1..], " \t\r\n");

            const self_closing = !closing and body.len != 0 and body[body.len - 1] == '/';
            if (self_closing) body = std.mem.trimEnd(u8, body[0 .. body.len - 1], " \t\r\n");

            const name_end = indexOfWhitespace(body) orelse body.len;
            const name = body[0..name_end];
            const attrs = std.mem.trim(u8, body[name_end..], " \t\r\n");
            return .{
                .name = name,
                .attrs = attrs,
                .self_closing = self_closing,
                .start = open,
                .end = close + 1,
                .closing = closing,
            };
        }
        return null;
    }
};

pub fn attr(attrs: []const u8, name: []const u8) ?[]const u8 {
    var index: usize = 0;
    while (index < attrs.len) {
        while (index < attrs.len and isSpace(attrs[index])) index += 1;
        if (index >= attrs.len) return null;

        const key_start = index;
        while (index < attrs.len and attrs[index] != '=' and !isSpace(attrs[index])) index += 1;
        const key = attrs[key_start..index];

        while (index < attrs.len and isSpace(attrs[index])) index += 1;
        if (index >= attrs.len or attrs[index] != '=') return null;
        index += 1;
        while (index < attrs.len and isSpace(attrs[index])) index += 1;
        if (index >= attrs.len or attrs[index] != '"') return null;
        index += 1;

        const value_start = index;
        while (index < attrs.len and attrs[index] != '"') index += 1;
        if (index >= attrs.len) return null;
        const value = attrs[value_start..index];
        index += 1;

        if (std.mem.eql(u8, key, name)) return value;
    }
    return null;
}

pub fn parseInt(text: []const u8) !u32 {
    if (text.len > 2 and text[0] == '0' and (text[1] == 'x' or text[1] == 'X')) {
        return std.fmt.parseInt(u32, text[2..], 16);
    }
    return std.fmt.parseInt(u32, text, 10);
}

fn indexOfWhitespace(bytes: []const u8) ?usize {
    for (bytes, 0..) |byte, index| {
        if (isSpace(byte)) return index;
    }
    return null;
}

fn isSpace(byte: u8) bool {
    return switch (byte) {
        ' ', '\t', '\r', '\n' => true,
        else => false,
    };
}

test "scanner skips declarations and comments" {
    var scanner = Scanner{ .xml =
        \\<?xml version="1.0"?>
        \\<!-- comment -->
        \\<infoic><database type="INFOIC" /></infoic>
    };

    const infoic = scanner.next().?;
    try std.testing.expectEqualStrings("infoic", infoic.name);
    try std.testing.expect(!infoic.closing);
    try std.testing.expect(!infoic.self_closing);

    const database = scanner.next().?;
    try std.testing.expectEqualStrings("database", database.name);
    try std.testing.expect(database.self_closing);
    try std.testing.expectEqualStrings("INFOIC", attr(database.attrs, "type").?);

    const close = scanner.next().?;
    try std.testing.expect(close.closing);
    try std.testing.expectEqualStrings("infoic", close.name);
    try std.testing.expect(scanner.next() == null);
}

test "attr handles upstream multiline spacing" {
    const attrs =
        \\name="AT28C64B,AT28C64"
        \\  protocol_id="0x01"
        \\  flags="32"
    ;
    try std.testing.expectEqualStrings("AT28C64B,AT28C64", attr(attrs, "name").?);
    try std.testing.expectEqual(@as(u32, 0x01), try parseInt(attr(attrs, "protocol_id").?));
    try std.testing.expectEqual(@as(u32, 32), try parseInt(attr(attrs, "flags").?));
    try std.testing.expect(attr(attrs, "missing") == null);
}
