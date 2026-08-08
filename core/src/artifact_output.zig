//! Artifact output sink: direct forwarding for streams, staged buffered I/O
//! for paths, arena-backed accumulation for memory output, with byte
//! accounting and the `max_output_bytes` cap kept beside the active writer.

const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;
const stream_output = @import("stream_output.zig");
const host = @import("host.zig");

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

/// The artifact sink, parameterized by host authority.
///
/// A pure sink carries neither the staging buffer nor the file writer: the
/// fields do not exist, so a browser conversion does not reserve eight
/// kilobytes of stack for a file it can never open, and the file-writing code
/// is not compiled into that build at all.
pub fn Sink(comptime mode: host.Mode) type {
    return struct {
        const Self = @This();

        file: FileStaging(mode) = .{},
        tracking: ?stream_output.TrackingWriter = null,
        memory: ?MemoryWriter = null,
        limiting: stream_output.LimitedWriter = undefined,
        out: *Io.Writer = undefined,

        pub fn open(
            sink: *Self,
            io: host.Io(mode),
            destination: Destination,
            overwrite: bool,
            max_output_bytes: u64,
            atomic: *?host.Atomic(mode),
        ) !void {
            const inner: *Io.Writer = switch (destination) {
                .writer => |caller| blk: {
                    sink.tracking = stream_output.TrackingWriter.init(caller);
                    break :blk &sink.tracking.?.writer;
                },
                .path => |path| blk: {
                    if (mode == .host) {
                        atomic.* = try Io.Dir.cwd().createFileAtomic(io, path, .{
                            .replace = overwrite,
                        });
                        sink.file.writer = atomic.*.?.file.writerStreaming(
                            io,
                            &sink.file.buffer,
                        );
                        break :blk &sink.file.writer.?.interface;
                    } else {
                        // Input resolution refuses a path before a pure
                        // bundle ever reaches the writer, so this is not a
                        // supported outcome to handle — it is a state the
                        // engine has already excluded.
                        unreachable;
                    }
                },
                .memory => |arena| blk: {
                    sink.memory = MemoryWriter.init(arena);
                    break :blk &sink.memory.?.writer;
                },
            };
            sink.limiting = stream_output.LimitedWriter.init(inner, max_output_bytes);
            sink.out = &sink.limiting.writer;
        }

        pub fn writer(sink: *Self) *Io.Writer {
            return sink.out;
        }

        pub fn tracker(sink: *const Self) ?*const stream_output.TrackingWriter {
            return if (sink.tracking) |*value| value else null;
        }

        /// Whether the last write failure was the output-size limit refusing
        /// another byte.
        pub fn outputLimitExceeded(sink: *const Self) bool {
            return sink.limiting.exceeded;
        }

        /// Whether the last write failure was memory-accumulation exhaustion.
        pub fn memoryOom(sink: *const Self) bool {
            return if (sink.memory) |*value| value.oom else false;
        }

        /// The accumulated artifact bytes for a memory destination.
        /// Arena-owned; valid for the conversion result's lifetime.
        pub fn memoryBytes(sink: *const Self) []const u8 {
            return sink.memory.?.list.items;
        }

        pub fn flush(sink: *Self) Io.Writer.Error!void {
            if (mode == .host) {
                if (sink.file.writer) |*staged_writer| {
                    try staged_writer.interface.flush();
                }
            }
        }
    };
}

/// The staging buffer and file writer a host sink needs, and a pure sink does
/// not have.
fn FileStaging(comptime mode: host.Mode) type {
    return switch (mode) {
        .host => struct {
            buffer: [8 * 1024]u8 = undefined,
            writer: ?Io.File.Writer = null,
        },
        .pure => struct {},
    };
}
