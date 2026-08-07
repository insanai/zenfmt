//! End-to-end coverage for writer lowering (ZDS 0013): a synthetic second
//! writer proves that capability declarations, priced rule hits, graded
//! strict refusal, and mode-independent construct refusal all work outside
//! the Markdown writer they were extracted from.

const std = @import("std");
const testing = std.testing;
const core = @import("zenfmt_core");
const markdown = @import("zenfmt_markdown");

const lowering = core.lowering;

// ------------------------------------------------------- synthetic writer

/// A deliberately lossy writer: emphasis is dropped as a content loss,
/// underline as a style loss, and tables are refused outright.
const shouty = struct {
    const RuleId = enum(u16) { emphasis_dropped, underline_styled };

    fn emphasisDroppedNote() core.Report {
        return .{
            .severity = .warning,
            .code = "shouty.emphasis-dropped",
            .title = "EMPHASIS DROPPED",
            .problem = "The shouty format cannot spell emphasis.",
            .consequence = "The emphasized text was removed entirely.",
            .loss = .dropped,
            .directions = &.{.{
                .title = "Keep the source",
                .explanation = "Keep the source if emphasis matters.",
            }},
        };
    }

    fn underlineStyledNote() core.Report {
        return .{
            .severity = .note,
            .code = "shouty.underline-styled",
            .title = "UNDERLINE DROPPED",
            .problem = "The shouty format cannot spell underline.",
            .consequence = "The text was kept; the underline was dropped.",
            .loss = .degraded,
            .directions = &.{.{
                .title = "Keep the source",
                .explanation = "Keep the source if styling matters.",
            }},
        };
    }

    const rules = [_]lowering.Rule{
        .{ .name = "emphasis-dropped", .cost = .{ 1, 0, 0, 0, 0, 0 }, .note = emphasisDroppedNote },
        .{ .name = "underline-styled", .cost = .{ 0, 0, 1, 0, 0, 0 }, .note = underlineStyledNote },
    };

    const capabilities: lowering.Capabilities = .{
        .exact_blocks = &.{
            .plain,           .paragraph,       .line_block, .heading,
            .code_block,      .raw_block,       .quote,      .list,
            .definition_list, .thematic_break,  .figure,     .container,
            .extension,       .line,            .list_item,  .definition_entry,
            .definition_term, .definition_body, .caption,    .table_head,
            .table_body,      .table_foot,      .table_row,  .table_cell,
        },
        .refused_blocks = &.{.table},
        .exact_inlines = &.{
            .text,        .space,     .soft_break, .hard_break, .strong, .strikethrough,
            .superscript, .subscript, .small_caps, .quote,      .code,   .math,
            .raw,         .link,      .image,      .note,       .span,   .citation,
            .extension,
        },
        .lowered_inlines = &.{ .emphasis, .underline },
        .rules = &rules,
    };

    comptime {
        capabilities.validate();
    }

    fn write(ctx: *core.WriteContext) core.WriteError!void {
        const doc = ctx.doc;
        const tags = doc.store.inlines.items(.tag);
        var roots = doc.blockRoots(doc.body);
        while (roots.next()) |block_index| {
            const view = doc.block(block_index);
            const inlines = switch (view.content) {
                .paragraph, .plain => |value| value,
                else => continue,
            };
            var index = inlines.startRaw();
            while (index < inlines.endRaw()) : (index += 1) {
                switch (tags[index]) {
                    .text => {
                        const span = doc.store.spans.items[doc.store.inlines.items(.payload)[index]];
                        for (doc.text(span)) |byte| {
                            try ctx.out.writeByte(std.ascii.toUpper(byte));
                        }
                    },
                    .space => try ctx.out.writeAll(" "),
                    .emphasis => {
                        if (ctx.plan) |plan| plan.hit(@intFromEnum(RuleId.emphasis_dropped));
                        // Dropped: skip the emphasized subtree entirely.
                        index += doc.store.inlines.items(.subtree_len)[index] - 1;
                    },
                    .underline => {
                        if (ctx.plan) |plan| plan.hit(@intFromEnum(RuleId.underline_styled));
                    },
                    else => {},
                }
            }
            try ctx.out.writeAll("\n");
        }
    }

    const descriptor = core.Writer(.{
        .id = "ai.insan.zenfmt.test-shouty",
        .format = "shouty",
        .extensions = &.{"shout"},
        .write = write,
        .capabilities = &capabilities,
    });
};

// ------------------------------------------------------ fixture readers

fn readStyled(ctx: *core.ReadContext) core.ReadError!void {
    const paragraph = try ctx.out.beginParagraph();
    try ctx.out.text("keep ");
    const emphasis = try ctx.out.beginInline(.emphasis);
    try ctx.out.text("gone");
    ctx.out.endInline(emphasis);
    try ctx.out.text(" and ");
    const underline = try ctx.out.beginInline(.underline);
    try ctx.out.text("styled");
    ctx.out.endInline(underline);
    ctx.out.endBlock(paragraph);
}

fn readUnderlineOnly(ctx: *core.ReadContext) core.ReadError!void {
    const paragraph = try ctx.out.beginParagraph();
    const underline = try ctx.out.beginInline(.underline);
    try ctx.out.text("styled");
    ctx.out.endInline(underline);
    ctx.out.endBlock(paragraph);
}

fn readTable(ctx: *core.ReadContext) core.ReadError!void {
    const table = try ctx.out.beginTable(&.{.default});
    const body = try ctx.out.beginTableBody(.{ .row_head_columns = 0, .head_rows = 0 });
    const row = try ctx.out.beginBlock(.table_row);
    const cell = try ctx.out.beginTableCell(.plain);
    const paragraph = try ctx.out.beginPlain();
    try ctx.out.text("x");
    ctx.out.endBlock(paragraph);
    ctx.out.endBlock(cell);
    ctx.out.endBlock(row);
    ctx.out.endBlock(body);
    ctx.out.endBlock(table);
}

