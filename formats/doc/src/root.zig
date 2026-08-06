//! `zenfmt_doc`: the legacy binary Word format library.

pub const reader = @import("reader.zig").reader;

test {
    _ = @import("reader.zig");
    _ = @import("styles.zig");
}
