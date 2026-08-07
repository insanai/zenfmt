//! Writer lowering (ZDS 0013, Writer Lowering).
//!
//! A writer declares its capabilities at compile time: which kernel tags it
//! emits exactly, which it lowers through declared degradation rules, and
//! which it refuses. The declaration is validated for totality against the
//! schema table, so an uncovered tag is a compile error, not a silent gap.
//!
//! At run time a `Plan` accumulates rule hits as the writer walks the
//! document. Each rule carries its lexicographic `LossCost` (ZDS 0013,
//! Definition 7) and its diagnostic constructor; the engine prices the
//! selected plan, gates the graded `--strict` predicate before anything is
//! committed, and flushes one aggregated report per rule in first-hit
//! order. Every alternative here is single-valued, so the unique-minimum
//! guarantee of ZDS 0013 Theorem 5 holds trivially; the machinery is the
//! cost accounting, the refusal gate, and the loss reports.

const std = @import("std");
const assert = std.debug.assert;
const ast = @import("ast.zig");
const schema = @import("schema.zig");
const report_mod = @import("report.zig");
const limits_mod = @import("limits.zig");

/// The lexicographic loss-cost vector (ZDS 0013, Definition 7). Components,
/// in order: dropped semantic content; structural degradation; style,
/// layout, revision, and metadata loss; emitted warnings; refusal
/// pressure; writer-local cost.
pub const LossCost = [6]u32;

pub const zero_cost: LossCost = .{ 0, 0, 0, 0, 0, 0 };

pub fn addCost(a: LossCost, b: LossCost) LossCost {
    var sum: LossCost = undefined;
    for (&sum, a, b) |*out, x, y| out.* = x +| y;
    return sum;
}

pub fn scaleCost(cost: LossCost, count: u32) LossCost {
    var scaled: LossCost = undefined;
    for (&scaled, cost) |*out, component| out.* = component *| count;
    return scaled;
}

/// The graded strict predicate (ZDS 0013, Strict mode and refusal).
pub const Strictness = enum(u8) {
    off,
    /// Refuse when any semantic content is dropped. Bare `--strict`.
    content,
    /// Additionally refuse structural degradation.
    structure,
    /// Additionally refuse style, layout, revision, and metadata loss.
    exact,

    pub fn refuses(grade: Strictness, cost: LossCost) bool {
        return switch (grade) {
            .off => false,
            .content => cost[0] > 0,
            .structure => cost[0] +| cost[1] > 0,
            .exact => cost[0] +| cost[1] +| cost[2] > 0,
        };
    }

    pub fn parse(text: []const u8) ?Strictness {
        if (std.mem.eql(u8, text, "content")) return .content;
        if (std.mem.eql(u8, text, "structure")) return .structure;
        if (std.mem.eql(u8, text, "exact")) return .exact;
        return null;
    }
};

/// One declared degradation: a stable name, its priced loss, and the
/// diagnostic the engine emits when the rule fired.
pub const Rule = struct {
    name: []const u8,
    cost: LossCost,
    note: *const fn () report_mod.Report,
};

pub const FacetKind = enum(u8) { provenance, style, layout, grid, revision };

