//! `zenfmt_rtf`: the RTF reader library (ZDS 0002, phase 5; ZDS 0004).

pub const reader = @import("reader.zig").reader;

test {
    _ = @import("reader.zig");
    _ = @import("structure.zig");
    _ = @import("reports.zig");
    _ = @import("reader_test.zig");
}
