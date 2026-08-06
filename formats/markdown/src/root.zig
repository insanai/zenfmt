//! `zenfmt_markdown`: the Markdown format library (ZDS 0002).
//!
//! The writer is the sole first-release output; the reader is the phase 2
//! test instrument that makes the round-trip fixed point checkable. Both
//! halves share one plugin id and one preservation-data namespace.

pub const writer = @import("writer.zig").writer;
pub const reader = @import("reader.zig").reader;

test {
    _ = @import("writer.zig");
    _ = @import("writer_reports.zig");
    _ = @import("writer_test.zig");
    _ = @import("reader.zig");
    _ = @import("lines.zig");
    _ = @import("inlines.zig");
}
