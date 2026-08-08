//! Artifact output sink: direct forwarding for streams, staged buffered I/O
//! for paths, with byte accounting kept beside the active writer.

const std = @import("std");
const Io = std.Io;
const stream_output = @import("stream_output.zig");

pub const Destination = union(enum) {
    path: []const u8,
    writer: *Io.Writer,
};

pub const Sink = struct {
    file_buffer: [8 * 1024]u8 = undefined,
    file_writer: ?Io.File.Writer = null,
    tracking: ?stream_output.TrackingWriter = null,
    out: *Io.Writer = undefined,

    pub fn open(
        sink: *Sink,
        io: Io,
        destination: Destination,
        overwrite: bool,
        atomic: *?Io.File.Atomic,
    ) !void {
        switch (destination) {
            .writer => |caller| {
                sink.tracking = stream_output.TrackingWriter.init(caller);
                sink.out = &sink.tracking.?.writer;
            },
            .path => |path| {
                atomic.* = try Io.Dir.cwd().createFileAtomic(io, path, .{
                    .replace = overwrite,
                });
                sink.file_writer = atomic.*.?.file.writerStreaming(
                    io,
                    &sink.file_buffer,
                );
                sink.out = &sink.file_writer.?.interface;
            },
        }
    }

    pub fn writer(sink: *Sink) *Io.Writer {
        return sink.out;
    }

    pub fn tracker(sink: *const Sink) ?*const stream_output.TrackingWriter {
        return if (sink.tracking) |*value| value else null;
    }

    pub fn flush(sink: *Sink) Io.Writer.Error!void {
        if (sink.file_writer) |*staged_writer| {
            try staged_writer.interface.flush();
        }
    }
};
