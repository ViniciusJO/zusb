const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const fw = b.addWriteFile("libusb.c", "#include <libusb-1.0/libusb.h>");
    const s = fw.add("libusb.c", "#include <libusb-1.0/libusb.h>");

    const libusb = b.addTranslateC(.{
        .root_source_file = s,
        .target = target,
        .optimize = optimize,
    });
    // TODO: verify
    const libusb_mod = libusb.addModule("libusb");

    const zusb_mod = b.addModule("zusb", .{
        .root_source_file = b.path("zusb.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "libusb", .module = libusb.createModule() },
        },
    });

    zusb_mod.linkSystemLibrary("libusb-1.0", .{});

    const example = b.addModule("example", .{
        .root_source_file = b.path("example/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "libusb", .module = libusb_mod },
            .{ .name = "zusb", .module = zusb_mod },
        },
    });

    const exe = b.addExecutable(.{
        .name = "zusb_example",
        .root_module = example,
    });

    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    const run_step = b.step("run", "run example");
    run_step.dependOn(&run.step);

    const clean = b.addSystemCommand(&.{ "rm", "-rf", "zig-out", ".zig-cache" });
    const clean_step = b.step("clean", "clean artifacts");
    clean_step.dependOn(&clean.step);
}
