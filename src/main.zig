// SPDX-License-Identifier: GPL-3.0-or-later

const std = @import("std");
const cli = @import("cli.zig");

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);

    var stdout_buffer: [4096]u8 = undefined;
    var stderr_buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(init.io, &stdout_buffer);
    var stderr = std.Io.File.stderr().writerStreaming(init.io, &stderr_buffer);

    const result = cli.run(allocator, init.io, args, &stdout.interface, &stderr.interface);
    if (result) |code| {
        try stdout.flush();
        try stderr.flush();
        std.process.exit(code);
    } else |err| switch (err) {
        else => {
            try stderr.interface.print("minipro-zig: {s}\n", .{@errorName(err)});
            try stderr.flush();
            std.process.exit(1);
        },
    }
}

test {
    std.testing.refAllDecls(@import("root.zig"));
}
