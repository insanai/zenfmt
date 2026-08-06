//! `zenfmt_pdf`: the PDF format library (ZDS: pdf-reader).
//!
//! Native Zig text extraction — no C dependency. `xref.zig` owns file
//! structure, `objects.zig` the COS syntax, `streams.zig` the filters,
//! `fonts.zig`/`glyphs.zig` code→Unicode mapping, `content.zig` the
//! content-stream machine, `graphics.zig`/`layout.zig` table and image
//! reconstruction, `images.zig` as-is image extraction, and `reader.zig`
//! the plugin descriptor.

pub const reader = @import("reader.zig").reader;

test {
    _ = @import("objects.zig");
    _ = @import("xref.zig");
    _ = @import("streams.zig");
    _ = @import("glyphs.zig");
    _ = @import("fonts.zig");
    _ = @import("content.zig");
    _ = @import("graphics.zig");
    _ = @import("images.zig");
    _ = @import("layout.zig");
    _ = @import("reader.zig");
    _ = @import("reports.zig");
    _ = @import("testpdf.zig");
    _ = @import("reader_test.zig");
}
