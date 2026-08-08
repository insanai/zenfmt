//! Artifact output sink: direct forwarding for streams, staged buffered I/O
//! for paths, arena-backed accumulation for memory output, with byte
//! accounting and the `max_output_bytes` cap kept beside the active writer.

const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;
const stream_output = @import("stream_output.zig");

pub const Destination = union(enum) {
    path: []const u8,
    writer: *Io.Writer,
    /// The conversion arena; accumulated bytes stay valid for the result's
    /// lifetime.
    memory: std.mem.Allocator,
};

/// A zero-buffer writer that accumulates the artifact in the conversion
/// arena. Allocation failure is recorded so the engine can surface the
/// canonical out-of-memory report instead of a generic write failure.
pub const MemoryWriter = struct {
    arena: std.mem.Allocator,
    list: std.ArrayList(u8) = .empty,
    oom: bool = false,
    writer: Io.Writer,

    pub fn init(arena: std.mem.Allocator) MemoryWriter {
        return .{
            .arena = arena,
            .writer = .{
                .buffer = &.{},
                .vtable = &.{ .drain = drain },
            },
        };
    }

    fn drain(
        writer: *Io.Writer,
        data: []const []const u8,
        splat: usize,
    ) Io.Writer.Error!usize {
        const memory: *MemoryWriter = @alignCast(
            @fieldParentPtr("writer", writer),
        );
        assert(writer.end == 0);
        if (data.len == 0) return 0;
        var accepted: usize = 0;
        for (data[0 .. data.len - 1]) |slice| {
            memory.list.appendSlice(memory.arena, slice) catch {
                memory.oom = true;
                return error.WriteFailed;
            };
            accepted += slice.len;
        }
        const last = data[data.len - 1];
        for (0..splat) |_| {
            memory.list.appendSlice(memory.arena, last) catch {
                memory.oom = true;
                return error.WriteFailed;
            };
            accepted += last.len;
        }
        return accepted;
    }
};

pub const Sink = struct {
    file_buffer: [8 * 1024]u8 = undefined,
    file_writer: ?Io.File.Writer = null,
    tracking: ?stream_output.TrackingWriter = null,
    memory: ?MemoryWriter = null,
    limiting: stream_output.LimitedWriter = undefined,
    out: *Io.Writer = undefined,

    pub fn open(
        sink: *Sink,
        io: Io,
        destination: Destination,
        overwrite: bool,
        max_output_bytes: u64,
        atomic: *?Io.File.Atomic,
    ) !void {
        const inner: *Io.Writer = switch (destination) {
            .writer => |caller| blk: {
                sink.tracking = stream_output.TrackingWriter.init(caller);
                break :blk &sink.tracking.?.writer;
            },
            .path => |path| blk: {
                atomic.* = try Io.Dir.cwd().createFileAtomic(io, path, .{
                    .replace = overwrite,
                });
                sink.file_writer = atomic.*.?.file.writerStreaming(
                    io,
                    &sink.file_buffer,
                );
                break :blk &sink.file_writer.?.interface;
            },
            .memory => |arena| blk: {
                sink.memory = MemoryWriter.init(arena);
                break :blk &sink.memory.?.writer;
            },
        };
        sink.limiting = stream_output.LimitedWriter.init(inner, max_output_bytes);
        sink.out = &sink.limiting.writer;
    }

    pub fn writer(sink: *Sink) *Io.Writer {
        return sink.out;
    }

    pub fn tracker(sink: *const Sink) ?*const stream_output.TrackingWriter {
        return if (sink.tracking) |*value| value else null;
    }

    /// Whether the last write failure was the output-size limit refusing
    /// another byte.
    pub fn outputLimitExceeded(sink: *const Sink) bool {
        return sink.limiting.exceeded;
    }

    /// Whether the last write failure was memory-accumulation exhaustion.
    pub fn memoryOom(sink: *const Sink) bool {
        return if (sink.memory) |*value| value.oom else false;
    }

    /// The accumulated artifact bytes for a memory destination. Arena-owned;
    /// valid for the conversion result's lifetime.
    pub fn memoryBytes(sink: *const Sink) []const u8 {
        return sink.memory.?.list.items;
    }

    pub fn flush(sink: *Sink) Io.Writer.Error!void {
        if (sink.file_writer) |*staged_writer| {
            try staged_writer.interface.flush();
        }
    }
};
