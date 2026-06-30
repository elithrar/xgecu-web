// SPDX-License-Identifier: GPL-3.0-or-later

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    linkSqlite(exe_module);
    linkLibusb(exe_module);
    const exe = b.addExecutable(.{
        .name = "minipro-zig",
        .root_module = exe_module,
    });
    b.installArtifact(exe);
    b.installFile("README.md", "share/doc/minipro-zig/README.md");
    b.installFile("docs/linux.md", "share/doc/minipro-zig/linux.md");
    b.installFile("docs/minipro-zig.1", "share/man/man1/minipro-zig.1");
    b.installFile("completions/minipro-zig.bash", "share/bash-completion/completions/minipro-zig");
    b.installFile("completions/minipro-zig.fish", "share/fish/vendor_completions.d/minipro-zig.fish");
    b.installFile("completions/_minipro-zig", "share/zsh/site-functions/_minipro-zig");
    b.installFile("src/db/schema.sql", "share/minipro-zig/schema.sql");
    b.installFile("packaging/60-minipro-zig.rules", "lib/udev/rules.d/60-minipro-zig.rules");

    const compare_module = b.createModule(.{
        .root_source_file = b.path("tools/compare_cli.zig"),
        .target = target,
        .optimize = optimize,
    });
    const compare_exe = b.addExecutable(.{
        .name = "compare_cli",
        .root_module = compare_module,
    });
    b.installArtifact(compare_exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run minipro-zig");
    run_step.dependOn(&run_cmd.step);

    const unit_test_module = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    linkSqlite(unit_test_module);
    linkLibusb(unit_test_module);
    const unit_tests = b.addTest(.{
        .root_module = unit_test_module,
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);

    const exe_test_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    linkSqlite(exe_test_module);
    linkLibusb(exe_test_module);
    const exe_tests = b.addTest(.{
        .root_module = exe_test_module,
    });
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
    test_step.dependOn(&run_exe_tests.step);
}

fn linkSqlite(module: *std.Build.Module) void {
    module.linkSystemLibrary("c", .{});
    module.linkSystemLibrary("sqlite3", .{});
}

fn linkLibusb(module: *std.Build.Module) void {
    module.linkSystemLibrary("c", .{});
    module.linkSystemLibrary("usb-1.0", .{});
}
