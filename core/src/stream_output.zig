//! Direct-stream byte accounting (ZDS 0013, Stream Output Completeness).

const std = @import("std");
const assert = std.debug.assert;

pub const State = enum(u8) { none, untouched, partial, complete };

/// A zero-buffer forwarding writer that counts bytes actually accepted by
/// the caller. Buffered bytes still inside an upstream writer do not count.
pub const TrackingWriter = struct {
    out: *std.Io.Writer,
    count: u64 = 0,
    writer: std.Io.Writer,

    pub fn init(out: *std.Io.Writer) TrackingWriter {
        return .{
            .out = out,
            .writer = .{
                .buffer = &.{},
                .vtable = &.{ .drain = drain },
            },
        };
    }

    fn drain(
        writer: *std.Io.Writer,
        data: []const []const u8,
        splat: usize,
    ) std.Io.Writer.Error!usize {
        const tracking: *TrackingWriter = @alignCast(
            @fieldParentPtr("writer", writer),
        );
        assert(writer.end == 0);
        const buffered_before = tracking.out.buffered().len;
        const accepted = tracking.out.writeSplatHeader(&.{}, data, splat) catch |err| {
            const buffered_after = tracking.out.buffered().len;
            if (buffered_after > buffered_before) {
                tracking.count += buffered_after - buffered_before;
            }
            return err;
        };
        tracking.count += accepted;
        return accepted;
    }
};

/// A zero-buffer forwarding writer that refuses the byte that would cross
/// `limit` (ZDS 0014, `max_output_bytes`). The rejected drain forwards
/// nothing; `exceeded` distinguishes the limit from an ordinary write
/// failure.
pub const LimitedWriter = struct {
    out: *std.Io.Writer,
    limit: u64,
    count: u64 = 0,
    exceeded: bool = false,
    writer: std.Io.Writer,

    pub fn init(out: *std.Io.Writer, limit: u64) LimitedWriter {
        return .{
            .out = out,
            .limit = limit,
            .writer = .{
                .buffer = &.{},
                .vtable = &.{ .drain = drain },
            },
        };
    }

    fn drain(
        writer: *std.Io.Writer,
        data: []const []const u8,
        splat: usize,
    ) std.Io.Writer.Error!usize {
        const limited: *LimitedWriter = @alignCast(
            @fieldParentPtr("writer", writer),
        );
        assert(writer.end == 0);
        const incoming = std.Io.Writer.countSplat(data, splat);
        if (incoming > limited.limit - limited.count) {
            limited.exceeded = true;
            return error.WriteFailed;
        }
        const accepted = try limited.out.writeSplatHeader(&.{}, data, splat);
        limited.count += accepted;
        return accepted;
    }
};

pub fn failureState(
    path_output: bool,
    tracking: ?*const TrackingWriter,
) State {
    if (path_output) {
        assert(tracking == null);
        return .none;
    }
    const count = (tracking orelse unreachable).count;
    return if (count == 0) .untouched else .partial;
}
