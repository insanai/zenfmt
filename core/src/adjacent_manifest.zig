//! Bounded, digest-checked loading of an adjacent artifact manifest.

const std = @import("std");
const Io = std.Io;
const limits_mod = @import("limits.zig");
const manifest = @import("manifest.zig");

pub const Result = union(enum) {
    missing,
    invalid: Invalid,
    loaded: manifest.Loaded,
};

pub const Invalid = struct {
    path: []const u8,
    reason: Reason,
};

pub const Reason = union(enum) {
    read_failed: anyerror,
    too_large: u32,
    invalid_data,
    digest_mismatch,
};

pub fn load(
    arena: std.mem.Allocator,
    io: Io,
    input_path: ?[]const u8,
    input_digest: manifest.DigestHex,
    limits: limits_mod.Limits,
) error{OutOfMemory}!Result {
    const path = input_path orelse return .missing;
    const manifest_path = try std.fmt.allocPrint(
        arena,
        "{s}.zenfmt.json",
        .{path},
    );
    const bytes = Io.Dir.cwd().readFileAlloc(
        io,
        manifest_path,
        arena,
        .limited(limits.max_manifest_bytes),
    ) catch |err| switch (err) {
        error.FileNotFound => return .missing,
        error.OutOfMemory => return error.OutOfMemory,
        error.StreamTooLong => return .{ .invalid = .{
            .path = manifest_path,
            .reason = .{ .too_large = limits.max_manifest_bytes },
        } },
        else => return .{ .invalid = .{
            .path = manifest_path,
            .reason = .{ .read_failed = err },
        } },
    };
    const loaded = manifest.load(arena, bytes, limits) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Invalid => return .{ .invalid = .{
            .path = manifest_path,
            .reason = .invalid_data,
        } },
    };
    if (!std.mem.eql(
        u8,
        &loaded.artifact_digest_hex,
        &input_digest,
    )) return .{ .invalid = .{
        .path = manifest_path,
        .reason = .digest_mismatch,
    } };
    return .{ .loaded = loaded };
}
