//! `zenfmt_odt`: the OpenDocument Text reader library (ZDS 0002, phase 5).

pub const reader = @import("reader.zig").reader;

test {
    _ = @import("reader.zig");
}
