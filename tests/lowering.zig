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
            .loss = .presentation,
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
        .propose = propose,
    };

    fn propose(
        context: *const lowering.ProposalContext,
        node: lowering.Node,
        alternatives: *lowering.Alternatives,
    ) lowering.PlanError!void {
        const index = switch (node) {
            .@"inline" => |value| value,
            .block => return error.InvalidPlan,
        };
        if (context.doc.inlineTag(index) == .emphasis) {
            const id: u16 = @intFromEnum(RuleId.emphasis_dropped);
            try alternatives.add(lowering.Alternative.degraded(.omit, id, &.{id}));
            return;
        }

        // Two applicable alternatives prove that the planner, rather than
        // writer branch order, makes the choice. Lexicographic loss keeps
        // the content-preserving splice despite its larger stable id.
        const dropped: u16 = @intFromEnum(RuleId.emphasis_dropped);
        const styled: u16 = @intFromEnum(RuleId.underline_styled);
        try alternatives.add(lowering.Alternative.degraded(.omit, 0, &.{dropped}));
        try alternatives.add(lowering.Alternative.degraded(.splice_children, 1, &.{styled}));
    }

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
                        const payloads = doc.store.inlines.items(.payload);
                        const span = doc.store.spans.items[payloads[index]];
                        for (doc.text(span)) |byte| {
                            try ctx.out.writeByte(std.ascii.toUpper(byte));
                        }
                    },
                    .space => try ctx.out.writeAll(" "),
                    .emphasis => {
                        const instruction = ctx.plan.?.instruction(.{
                            .@"inline" = @enumFromInt(index),
                        }).?;
                        ctx.plan.?.hit(instruction.primary_rule);
                        if (!instruction.delegates_children) {
                            index += doc.store.inlines.items(.subtree_len)[index] - 1;
                        }
                    },
                    .underline => {
                        const instruction = ctx.plan.?.instruction(.{
                            .@"inline" = @enumFromInt(index),
                        }).?;
                        ctx.plan.?.hit(instruction.primary_rule);
                        if (!instruction.delegates_children) {
                            index += doc.store.inlines.items(.subtree_len)[index] - 1;
                        }
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
    const hidden_underline = try ctx.out.beginInline(.underline);
    try ctx.out.text("gone");
    ctx.out.endInline(hidden_underline);
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

fn convertStyled(
    gpa: std.mem.Allocator,
    out: *std.Io.Writer,
    format: []const u8,
    strict: core.Strictness,
) core.Conversion {
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
    var styled_count: u32 = 0;
    for (conversion.reports) |entry| {
        if (std.mem.eql(u8, entry.code, "shouty.emphasis-dropped")) saw_dropped = true;
        if (std.mem.eql(u8, entry.code, "shouty.underline-styled")) {
            styled_count = entry.count;
        }
    }
    try testing.expect(saw_dropped);
    // The underline inside omitted emphasis is not part of the selected
    // emission plan and therefore does not leak into diagnostics.
    try testing.expectEqual(@as(u32, 1), styled_count);
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

test "lowering limits refuse before output with an actionable hint" {
    const gpa = testing.allocator;
    var buffer: [4096]u8 = undefined;
    var out = std.Io.Writer.fixed(&buffer);
    var conversion = Bundle.convert(gpa, testing.io, .{
        .input = .{ .bytes = .{ .name = "doc.any", .data = "irrelevant" } },
        .output = .{ .writer = &out },
        .from = "underlined",
        .limits = .{ .max_lowering_alternatives = 1 },
    });
    defer conversion.deinit(gpa);

    try testing.expectEqual(core.Status.failed, conversion.status);
    try testing.expectEqual(@as(usize, 0), out.buffered().len);
    try testing.expectEqualStrings("core.lowering-limit", conversion.reports[0].code);
    try testing.expect(std.mem.indexOf(
        u8,
        conversion.reports[0].directions[0].explanation,
        "--limit max_lowering_alternatives=2",
    ) != null);
}

test "lowering work is bounded before the writer opens" {
    const gpa = testing.allocator;
    var buffer: [256]u8 = undefined;
    var out = std.Io.Writer.fixed(&buffer);
    var conversion = Bundle.convert(gpa, testing.io, .{
        .input = .{ .bytes = .{ .name = "doc.any", .data = "irrelevant" } },
        .output = .{ .writer = &out },
        .from = "underlined",
        .limits = .{ .max_lowering_work = 1 },
    });
    defer conversion.deinit(gpa);

    try testing.expectEqual(core.Status.failed, conversion.status);
    try testing.expectEqual(core.Conversion.StreamState.untouched, conversion.stream);
    try testing.expectEqual(@as(usize, 0), out.buffered().len);
    const diagnostic = conversion.reports[0];
    try testing.expectEqualStrings("core.lowering-limit", diagnostic.code);
    try testing.expect(diagnostic.context != null);
    try testing.expect(std.mem.indexOf(
        u8,
        diagnostic.directions[0].explanation,
        "--limit max_lowering_work=2",
    ) != null);
}

// --------------------------------------- deterministic-plan adversaries

fn proposeStableTie(
    context: *const lowering.ProposalContext,
    node: lowering.Node,
    alternatives: *lowering.Alternatives,
) lowering.PlanError!void {
    _ = context;
    _ = node;
    const rule: u16 = @intFromEnum(shouty.RuleId.underline_styled);
    try alternatives.add(lowering.Alternative.degraded(.omit, 9, &.{rule}));
    try alternatives.add(lowering.Alternative.degraded(.splice_children, 1, &.{rule}));
}

fn proposeDuplicateId(
    context: *const lowering.ProposalContext,
    node: lowering.Node,
    alternatives: *lowering.Alternatives,
) lowering.PlanError!void {
    _ = context;
    _ = node;
    const rule: u16 = @intFromEnum(shouty.RuleId.underline_styled);
    try alternatives.add(lowering.Alternative.degraded(.omit, 1, &.{rule}));
    try alternatives.add(lowering.Alternative.degraded(.splice_children, 1, &.{rule}));
}

fn adversarialWriter(
    comptime format: []const u8,
    comptime propose: lowering.ProposeFn,
) core.plugin.WriterDescriptor {
    const capabilities: lowering.Capabilities = .{
        .exact_blocks = shouty.capabilities.exact_blocks,
        .refused_blocks = shouty.capabilities.refused_blocks,
        .exact_inlines = shouty.capabilities.exact_inlines,
        .lowered_inlines = shouty.capabilities.lowered_inlines,
        .rules = shouty.capabilities.rules,
        .propose = propose,
    };
    capabilities.validate();
    return core.Writer(.{
        .id = "ai.insan.zenfmt.test-" ++ format,
        .format = format,
        .extensions = &.{format},
        .write = shouty.write,
        .capabilities = &capabilities,
    });
}

test "equal-cost alternatives select the lowest stable id" {
    const TieBundle = core.Bundle(.{
        .readers = .{fixtureReader("tie", readUnderlineOnly)},
        .writers = .{adversarialWriter("tieout", proposeStableTie)},
    });
    var buffer: [64]u8 = undefined;
    var out = std.Io.Writer.fixed(&buffer);
    var conversion = TieBundle.convert(testing.allocator, testing.io, .{
        .input = .{ .bytes = .{ .name = "doc.tie", .data = "x" } },
        .output = .{ .writer = &out },
    });
    defer conversion.deinit(testing.allocator);

    try testing.expectEqual(core.Status.success, conversion.status);
    try testing.expectEqualStrings("STYLED\n", out.buffered());
}

test "duplicate stable ids refuse before output" {
    const DuplicateBundle = core.Bundle(.{
        .readers = .{fixtureReader("duplicate", readUnderlineOnly)},
        .writers = .{adversarialWriter("duplicateout", proposeDuplicateId)},
    });
    var buffer: [64]u8 = undefined;
    var out = std.Io.Writer.fixed(&buffer);
    var conversion = DuplicateBundle.convert(testing.allocator, testing.io, .{
        .input = .{ .bytes = .{ .name = "doc.duplicate", .data = "x" } },
        .output = .{ .writer = &out },
    });
    defer conversion.deinit(testing.allocator);

    try testing.expectEqual(core.Status.failed, conversion.status);
    try testing.expectEqual(core.Conversion.StreamState.untouched, conversion.stream);
    try testing.expectEqual(@as(usize, 0), out.buffered().len);
    try testing.expectEqualStrings(
        "core.invalid-lowering-plan",
        conversion.reports[0].code,
    );
    try testing.expect(conversion.reports[0].directions.len > 0);
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

fn readCyclicNote(ctx: *core.ReadContext) core.ReadError!void {
    const note = try ctx.out.declareNote();
    const paragraph = try ctx.out.beginParagraph();
    try ctx.out.text("body");
    try ctx.out.noteReference(note);
    try ctx.out.noteReference(note);
    ctx.out.endBlock(paragraph);

    ctx.out.beginNoteBody(note);
    const note_paragraph = try ctx.out.beginParagraph();
    try ctx.out.text("note");
    try ctx.out.noteReference(note);
    ctx.out.endBlock(note_paragraph);
    ctx.out.endNoteBody(note);
}

test "note rendering deduplicates repeated and cyclic references" {
    const NoteBundle = core.Bundle(.{
        .readers = .{fixtureReader("cyclicnote", readCyclicNote)},
        .writers = .{markdown.writer},
    });
    var buffer: [256]u8 = undefined;
    var out = std.Io.Writer.fixed(&buffer);
    var conversion = NoteBundle.convert(testing.allocator, testing.io, .{
        .input = .{ .bytes = .{ .name = "doc.cyclicnote", .data = "x" } },
        .output = .{ .writer = &out },
    });
    defer conversion.deinit(testing.allocator);

    try testing.expectEqual(core.Status.success, conversion.status);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, out.buffered(), "[^1]:"));
    try testing.expect(std.mem.indexOf(u8, out.buffered(), "body[^1][^1]") != null);
    try testing.expect(std.mem.indexOf(u8, out.buffered(), "note[^1]") != null);
}

fn readNoteInsideOmittedTable(ctx: *core.ReadContext) core.ReadError!void {
    const note = try ctx.out.declareNote();
    const outer = try ctx.out.beginTable(&.{.default});
    const outer_body = try ctx.out.beginTableBody(.{
        .row_head_columns = 0,
        .head_rows = 0,
    });
    const outer_row = try ctx.out.beginBlock(.table_row);
    const outer_cell = try ctx.out.beginTableCell(.plain);
    const inner = try ctx.out.beginTable(&.{.default});
    const inner_body = try ctx.out.beginTableBody(.{
        .row_head_columns = 0,
        .head_rows = 0,
    });
    const inner_row = try ctx.out.beginBlock(.table_row);
    const inner_cell = try ctx.out.beginTableCell(.plain);
    const inner_text = try ctx.out.beginPlain();
    try ctx.out.noteReference(note);
    ctx.out.endBlock(inner_text);
    ctx.out.endBlock(inner_cell);
    ctx.out.endBlock(inner_row);
    ctx.out.endBlock(inner_body);
    ctx.out.endBlock(inner);
    ctx.out.endBlock(outer_cell);
    ctx.out.endBlock(outer_row);
    ctx.out.endBlock(outer_body);
    ctx.out.endBlock(outer);

    ctx.out.beginNoteBody(note);
    const note_body = try ctx.out.beginParagraph();
    const underline = try ctx.out.beginInline(.underline);
    try ctx.out.text("hidden note");
    ctx.out.endInline(underline);
    ctx.out.endBlock(note_body);
    ctx.out.endNoteBody(note);
}

test "a note hidden by selected lowering contributes no phantom loss" {
    const NoteBundle = core.Bundle(.{
        .readers = .{fixtureReader("omittednote", readNoteInsideOmittedTable)},
        .writers = .{markdown.writer},
    });
    var buffer: [256]u8 = undefined;
    var out = std.Io.Writer.fixed(&buffer);
    var conversion = NoteBundle.convert(testing.allocator, testing.io, .{
        .input = .{ .bytes = .{ .name = "doc.omittednote", .data = "x" } },
        .output = .{ .writer = &out },
    });
    defer conversion.deinit(testing.allocator);

    try testing.expectEqual(core.Status.success, conversion.status);
    try testing.expect(std.mem.indexOf(u8, out.buffered(), "(nested table)") != null);
    for (conversion.reports) |entry| {
        try testing.expect(!std.mem.eql(u8, entry.code, "markdown.style-dropped"));
    }
}
