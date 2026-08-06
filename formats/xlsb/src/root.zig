//! `zenfmt_xlsb`: the binary Excel workbook format library (MS-XLSB).

pub const reader = @import("reader.zig").reader;

test {
    _ = @import("reader.zig");
}
