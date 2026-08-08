//! Running a writer into the artifact sink, and closing that sink honestly.
//!
//! Split out of the bundle so `root.zig` stays inside the standard's file
//! bound (ZDS 0002). The behaviour is unchanged: this is where the writer's
//! bytes are hashed as they are emitted, where a write failure is classified
//! into the report that explains it, and where the stream state records what
//! a caller's writer actually received before the failure.

const std = @import("std");
const Io = std.Io;

const artifact_output = @import("artifact_output.zig");
const engine_reports = @import("engine_reports.zig");
const host = @import("host.zig");
const lowering = @import("lowering.zig");
const manifest = @import("manifest.zig");
const plugin = @import("plugin.zig");
const preservation = @import("preservation.zig");
const stream_output = @import("stream_output.zig");

const Document = @import("ast.zig").Document;
const Reports = @import("report.zig").Reports;
const ConvertOptions = @import("options.zig").ConvertOptions;
const RunError = error{ OutOfMemory, Failed };
const Blake3 = std.crypto.hash.Blake3;

/// A rendered artifact: the digest always, plus the arena-owned bytes when
/// the destination was memory.
pub const Rendered = struct {
    digest: manifest.DigestHex,
    memory_bytes: ?[]const u8,
};

pub fn render(
    comptime mode: host.Mode,
    comptime descriptor: plugin.WriterDescriptor,
    arena: std.mem.Allocator,
    io: host.Io(mode),
    options: ConvertOptions,
    artifact_name: []const u8,
    doc: *const Document,
    loaded: ?manifest.Loaded,
    reports: *Reports,
    stream: *stream_output.State,
    plan: *?lowering.Plan,
    atomic: *?host.Atomic(mode),
) RunError!Rendered {
    const destination: artifact_output.Destination = switch (options.output) {
        .writer => |value| .{ .writer = value },
        .path => |value| .{ .path = value },
        .memory => .{ .memory = arena },
    };
    var sink: artifact_output.Sink(mode) = .{};
    sink.open(
        io,
        destination,
        options.overwrite,
        options.limits.max_output_bytes,
        atomic,
    ) catch |err| {
        const path = switch (options.output) {
            .writer, .memory => artifact_name,
            .path => |value| value,
        };
        try reports.add(try engine_reports.pathFailure(
            arena,
            "stage the output file",
            path,
            err,
        ));
        return error.Failed;
    };
    var hash_buffer: [4 * 1024]u8 = undefined;
    var hashed = Io.Writer.Hashed(Blake3).initHasher(
        sink.writer(),
        Blake3.init(.{}),
        &hash_buffer,
    );
    var context: plugin.WriteContext = .{
        .plan = if (plan.*) |*selected| selected else null,
        .gpa = arena,
        .doc = doc,
        .out = &hashed.writer,
        .reports = reports,
        .limits = options.limits,
        .preservation_in = preservation.entry(
            loaded,
            descriptor.id,
            descriptor.data_version,
        ),
    };
    descriptor.write(&context) catch |err| {
        stream.* = stream_output.failureState(
            options.output != .writer,
            sink.tracker(),
        );
        if (err == error.OutOfMemory or sink.memoryOom()) {
            return error.OutOfMemory;
        }
        try reports.add(try writeFailure(
            arena,
            descriptor.format,
            artifact_name,
            options,
            &sink,
            stream.*,
            err,
        ));
        return error.Failed;
    };
    return finish(
        mode,
        arena,
        descriptor.format,
        options,
        artifact_name,
        reports,
        stream,
        plan,
        &sink,
        &hashed,
    );
}

fn finish(
    comptime mode: host.Mode,
    arena: std.mem.Allocator,
    format: []const u8,
    options: ConvertOptions,
    artifact_name: []const u8,
    reports: *Reports,
    stream: *stream_output.State,
    plan: *?lowering.Plan,
    sink: *artifact_output.Sink(mode),
    hashed: *Io.Writer.Hashed(Blake3),
) RunError!Rendered {
    if (plan.*) |*selected| selected.assertEmissionComplete();
    hashed.writer.flush() catch |err| {
        stream.* = stream_output.failureState(
            options.output != .writer,
            sink.tracker(),
        );
        if (sink.memoryOom()) return error.OutOfMemory;
        try reports.add(try writeFailure(
            arena,
            format,
            artifact_name,
            options,
            sink,
            stream.*,
            err,
        ));
        return error.Failed;
    };
    sink.flush() catch |err| {
        try reports.add(try engine_reports.pathFailure(
            arena,
            "flush the output",
            artifact_name,
            err,
        ));
        return error.Failed;
    };
    if (options.output == .writer) stream.* = .complete;
    return .{
        .digest = manifest.digestHexFromHasher(&hashed.hasher),
        .memory_bytes = if (options.output == .memory)
            sink.memoryBytes()
        else
            null,
    };
}

/// Classifies an emission failure. The output limit is not a writer defect,
/// so it keeps its own report and its own exit class; anything else is
/// reported against the writer with what the caller's stream already
/// received.
fn writeFailure(
    arena: std.mem.Allocator,
    format: []const u8,
    artifact_name: []const u8,
    options: ConvertOptions,
    sink: anytype,
    stream: stream_output.State,
    err: anyerror,
) error{OutOfMemory}!@import("report.zig").Report {
    if (sink.outputLimitExceeded()) {
        return engine_reports.outputTooLarge(arena, artifact_name, options.limits);
    }
    return engine_reports.writerFailure(
        arena,
        format,
        artifact_name,
        err,
        options.output == .writer,
        stream == .partial,
    );
}
