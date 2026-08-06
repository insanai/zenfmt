//! `zenfmt_odp`: the OpenDocument presentation format library.
//!
//! Slides project to headings and body text following the PPTX
//! conventions; speaker notes append as a `container` classed `notes`.

pub const reader = @import("reader.zig").reader;

test {
    _ = @import("reader.zig");
    _ = @import("reader_test.zig");
}
