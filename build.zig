const std = @import("std");
const assert = std.debug.assert;
const zbs = std.build;
const fs = std.fs;
const mem = std.mem;

const Scanner = @import("deps/zig-wayland/build.zig").Scanner;

/// While a waylock release is in development, this string should contain the version in
/// development with the "-dev" suffix.
/// When a release is tagged, the "-dev" suffix should be removed for the commit that gets tagged.
/// Directly after the tagged commit, the version should be bumped and the "-dev" suffix added.
const version = "0.7.0-dev";

pub fn build(b: *zbs.Builder) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const strip = b.option(bool, "strip", "Omit debug information") orelse false;
    const pie = b.option(bool, "pie", "Build a Position Independent Executable") orelse false;

    const man_pages = b.option(
        bool,
        "man-pages",
        "Set to true to build man pages. Requires scdoc. Defaults to true if scdoc is found.",
    ) orelse scdoc_found: {
        _ = b.findProgram(&[_][]const u8{"scdoc"}, &[_][]const u8{}) catch |err| switch (err) {
            error.FileNotFound => break :scdoc_found false,
            else => return err,
        };
        break :scdoc_found true;
    };

    if (man_pages) {
        const scdoc = b.addSystemCommand(&.{"scdoc"});
        scdoc.stdin = try fs.cwd().readFileAlloc(b.allocator, "doc/waylock.1.scd", 1024 * 1024);
        const stdout = scdoc.captureStdOut();
        b.getInstallStep().dependOn(&b.addInstallFile(stdout, "share/man/man1/waylock.1").step);
    }

    const install_prefix = try std.fs.path.resolve(b.allocator, &[_][]const u8{b.install_prefix});
    if (std.mem.eql(u8, install_prefix, "/usr")) {
        b.installFile("pam.d/waylock", "../etc/pam.d/waylock");
    } else {
        b.installFile("pam.d/waylock", "etc/pam.d/waylock");
    }

    const full_version = blk: {
        if (mem.endsWith(u8, version, "-dev")) {
            var ret: u8 = undefined;

            const git_describe_long = b.execAllowFail(
                &[_][]const u8{ "git", "-C", b.build_root.path orelse ".", "describe", "--long" },
                &ret,
                .Inherit,
            ) catch break :blk version;

            var it = mem.split(u8, mem.trim(u8, git_describe_long, &std.ascii.whitespace), "-");
            _ = it.next().?; // previous tag
            const commit_count = it.next().?;
            const commit_hash = it.next().?;
            assert(it.next() == null);
            assert(commit_hash[0] == 'g');

            // Follow semantic versioning, e.g. 0.2.0-dev.42+d1cf95b
            break :blk try std.fmt.allocPrintZ(b.allocator, version ++ ".{s}+{s}", .{
                commit_count,
                commit_hash[1..],
            });
        } else {
            break :blk version;
        }
    };

    const options = b.addOptions();
    options.addOption([]const u8, "version", full_version);

    const scanner = Scanner.create(b);
    defer scanner.finish();

    scanner.addSystemProtocol("staging/ext-session-lock/ext-session-lock-v1.xml");
    scanner.addSystemProtocol("staging/single-pixel-buffer/single-pixel-buffer-v1.xml");
    scanner.addSystemProtocol("stable/viewporter/viewporter.xml");

    scanner.generate("wl_compositor", 4);
    scanner.generate("wl_output", 3);
    scanner.generate("wl_seat", 5);
    scanner.generate("ext_session_lock_manager_v1", 1);
    scanner.generate("wp_viewporter", 1);
    scanner.generate("wp_single_pixel_buffer_manager_v1", 1);

    const wayland = b.createModule(.{ .source_file = scanner.result });
    const xkbcommon = b.createModule(.{ .source_file = .{ .path = "deps/zig-xkbcommon/src/xkbcommon.zig" } });

    const waylock = b.addExecutable(.{
        .name = "waylock",
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });
    waylock.addOptions("build_options", options);

    waylock.addModule("wayland", wayland);
    waylock.addModule("xkbcommon", xkbcommon);
    waylock.linkLibC();
    waylock.linkSystemLibrary("wayland-client");
    waylock.linkSystemLibrary("xkbcommon");
    waylock.linkSystemLibrary("pam");

    scanner.addCSource(waylock);

    waylock.strip = strip;
    waylock.pie = pie;
    b.installArtifact(waylock);
}