/// A writer's compile-time capability declaration (ZDS 0013). Every kernel
/// tag must appear in exactly one of exact, lowered, or refused;
/// `validate` enforces totality against the schema table.
pub const Capabilities = struct {
    exact_blocks: []const ast.BlockTag,
    exact_inlines: []const ast.InlineTag,
    /// Tags the writer emits through degradation rules.
    lowered_blocks: []const ast.BlockTag = &.{},
    lowered_inlines: []const ast.InlineTag = &.{},
    /// Constructs the writer refuses in every mode.
    refused_blocks: []const ast.BlockTag = &.{},
    refused_inlines: []const ast.InlineTag = &.{},
    /// The degradation rules the writer's emission sites may hit.
    rules: []const Rule,
    /// Facet kinds this writer consumes; everything else is carried but
    /// unused (manifest schema v2 reports it as such).
    facets: []const FacetKind = &.{},
    /// Extension namespaces this writer understands.
    extensions: []const []const u8 = &.{},

    /// Comptime totality: exactly one disposition per tag, and distinct
    /// rule names. Call from a `comptime` block next to the declaration.
    pub fn validate(comptime caps: Capabilities) void {
        @setEvalBranchQuota(100_000);
        inline for (@typeInfo(ast.BlockTag).@"enum".fields) |field| {
            const tag: ast.BlockTag = @enumFromInt(field.value);
            const spellings = countTag(ast.BlockTag, tag, caps.exact_blocks) +
                countTag(ast.BlockTag, tag, caps.lowered_blocks) +
                countTag(ast.BlockTag, tag, caps.refused_blocks);
            if (spellings != 1) @compileError(
                "WRITER CAPABILITIES INCOMPLETE\n\nWhat went wrong: the block tag '" ++
                    field.name ++ "' must appear in exactly one of exact_blocks, " ++
                    "lowered_blocks, or refused_blocks.\n",
            );
        }
        inline for (@typeInfo(ast.InlineTag).@"enum".fields) |field| {
            const tag: ast.InlineTag = @enumFromInt(field.value);
            const spellings = countTag(ast.InlineTag, tag, caps.exact_inlines) +
                countTag(ast.InlineTag, tag, caps.lowered_inlines) +
                countTag(ast.InlineTag, tag, caps.refused_inlines);
            if (spellings != 1) @compileError(
                "WRITER CAPABILITIES INCOMPLETE\n\nWhat went wrong: the inline tag '" ++
                    field.name ++ "' must appear in exactly one of exact_inlines, " ++
                    "lowered_inlines, or refused_inlines.\n",
            );
        }
        inline for (caps.rules, 0..) |rule, i| {
            inline for (caps.rules[i + 1 ..]) |later| {
                if (comptime std.mem.eql(u8, rule.name, later.name)) @compileError(
                    "DUPLICATE LOWERING RULE\n\nWhat went wrong: two rules are both " ++
                        "named '" ++ rule.name ++ "'; rule names are the stable " ++
                        "identifiers ZDS 0013 ties costs and diagnostics to.\n",
                );
            }
        }
        // The schema table is the totality oracle: the loops above iterate
        // its tag enums, so a new tag fails here until the writer decides
        // its disposition.
        comptime assert(schema.block_schema.len == @typeInfo(ast.BlockTag).@"enum".fields.len);
    }

    fn countTag(comptime Tag: type, comptime tag: Tag, comptime list: []const Tag) usize {
        var count: usize = 0;
        for (list) |entry| {
            if (entry == tag) count += 1;
        }
        return count;
    }
};

/// The runtime accumulator for one conversion: rule hit counts in
/// first-hit order. Hits are infallible so emission sites stay simple;
/// the work bound is checked at flush.
pub const Plan = struct {
    rules: []const Rule,
    counts: []u32,
    /// Rule indices in first-hit order, so flushed reports keep the order
    /// the document produced them in.
    order: []u16,
    order_len: u32 = 0,
    total_hits: u64 = 0,

    pub fn init(arena: std.mem.Allocator, rules: []const Rule) error{OutOfMemory}!Plan {
        assert(rules.len <= std.math.maxInt(u16));
        const counts = try arena.alloc(u32, rules.len);
        @memset(counts, 0);
        return .{
            .rules = rules,
            .counts = counts,
            .order = try arena.alloc(u16, rules.len),
        };
    }

    pub fn hit(plan: *Plan, rule_index: u16) void {
        assert(rule_index < plan.rules.len);
        if (plan.counts[rule_index] == 0) {
            plan.order[plan.order_len] = rule_index;
            plan.order_len += 1;
        }
        plan.counts[rule_index] +|= 1;
        plan.total_hits +|= 1;
    }

    /// The plan's aggregated loss (ZDS 0013): each fired rule's cost,
    /// scaled by its count, summed with saturation.
    pub fn cost(plan: *const Plan) LossCost {
        var total = zero_cost;
        for (plan.rules, plan.counts) |rule, count| {
            if (count == 0) continue;
            total = addCost(total, scaleCost(rule.cost, count));
        }
        return total;
    }

    /// Emits one aggregated report per fired rule, in first-hit order, and
    /// enforces the planning work bound.
    pub fn flush(
        plan: *const Plan,
        reports: *report_mod.Reports,
        limits: limits_mod.Limits,
    ) error{ OutOfMemory, LimitExceeded }!void {
        if (plan.total_hits > limits.max_lowering_work) return error.LimitExceeded;
        for (plan.order[0..plan.order_len]) |rule_index| {
            var note = plan.rules[rule_index].note();
            note.count = plan.counts[rule_index];
            try reports.add(note);
        }
    }
};

