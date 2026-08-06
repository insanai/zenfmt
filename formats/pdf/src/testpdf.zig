//! Test-only PDF assembly (ZDS: pdf-reader).
//!
//! Hand-writing xref byte offsets is how test PDFs rot; this builder
//! records each object's offset as it is appended and writes the classic
//! cross-reference table from those records. Tests state object bodies;
//! the builder owns framing.

const std = @import("std");
const assert = std.debug.assert;

pub const Builder = struct {
    arena: std.mem.Allocator,
    out: std.ArrayList(u8) = .empty,
    offsets: std.ArrayList(u64) = .empty,
    /// Extra trailer-dictionary text, e.g. `/Encrypt 2 0 R`.
    extra_trailer: []const u8 = "",

    pub fn init(arena: std.mem.Allocator) Builder {
        var b: Builder = .{ .arena = arena };
        b.out.appendSlice(arena, "%PDF-1.7\n%\xc2\xa5\xc2\xb1\n") catch @panic("OOM");
        return b;
    }

    /// Appends `N 0 obj <body> endobj`, returning the object number.
    pub fn add(b: *Builder, body: []const u8) !u32 {
        const num: u32 = @intCast(b.offsets.items.len + 1);
        try b.offsets.append(b.arena, b.out.items.len);
        try b.out.print(b.arena, "{d} 0 obj\n{s}\nendobj\n", .{ num, body });
        return num;
    }

    /// Appends a stream object with the given dictionary extras and data;
    /// `/Length` is computed. Pass `dict_body` without `<<`/`>>`.
    pub fn addStream(b: *Builder, dict_body: []const u8, data: []const u8) !u32 {
        const num: u32 = @intCast(b.offsets.items.len + 1);
        try b.offsets.append(b.arena, b.out.items.len);
        try b.out.print(
            b.arena,
            "{d} 0 obj\n<< {s} /Length {d} >>\nstream\n",
            .{ num, dict_body, data.len },
        );
        try b.out.appendSlice(b.arena, data);
        try b.out.appendSlice(b.arena, "\nendstream\nendobj\n");
        return num;
    }

    /// Writes the xref table and trailer. `root` is the catalog's number.
    pub fn finish(b: *Builder, root: u32) ![]const u8 {
        const xref_at = b.out.items.len;
        const count = b.offsets.items.len + 1;
        try b.out.print(b.arena, "xref\n0 {d}\n", .{count});
        try b.out.appendSlice(b.arena, "0000000000 65535 f \n");
        for (b.offsets.items) |offset| {
            try b.out.print(b.arena, "{d:0>10} 00000 n \n", .{offset});
        }
        try b.out.print(
            b.arena,
            "trailer\n<< /Size {d} /Root {d} 0 R {s} >>\nstartxref\n{d}\n%%EOF\n",
            .{ count, root, b.extra_trailer, xref_at },
        );
        return b.out.items;
    }
};

/// A complete single-page document whose page carries `content` as its
/// (uncompressed) content stream and `extra_page` inside the page dict —
/// e.g. a `/Resources` entry naming fonts created by the caller.
pub fn singlePage(
    arena: std.mem.Allocator,
    content: []const u8,
    extra_page: []const u8,
) ![]const u8 {
    var b = Builder.init(arena);
    _ = try b.add("<< /Type /Catalog /Pages 2 0 R >>");
    _ = try b.add("<< /Type /Pages /Kids [3 0 R] /Count 1 >>");
    const page = try std.fmt.allocPrint(
        arena,
        "<< /Type /Page /Parent 2 0 R /Contents 4 0 R {s} >>",
        .{extra_page},
    );
    _ = try b.add(page);
    _ = try b.addStream("", content);
    return b.finish(1);
}

test "builder offsets match the objects they index" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var b = Builder.init(arena);
    _ = try b.add("<< /Type /Catalog /Pages 2 0 R >>");
    _ = try b.add("<< /Type /Pages /Kids [] /Count 0 >>");
    const bytes = try b.finish(1);
    for (b.offsets.items, 1..) |offset, num| {
        var expected: [16]u8 = undefined;
        const prefix = try std.fmt.bufPrint(&expected, "{d} 0 obj", .{num});
        try std.testing.expect(std.mem.startsWith(u8, bytes[@intCast(offset)..], prefix));
    }
}
