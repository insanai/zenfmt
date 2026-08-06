//! `zenfmt_csv`: the CSV/TSV reader library (ZDS 0002, phase 2).

pub const reader = @import("reader.zig").reader;

test {
    _ = @import("reader.zig");
}
