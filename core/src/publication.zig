//! Staged artifact publication (ZDS 0013, Core Contract Repairs).
//!
//! Artifact, embedded resources, and manifest are fully written under
//! temporary names before publication starts. The manifest publishes last,
//! so it never vouches for an incomplete output ensemble.

const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;
const resource_output = @import("resource_output.zig");

pub const Error = error{ OutOfMemory, Failed };

pub const Failure = struct {
    kind: Kind = .operation,
    operation: []const u8 = "publish the output",
    path: []const u8 = "",
    cause: anyerror = error.Unexpected,

    pub const Kind = enum { operation, destination_exists };
};

const StagedMedia = struct {
    atomic: Io.File.Atomic,
    path: []const u8,
};

pub fn publish(
    arena: std.mem.Allocator,
    io: Io,
    artifact: *Io.File.Atomic,
    output_path: []const u8,
    manifest_json: []const u8,
    media_plan: []const resource_output.File,
    overwrite: bool,
    failure: *Failure,
) Error!void {
    assert(output_path.len > 0);
    assert(failure.path.len == 0);

    const manifest_path = try std.fmt.allocPrint(
        arena,
        "{s}.zenfmt.json",
        .{output_path},
    );
    if (!overwrite) {
        try requireAbsent(io, output_path, failure);
        try requireAbsent(io, manifest_path, failure);
        for (media_plan) |file| try requireAbsent(io, file.disk_path, failure);
    }
    var manifest = try stageManifest(io, manifest_path, manifest_json, overwrite, failure);
    defer manifest.deinit(io);
    var media = try stageMedia(arena, io, media_plan, overwrite, failure);
    defer deinitMedia(&media, io);

    if (overwrite) {
        try retireManifest(io, manifest_path, failure);
    }

    try publishOne(artifact, io, output_path, overwrite, failure);
    for (media.items) |*file| {
        try publishOne(&file.atomic, io, file.path, overwrite, failure);
    }
    try publishOne(&manifest, io, manifest_path, overwrite, failure);
}

fn stageManifest(
    io: Io,
    path: []const u8,
    bytes: []const u8,
    overwrite: bool,
    failure: *Failure,
) Error!Io.File.Atomic {
    var atomic = Io.Dir.cwd().createFileAtomic(io, path, .{
        .replace = overwrite,
    }) catch |err| return fail(failure, "stage the manifest", path, err);
    errdefer atomic.deinit(io);
    atomic.file.writeStreamingAll(io, bytes) catch |err| {
        return fail(failure, "write the staged manifest", path, err);
    };
    return atomic;
}

fn stageMedia(
    arena: std.mem.Allocator,
    io: Io,
    plan: []const resource_output.File,
    overwrite: bool,
    failure: *Failure,
) Error!std.ArrayList(StagedMedia) {
    var staged: std.ArrayList(StagedMedia) = .empty;
    errdefer deinitMedia(&staged, io);
    if (plan.len == 0) return staged;

    const directory = std.fs.path.dirname(plan[0].disk_path) orelse ".";
    Io.Dir.cwd().createDirPath(io, directory) catch |err| {
        return fail(failure, "create the media directory", directory, err);
    };
    for (plan) |file| {
        var atomic = Io.Dir.cwd().createFileAtomic(io, file.disk_path, .{
            .replace = overwrite,
        }) catch |err| return fail(failure, "stage a media file", file.disk_path, err);
        errdefer atomic.deinit(io);
        atomic.file.writeStreamingAll(io, file.bytes) catch |err| {
            return fail(failure, "write a staged media file", file.disk_path, err);
        };
        try staged.append(arena, .{ .atomic = atomic, .path = file.disk_path });
    }
    return staged;
}

fn requireAbsent(io: Io, path: []const u8, failure: *Failure) Error!void {
    Io.Dir.cwd().access(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return fail(failure, "inspect an output path", path, err),
    };
    failure.* = .{
        .kind = .destination_exists,
        .operation = "publish the output",
        .path = path,
        .cause = error.PathAlreadyExists,
    };
    return error.Failed;
}

fn retireManifest(io: Io, path: []const u8, failure: *Failure) Error!void {
    Io.Dir.cwd().deleteFile(io, path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return fail(failure, "retire the previous manifest", path, err),
    };
}

fn publishOne(
    atomic: *Io.File.Atomic,
    io: Io,
    path: []const u8,
    overwrite: bool,
    failure: *Failure,
) Error!void {
    if (overwrite) {
        atomic.replace(io) catch |err| {
            return fail(failure, "publish the staged output", path, err);
        };
    } else {
        atomic.link(io) catch |err| {
            return fail(failure, "publish the staged output", path, err);
        };
    }
}

fn fail(
    failure: *Failure,
    operation: []const u8,
    path: []const u8,
    cause: anyerror,
) error{Failed} {
    failure.* = .{
        .operation = operation,
        .path = path,
        .cause = cause,
    };
    return error.Failed;
}

fn deinitMedia(media: *std.ArrayList(StagedMedia), io: Io) void {
    for (media.items) |*file| file.atomic.deinit(io);
    media.clearRetainingCapacity();
}
