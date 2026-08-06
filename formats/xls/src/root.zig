//! `zenfmt_xls`: the legacy binary Excel format library (BIFF8).

pub const reader = @import("reader.zig").reader;

test {
    _ = @import("reader.zig");
}
