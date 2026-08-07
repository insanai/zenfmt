//! `zenfmt_html`: the tolerant HTML reader library (ZDS 0002, phase 6).

pub const reader = @import("reader.zig").reader;
pub const parseFragment = @import("reader.zig").parseFragment;

test {
    _ = @import("reader.zig");
    _ = @import("reader_test.zig");
    _ = @import("entities.zig");
}
