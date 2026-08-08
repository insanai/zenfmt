//! A zenfmt binary with filters compiled in, in the manner of `build.zig`:
//! this file is a program, and the compiler checks every transform in it.
//!
//!     zig build
//!     ./zig-out/bin/zenfmt-filtered --filters manual.md -o manual.out.md

const std = @import("std");
const zenfmt = @import("zenfmt");
const cli = @import("zenfmt_cli");

/// The pipeline this binary carries. Order matters, and is exactly the
/// order written here.
pub fn filters(p: *zenfmt.Pipeline) void {
    // One that ships with zenfmt.
    p.add(zenfmt.filters.shift_headings, .{ .by = 1 });

    // One this project defines, right below.
    p.add(InternalLinks, .{ .base = "https://docs.example.com/" });

    p.add(zenfmt.filters.drop_empty_containers, .{});
}

const InternalLinksOptions = struct {
    base: []const u8,
};

/// Rewrites fragment-only link targets to absolute URLs.
const InternalLinks = zenfmt.Filter(.{
    .id = "example.internal-links",
    .description = "Rewrite fragment links to absolute URLs",
    .options = InternalLinksOptions,
    .inline_tags = &.{.link},
    .idempotent = true,
    .visit_inline = visitLink,
});

fn visitLink(
    options: *const InternalLinksOptions,
    ctx: *zenfmt.FilterContext,
    node: zenfmt.ast.InlineIndex,
) zenfmt.FilterError!zenfmt.FilterAction {
    const link = switch (ctx.inlineView(node).content) {
        .link => |value| value,
        else => unreachable,
    };
    const target = ctx.text(link.url);
    if (!std.mem.startsWith(u8, target, "#")) return .keep;

    const absolute = try ctx.fmt("{s}{s}", .{ options.base, target[1..] });
    try ctx.replaceLinkTarget(node, absolute);
    return .replace;
}

pub fn main(init: std.process.Init) !u8 {
    var pipeline: zenfmt.Pipeline = .empty;
    filters(&pipeline);
    return cli.main(init, &pipeline);
}
