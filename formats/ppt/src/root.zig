//! `zenfmt_ppt`: the legacy binary PowerPoint format library.

pub const reader = @import("reader.zig").reader;

test {
    _ = @import("reader.zig");
}
