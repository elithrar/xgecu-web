// SPDX-License-Identifier: GPL-3.0-or-later

const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);

    if (args.len < 3) {
        try writeStderr(init.io,
            \\Usage: compare_cli <c-minipro> <zig-minipro> [--c-prefix <args...>] [--zig-prefix <args...>] -- <args...>
            \\
        );
        std.process.exit(2);
    }

    var split_index: ?usize = null;
    for (args, 0..) |arg, index| {
        if (std.mem.eql(u8, arg, "--")) {
            split_index = index;
            break;
        }
    }
    const sep = split_index orelse {
        try writeStderr(init.io, "missing '--' separator\n");
        std.process.exit(2);
    };
    if (sep < 3) {
        try writeStderr(init.io, "missing binary paths\n");
        std.process.exit(2);
    }

    const prefixes = parsePrefixes(args[3..sep]) catch |err| {
        try writeStderr(init.io, parseErrorMessage(err));
        std.process.exit(2);
    };
    const shared_args = args[sep + 1 ..];

    const c_args = try joinArgs(allocator, prefixes.c_prefix, shared_args);
    defer allocator.free(c_args);
    const c_result = try runChild(allocator, init.io, args[1], c_args);
    defer allocator.free(c_result.stdout);
    defer allocator.free(c_result.stderr);

    const zig_args = try joinArgs(allocator, prefixes.zig_prefix, shared_args);
    defer allocator.free(zig_args);
    const zig_result = try runChild(allocator, init.io, args[2], zig_args);
    defer allocator.free(zig_result.stdout);
    defer allocator.free(zig_result.stderr);

    const c_stdout = try normalize(allocator, c_result.stdout);
    defer allocator.free(c_stdout);
    const zig_stdout = try normalize(allocator, zig_result.stdout);
    defer allocator.free(zig_stdout);
    const c_stderr = try normalize(allocator, c_result.stderr);
    defer allocator.free(c_stderr);
    const zig_stderr = try normalize(allocator, zig_result.stderr);
    defer allocator.free(zig_stderr);

    if (!std.meta.eql(c_result.term, zig_result.term) or
        !std.mem.eql(u8, c_stdout, zig_stdout) or
        !std.mem.eql(u8, c_stderr, zig_stderr))
    {
        var buffer: [4096]u8 = undefined;
        var stderr = std.Io.File.stderr().writerStreaming(init.io, &buffer);
        try stderr.interface.writeAll("CLI output differs\n");
        try stderr.interface.print("C exit: {any}\nZig exit: {any}\n", .{ c_result.term, zig_result.term });
        try printFirstDifference(&stderr.interface, "stdout", c_stdout, zig_stdout);
        try printFirstDifference(&stderr.interface, "stderr", c_stderr, zig_stderr);
        try stderr.flush();
        std.process.exit(1);
    }
}

const Prefixes = struct {
    c_prefix: []const []const u8 = &.{},
    zig_prefix: []const []const u8 = &.{},
};

fn parsePrefixes(args: []const []const u8) !Prefixes {
    var prefixes = Prefixes{};
    var index: usize = 0;
    while (index < args.len) {
        const marker = args[index];
        if (!std.mem.eql(u8, marker, "--c-prefix") and !std.mem.eql(u8, marker, "--zig-prefix")) return error.UnknownOption;
        index += 1;
        const start = index;
        while (index < args.len and !std.mem.eql(u8, args[index], "--c-prefix") and !std.mem.eql(u8, args[index], "--zig-prefix")) : (index += 1) {}
        if (std.mem.eql(u8, marker, "--c-prefix")) {
            prefixes.c_prefix = args[start..index];
        } else {
            prefixes.zig_prefix = args[start..index];
        }
    }
    return prefixes;
}

fn parseErrorMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.UnknownOption => "unknown compare_cli prefix option\n",
        else => "invalid compare_cli arguments\n",
    };
}

fn joinArgs(allocator: std.mem.Allocator, prefix: []const []const u8, shared: []const []const u8) ![]const []const u8 {
    const joined = try allocator.alloc([]const u8, prefix.len + shared.len);
    @memcpy(joined[0..prefix.len], prefix);
    @memcpy(joined[prefix.len..], shared);
    return joined;
}

fn writeStderr(io: std.Io, bytes: []const u8) !void {
    var buffer: [1024]u8 = undefined;
    var stderr = std.Io.File.stderr().writerStreaming(io, &buffer);
    try stderr.interface.writeAll(bytes);
    try stderr.flush();
}

fn printFirstDifference(writer: anytype, name: []const u8, c_output: []const u8, zig_output: []const u8) !void {
    if (std.mem.eql(u8, c_output, zig_output)) {
        try writer.print("{s}: match ({d} bytes)\n", .{ name, c_output.len });
        return;
    }
    try writer.print("{s}: C {d} bytes, Zig {d} bytes\n", .{ name, c_output.len, zig_output.len });

    var c_lines = std.mem.splitScalar(u8, c_output, '\n');
    var zig_lines = std.mem.splitScalar(u8, zig_output, '\n');
    var line_number: usize = 1;
    while (true) : (line_number += 1) {
        const c_line = c_lines.next();
        const zig_line = zig_lines.next();
        if (c_line == null and zig_line == null) return;
        if (c_line == null or zig_line == null or !std.mem.eql(u8, c_line.?, zig_line.?)) {
            try writer.print("first {s} diff at line {d}\n", .{ name, line_number });
            try writer.print("C: {s}\n", .{c_line orelse "<EOF>"});
            try writer.print("Zig: {s}\n", .{zig_line orelse "<EOF>"});
            return;
        }
    }
}

fn runChild(allocator: std.mem.Allocator, io: std.Io, exe: []const u8, child_args: []const []const u8) !std.process.RunResult {
    var argv = try allocator.alloc([]const u8, child_args.len + 1);
    defer allocator.free(argv);
    argv[0] = exe;
    @memcpy(argv[1..], child_args);
    return std.process.run(allocator, io, .{
        .argv = argv,
        .stdout_limit = .limited(10 * 1024 * 1024),
        .stderr_limit = .limited(10 * 1024 * 1024),
    });
}

fn normalize(allocator: std.mem.Allocator, output: []const u8) ![]const u8 {
    var normalized: std.ArrayListUnmanaged(u8) = .empty;
    errdefer normalized.deinit(allocator);

    var remaining = output;
    var skipped_override = false;
    while (remaining.len != 0) {
        const newline_index = std.mem.indexOfScalar(u8, remaining, '\n');
        const line_end = newline_index orelse remaining.len;
        const line = remaining[0..line_end];
        const has_newline = newline_index != null;
        remaining = if (has_newline) remaining[line_end + 1 ..] else remaining[line_end..];

        if (std.mem.startsWith(u8, line, "Using overridden database file ")) {
            skipped_override = true;
            continue;
        }
        if (skipped_override and line.len == 0 and std.mem.startsWith(u8, remaining, "Device ")) {
            skipped_override = false;
            continue;
        }
        skipped_override = false;
        try normalized.appendSlice(allocator, line);
        if (has_newline) try normalized.append(allocator, '\n');
    }

    return normalized.toOwnedSlice(allocator);
}