fn fixtureReader(comptime format: []const u8, comptime read: anytype) core.plugin.ReaderDescriptor {
    return core.Reader(.{
        .id = "ai.insan.zenfmt.test-" ++ format,
        .format = format,
        .extensions = &.{format},
        .read = read,
    });
}

const Bundle = core.Bundle(.{
    .readers = .{
        fixtureReader("styled", readStyled),
        fixtureReader("underlined", readUnderlineOnly),
        fixtureReader("tabular", readTable),
    },
    .writers = .{shouty.descriptor},
});

fn convertStyled(gpa: std.mem.Allocator, out: *std.Io.Writer, format: []const u8, strict: core.Strictness) core.Conversion {
    return Bundle.convert(gpa, testing.io, .{
        .input = .{ .bytes = .{ .name = "doc.any", .data = "irrelevant" } },
        .output = .{ .writer = out },
        .from = format,
        .strict = strict,
    });
}

test "a lossy plan converts with priced, counted reports when strict is off" {
    const gpa = testing.allocator;
    var buffer: [4096]u8 = undefined;
    var out = std.Io.Writer.fixed(&buffer);
    var conversion = convertStyled(gpa, &out, "styled", .off);
    defer conversion.deinit(gpa);

    try testing.expectEqual(core.Status.success, conversion.status);
    try testing.expectEqualStrings("KEEP  AND STYLED\n", out.buffered());

    var saw_dropped = false;
    var saw_styled = false;
    for (conversion.reports) |entry| {
        if (std.mem.eql(u8, entry.code, "shouty.emphasis-dropped")) saw_dropped = true;
        if (std.mem.eql(u8, entry.code, "shouty.underline-styled")) saw_styled = true;
    }
    try testing.expect(saw_dropped);
    try testing.expect(saw_styled);
}

test "bare strict refuses dropped content before any output" {
    const gpa = testing.allocator;
    var buffer: [4096]u8 = undefined;
    var out = std.Io.Writer.fixed(&buffer);
    var conversion = convertStyled(gpa, &out, "styled", .content);
    defer conversion.deinit(gpa);

    try testing.expectEqual(core.Status.failed, conversion.status);
    // Nothing was streamed: the dry run gated before emission.
    try testing.expectEqual(@as(usize, 0), out.buffered().len);
    var refused = false;
    for (conversion.reports) |entry| {
        if (std.mem.eql(u8, entry.code, "core.strict-refused")) refused = true;
    }
    try testing.expect(refused);
}

test "the strict grades separate content, structure, and style loss" {
    const gpa = testing.allocator;

    // Style-only loss passes content and structure grades, fails exact.
    inline for (.{ .content, .structure }) |grade| {
        var buffer: [4096]u8 = undefined;
        var out = std.Io.Writer.fixed(&buffer);
        var conversion = convertStyled(gpa, &out, "underlined", grade);
        defer conversion.deinit(gpa);
        try testing.expectEqual(core.Status.success, conversion.status);
    }
    var buffer: [4096]u8 = undefined;
    var out = std.Io.Writer.fixed(&buffer);
    var conversion = convertStyled(gpa, &out, "underlined", .exact);
    defer conversion.deinit(gpa);
    try testing.expectEqual(core.Status.failed, conversion.status);
}

test "a refused construct fails in every mode" {
    const gpa = testing.allocator;
    var buffer: [4096]u8 = undefined;
    var out = std.Io.Writer.fixed(&buffer);
    var conversion = convertStyled(gpa, &out, "tabular", .off);
    defer conversion.deinit(gpa);

    try testing.expectEqual(core.Status.failed, conversion.status);
    try testing.expectEqual(@as(usize, 0), out.buffered().len);
    var refused = false;
    for (conversion.reports) |entry| {
        if (std.mem.eql(u8, entry.code, "core.construct-refused")) refused = true;
    }
    try testing.expect(refused);
}

// ------------------------------------------------- markdown graded strict

fn readUnderlined(ctx: *core.ReadContext) core.ReadError!void {
    const paragraph = try ctx.out.beginParagraph();
    const underline = try ctx.out.beginInline(.underline);
    try ctx.out.text("styled");
    ctx.out.endInline(underline);
    ctx.out.endBlock(paragraph);
}

const MarkdownBundle = core.Bundle(.{
    .readers = .{fixtureReader("styledmd", readUnderlined)},
    .writers = .{markdown.writer},
});

test "markdown accepts style loss under content strict and refuses under exact" {
    const gpa = testing.allocator;

    var accept_buffer: [4096]u8 = undefined;
    var accept_out = std.Io.Writer.fixed(&accept_buffer);
    var accepted = MarkdownBundle.convert(gpa, testing.io, .{
        .input = .{ .bytes = .{ .name = "doc.styledmd", .data = "x" } },
        .output = .{ .writer = &accept_out },
        .strict = .content,
    });
    defer accepted.deinit(gpa);
    try testing.expectEqual(core.Status.success, accepted.status);
    try testing.expectEqualStrings("styled\n", accept_out.buffered());

    var refuse_buffer: [4096]u8 = undefined;
    var refuse_out = std.Io.Writer.fixed(&refuse_buffer);
    var refused = MarkdownBundle.convert(gpa, testing.io, .{
        .input = .{ .bytes = .{ .name = "doc.styledmd", .data = "x" } },
        .output = .{ .writer = &refuse_out },
        .strict = .exact,
    });
    defer refused.deinit(gpa);
    try testing.expectEqual(core.Status.failed, refused.status);
    try testing.expectEqual(@as(usize, 0), refuse_out.buffered().len);
}
