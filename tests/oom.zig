//! Allocation-failure sweeps for every registered reader. Each sweep moves
//! the injected failure through every allocation reached by that reader's
//! seed and requires the reserved OOM diagnostic instead of a trap, leak, or
//! misleading malformed-input report.

const std = @import("std");
const testing = std.testing;
const zenfmt = @import("zenfmt");

const max_fail_index = 512;

test "every registered reader propagates allocation failure" {
    try testing.expectEqual(@as(usize, 19), zenfmt.Default.readers.len);
    for (zenfmt.Default.readers) |reader| {
        try sweepReader(reader.format, seedFor(reader.format));
    }
}

fn sweepReader(format: []const u8, seed: []const u8) !void {
    var reached_end = false;
    var fail_index: usize = 0;
    while (fail_index < max_fail_index) : (fail_index += 1) {
        var failing = testing.FailingAllocator.init(testing.allocator, .{
            .fail_index = fail_index,
        });
        var output_buffer: [64 * 1024]u8 = undefined;
        var output = std.Io.Writer.fixed(&output_buffer);
        var conversion = zenfmt.convert(failing.allocator(), testing.io, .{
            .input = .{ .bytes = .{ .name = "oom-input", .data = seed } },
            .output = .{ .writer = &output },
            .from = format,
        });
        const induced = failing.has_induced_failure;
        if (induced) {
            try testing.expectEqual(zenfmt.Status.failed, conversion.status);
            try testing.expectEqual(@as(usize, 1), conversion.reports.len);
            try testing.expectEqualStrings(
                "core.out-of-memory",
                conversion.reports[0].code,
            );
        } else {
            reached_end = true;
        }
        conversion.deinit(failing.allocator());
        if (!induced) break;
    }
    if (!reached_end) {
        std.debug.print(
            "reader {s} exceeded the OOM sweep bound ({d})\n",
            .{ format, max_fail_index },
        );
    }
    try testing.expect(reached_end);
}

fn seedFor(format: []const u8) []const u8 {
    if (std.mem.eql(u8, format, "text")) return "plain text\n";
    if (std.mem.eql(u8, format, "markdown")) return "# heading\n\nbody\n";
    if (std.mem.eql(u8, format, "csv")) return "name,value\na,1\n";
    if (std.mem.eql(u8, format, "rtf")) return "{\\rtf1\\ansi body}";
    if (std.mem.eql(u8, format, "html")) return "<p>body</p>";
    if (std.mem.eql(u8, format, "asciidoc")) return "= Heading\n\nbody\n";
    if (std.mem.eql(u8, format, "rst")) return "Heading\n=======\n\nbody\n";
    if (std.mem.eql(u8, format, "pdf")) return "%PDF-1.4\n%%EOF\n";
    if (std.mem.eql(u8, format, "doc") or
        std.mem.eql(u8, format, "xls") or
        std.mem.eql(u8, format, "ppt"))
    {
        return "\xd0\xcf\x11\xe0\xa1\xb1\x1a\xe1truncated";
    }
    return "PK\x03\x04truncated";
}