/// Scans the document for a construct the writer refuses in every mode
/// (ZDS 0013, Strict mode and refusal). Walks the body and every note
/// forest, and each leaf block's inline range; returns the offending tag
/// name. Bounded by the snapshot's ranges.
pub fn findRefused(caps: *const Capabilities, doc: *const ast.Document) ?[]const u8 {
    if (caps.refused_blocks.len == 0 and caps.refused_inlines.len == 0) return null;
    if (scanBlockRange(caps, doc, doc.body)) |name| return name;
    for (doc.store.block_ranges.items) |range| {
        if (scanBlockRange(caps, doc, range)) |name| return name;
    }
    return null;
}

fn scanBlockRange(
    caps: *const Capabilities,
    doc: *const ast.Document,
    range: ast.BlockRange,
) ?[]const u8 {
    const tags = doc.store.blocks.items(.tag);
    const inline_ranges = doc.store.blocks.items(.inlines);
    const inline_tags = doc.store.inlines.items(.tag);
    assert(range.endRaw() <= tags.len);

    var index = range.startRaw();
    while (index < range.endRaw()) : (index += 1) {
        for (caps.refused_blocks) |refused| {
            if (tags[index] == refused) return @tagName(refused);
        }
        const inlines = inline_ranges[index];
        if (inlines.isEmpty()) continue;
        assert(inlines.endRaw() <= inline_tags.len);
        for (inline_tags[inlines.startRaw()..inlines.endRaw()]) |inline_tag| {
            for (caps.refused_inlines) |refused| {
                if (inline_tag == refused) return @tagName(refused);
            }
        }
    }
    return null;
}

/// The loss already recorded by the reader and filters, mapped onto the
/// cost vector by tier: dropped content is component one, degradation is
/// component three. The strict gate prices the whole conversion, not just
/// the writer's plan.
pub fn reportedCost(reports: *const report_mod.Reports) LossCost {
    var total = zero_cost;
    for (reports.entries.items) |entry| {
        const tier = entry.report.loss orelse continue;
        const count = entry.report.count;
        switch (tier) {
            .dropped => total[0] +|= count,
            .degraded => total[2] +|= count,
        }
    }
    return total;
}

// ---------------------------------------------------------------- tests

test "strictness grades refuse along the lexicographic components" {
    const dropped: LossCost = .{ 1, 0, 0, 0, 0, 0 };
    const structural: LossCost = .{ 0, 2, 0, 0, 0, 0 };
    const styled: LossCost = .{ 0, 0, 3, 0, 0, 0 };

    try std.testing.expect(!Strictness.off.refuses(dropped));
    try std.testing.expect(Strictness.content.refuses(dropped));
    try std.testing.expect(!Strictness.content.refuses(structural));
    try std.testing.expect(Strictness.structure.refuses(structural));
    try std.testing.expect(!Strictness.structure.refuses(styled));
    try std.testing.expect(Strictness.exact.refuses(styled));
    try std.testing.expect(!Strictness.exact.refuses(zero_cost));
}

test "a plan prices hits and flushes counted reports in first-hit order" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const notes = struct {
        fn first() report_mod.Report {
            return .{
                .severity = .note,
                .code = "test.first",
                .title = "FIRST",
                .problem = "First rule fired.",
                .consequence = "Nothing.",
            };
        }
        fn second() report_mod.Report {
            return .{
                .severity = .note,
                .code = "test.second",
                .title = "SECOND",
                .problem = "Second rule fired.",
                .consequence = "Nothing.",
            };
        }
    };
    const rules = [_]Rule{
        .{ .name = "first", .cost = .{ 1, 0, 0, 0, 0, 0 }, .note = notes.first },
        .{ .name = "second", .cost = .{ 0, 0, 1, 0, 0, 0 }, .note = notes.second },
    };

    var plan = try Plan.init(arena, &rules);
    plan.hit(1);
    plan.hit(0);
    plan.hit(1);
    try std.testing.expectEqual(LossCost{ 1, 0, 2, 0, 0, 0 }, plan.cost());

    var reports = report_mod.Reports.init(arena, .{});
    try plan.flush(&reports, .{});
    const final = try reports.finalize();
    try std.testing.expectEqual(@as(usize, 2), final.len);
    try std.testing.expectEqualStrings("test.second", final[0].code);
    try std.testing.expectEqual(@as(u32, 2), final[0].count);
    try std.testing.expectEqualStrings("test.first", final[1].code);
}
