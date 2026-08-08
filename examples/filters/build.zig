//! A user project carrying its own zenfmt filters (ZDS 0002, Filters).
//!
//! This is the `build.zig` analogy taken literally: this project depends on
//! the zenfmt package, declares a pipeline in `src/main.zig`, and
//! `zig build` produces a zenfmt binary with those transforms compiled in.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zenfmt = b.dependency("zenfmt", .{
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "zenfmt-filtered",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zenfmt", .module = zenfmt.module("zenfmt") },
                .{ .name = "zenfmt_cli", .module = zenfmt.module("zenfmt_cli") },
            },
        }),
    });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    if (b.args) |args| run.addArgs(args);
    const run_step = b.step("run", "Run the filter-carrying zenfmt binary");
    run_step.dependOn(&run.step);
}
