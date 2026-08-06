//! `zenfmt_epub`: the EPUB format library.
//!
//! A ZIP container whose chapters are XHTML: the container and package
//! documents are parsed here, the chapters run through `zenfmt_html`'s
//! shared parser in spine order.

pub const reader = @import("reader.zig").reader;

test {
    _ = @import("reader.zig");
    _ = @import("reader_test.zig");
}
