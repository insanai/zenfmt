//! `zenfmt_docx`: the DOCX format library (ZDS 0002, phase 4).

pub const reader = @import("reader.zig").reader;

test {
    _ = @import("reader.zig");
    _ = @import("package.zig");
    _ = @import("tables.zig");
    _ = @import("reports.zig");
    _ = @import("util.zig");
    _ = @import("styles.zig");
    _ = @import("numbering.zig");
}
