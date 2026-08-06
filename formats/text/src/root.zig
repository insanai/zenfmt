//! `zenfmt_text`: the plain-text reader library (ZDS 0002, phase 1).

pub const reader = @import("reader.zig").reader;

test {
    _ = @import("reader.zig");
}
