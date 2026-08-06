//! `zenfmt_ods`: the OpenDocument spreadsheet format library.
//!
//! Sheets project to headings and tables following the XLSX conventions;
//! typed cell values resolve through `office:*` attributes.

pub const reader = @import("reader.zig").reader;

test {
    _ = @import("reader.zig");
}
