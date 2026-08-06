//! `zenfmt_html`: the tolerant HTML reader library (ZDS 0002, phase 6).

pub const reader = @import("reader.zig").reader;

test {
    _ = @import("reader.zig");
}
