//! `zenfmt_rtf`: the RTF reader library (ZDS 0002, phase 5).

pub const reader = @import("reader.zig").reader;

test {
    _ = @import("reader.zig");
}
