//! Bounded writer lowering (ZDS 0013, Writer Lowering).
//!
//! Planning and rendering are separate phases. A writer declares a total
//! disposition for every kernel tag and, for lowered tags, a pure proposer
//! which returns a bounded set of instruction descriptors. The planner walks
//! the reachable document bottom-up, chooses the unique lexicographic minimum,
//! prices it, and builds diagnostics before the output stream is touched.

const std = @import("std");
const assert = std.debug.assert;
const ast = @import("ast.zig");
const schema = @import("schema.zig");
const report_mod = @import("report.zig");
const limits_mod = @import("limits.zig");
const cost_mod = @import("lowering_cost.zig");
const decision_index = @import("lowering_decisions.zig");
const reachability = @import("lowering_reachability.zig");
pub const LossCost = cost_mod.LossCost;
pub const zero_cost = cost_mod.zero;
pub const CostError = cost_mod.Error;
pub const addCost = cost_mod.add;
pub const scaleCost = cost_mod.scale;
pub const Strictness = cost_mod.Strictness;
const costLessThan = cost_mod.lessThan;
pub const no_rule = std.math.maxInt(u16);
pub const no_node = std.math.maxInt(u32);
pub const max_alternatives_hard: u32 = limits_mod.max_lowering_alternatives_hard;
pub const max_losses_per_alternative: u32 = 4;
pub const Rule = struct {
    name: []const u8,
    cost: LossCost,
    note: *const fn () report_mod.Report,
};
pub const FacetKind = enum(u8) { provenance, style, layout, grid, revision };
pub const Node = union(enum) {
    block: ast.BlockIndex,
    @"inline": ast.InlineIndex,

    pub fn raw(node: Node) u32 {
        return switch (node) {
            .block => |index| index.raw(),
            .@"inline" => |index| index.raw(),
        };
    }
};

pub const Operation = enum(u8) {
    emit_exact,
    emit_degraded,
    wrap,
    splice_children,
    emit_text,
    omit,
};

/// The selected, fixed-size writer instruction. `target` and `data` are
/// writer-owned scalar operands; no candidate subtree is materialized.
pub const Instruction = struct {
    target: u32 = 0,
    data: u32 = 0,
    stable_id: u16,
    primary_rule: u16 = no_rule,
    operation: Operation,
    delegates_children: bool = true,
    reserved: u16 = 0,
};

comptime {
    assert(@sizeOf(Instruction) == 16);
}

pub const Alternative = struct {
    instruction: Instruction,
    losses: [max_losses_per_alternative]u16 = @splat(no_rule),
    loss_count: u8 = 0,
    writer_cost: u64 = 0,

    pub fn exact(stable_id: u16) Alternative {
        return .{ .instruction = .{ .operation = .emit_exact, .stable_id = stable_id } };
    }

    pub fn degraded(operation: Operation, stable_id: u16, losses: []const u16) Alternative {
        assert(operation != .emit_exact);
        assert(losses.len >= 1 and losses.len <= max_losses_per_alternative);
        var result: Alternative = .{
            .instruction = .{ .operation = operation, .stable_id = stable_id },
        };
        for (losses, 0..) |rule, index| result.losses[index] = rule;
        result.loss_count = @intCast(losses.len);
        result.instruction.primary_rule = losses[0];
        if (operation == .omit or operation == .emit_text) {
            result.instruction.delegates_children = false;
        }
        return result;
    }
};

pub const Alternatives = struct {
    items: *[max_alternatives_hard]Alternative,
    len: u32 = 0,
    limit: u32,

    pub fn add(out: *Alternatives, alternative: Alternative) PlanError!void {
        if (out.len >= out.limit) return error.AlternativeLimitExceeded;
        out.items[out.len] = alternative;
        out.len += 1;
    }

    pub fn slice(out: *const Alternatives) []const Alternative {
        return out.items[0..out.len];
    }
};

pub const ProposalContext = struct {
    doc: *const ast.Document,
    extensions: []const []const u8,
    block_ancestors: []const u32 = &.{},
    inline_ancestors: []const u32 = &.{},
    inline_owner: u32 = no_node,

    pub fn blockParent(ctx: *const ProposalContext, index: ast.BlockIndex) ?ast.BlockIndex {
        _ = index;
        if (ctx.block_ancestors.len == 0) return null;
        return @enumFromInt(ctx.block_ancestors[ctx.block_ancestors.len - 1]);
    }

    pub fn inlineParent(ctx: *const ProposalContext, index: ast.InlineIndex) ?ast.InlineIndex {
        _ = index;
        if (ctx.inline_ancestors.len == 0) return null;
        return @enumFromInt(ctx.inline_ancestors[ctx.inline_ancestors.len - 1]);
    }

    pub fn inlineOwner(ctx: *const ProposalContext, index: ast.InlineIndex) ?ast.BlockIndex {
        _ = index;
        return if (ctx.inline_owner == no_node) null else @enumFromInt(ctx.inline_owner);
    }

    pub fn hasBlockAncestor(
        ctx: *const ProposalContext,
        index: ast.BlockIndex,
        tag: ast.BlockTag,
    ) bool {
        _ = index;
        for (ctx.block_ancestors) |ancestor| {
            if (ctx.doc.blockTag(@enumFromInt(ancestor)) == tag) return true;
        }
        return false;
    }

    pub fn supportsExtension(ctx: *const ProposalContext, node: Node) bool {
        const owner = switch (node) {
            .block => |index| blk: {
                const extension = ctx.doc.blockAs(index, .extension) orelse return false;
                break :blk ctx.doc.text(extension.owner);
            },
            .@"inline" => |index| blk: {
                const extension = ctx.doc.inlineAs(index, .extension) orelse return false;
                break :blk ctx.doc.text(extension.owner);
            },
        };
        for (ctx.extensions) |supported| {
            if (std.mem.eql(u8, owner, supported)) return true;
        }
        return false;
    }
};

pub const ProposeFn = *const fn (
    context: *const ProposalContext,
    node: Node,
    alternatives: *Alternatives,
) PlanError!void;

pub const Capabilities = struct {
    exact_blocks: []const ast.BlockTag,
    exact_inlines: []const ast.InlineTag,
    lowered_blocks: []const ast.BlockTag = &.{},
    lowered_inlines: []const ast.InlineTag = &.{},
    refused_blocks: []const ast.BlockTag = &.{},
    refused_inlines: []const ast.InlineTag = &.{},
    rules: []const Rule,
    facets: []const FacetKind = &.{},
    extensions: []const []const u8 = &.{},
    propose: ?ProposeFn = null,

    pub fn validate(comptime caps: Capabilities) void {
        @setEvalBranchQuota(100_000);
        validateTags(ast.BlockTag, caps.exact_blocks, caps.lowered_blocks, caps.refused_blocks);
        validateTags(ast.InlineTag, caps.exact_inlines, caps.lowered_inlines, caps.refused_inlines);
        if ((caps.lowered_blocks.len > 0 or caps.lowered_inlines.len > 0) and
            caps.propose == null)
        {
            @compileError(
                "WRITER LOWERING MISSING\n\n" ++
                    "What happened: Lowered tags have no proposal callback.\n" ++
                    "Where: The writer capability declaration's `.propose` field.\n" ++
                    "What zenfmt did: Compilation stopped before this " ++
                    "incomplete writer could be registered.\n" ++
                    "What you can do: Add a pure `.propose` callback " ++
                    "that returns bounded alternatives for every lowered tag.\n",
            );
        }
        inline for (caps.rules, 0..) |rule, i| {
            inline for (caps.rules[i + 1 ..]) |later| {
                if (comptime std.mem.eql(u8, rule.name, later.name)) {
                    @compileError(
                        "DUPLICATE LOWERING RULE\n\n" ++
                            "What happened: Two lowering rules have the same stable name.\n" ++
                            "Where: The writer capability declaration's `.rules` table.\n" ++
                            "What zenfmt did: Compilation stopped because " ++
                            "diagnostics and tie-breaking would be ambiguous.\n" ++
                            "What you can do: Give every rule a unique, " ++
                            "durable name and update its RuleId entry to match.\n",
                    );
                }
            }
        }
        inline for (caps.extensions, 0..) |owner, index| {
            if (!validNamespace(owner)) @compileError(
                "INVALID EXTENSION NAMESPACE\n\n" ++
                    "What happened: `" ++ owner ++ "` is not a reverse-DNS namespace.\n" ++
                    "Where: The writer capability declaration's `.extensions` list.\n" ++
                    "What zenfmt did: Compilation stopped before extension " ++
                    "routing became ambiguous.\n" ++
                    "What you can do: Use lowercase ASCII segments such " ++
                    "as `ai.insan.zenfmt.html`.\n",
            );
            inline for (caps.extensions[index + 1 ..]) |later| {
                if (comptime std.mem.eql(u8, owner, later)) @compileError(
                    "DUPLICATE EXTENSION NAMESPACE\n\n" ++
                        "What happened: The same extension namespace appears twice.\n" ++
                        "Where: The writer capability declaration's `.extensions` list.\n" ++
                        "What zenfmt did: Compilation stopped before " ++
                        "registering duplicate routing.\n" ++
                        "What you can do: Keep one entry for each supported owner namespace.\n",
                );
            }
        }
        comptime assert(schema.block_schema.len == @typeInfo(ast.BlockTag).@"enum".fields.len);
    }

    fn validateTags(
        comptime Tag: type,
        comptime exact: []const Tag,
        comptime lowered: []const Tag,
        comptime refused: []const Tag,
    ) void {
        inline for (@typeInfo(Tag).@"enum".fields) |field| {
            const tag: Tag = @enumFromInt(field.value);
            const count = countTag(Tag, tag, exact) + countTag(Tag, tag, lowered) +
                countTag(Tag, tag, refused);
            if (count != 1) @compileError(
                "WRITER CAPABILITIES INCOMPLETE\n\n" ++
                    "What happened: The tag `" ++ field.name ++
                    "` does not have exactly one disposition.\n" ++
                    "Where: The writer's exact, lowered, and refused tag lists.\n" ++
                    "What zenfmt did: Compilation stopped before " ++
                    "registering an ambiguous writer.\n" ++
                    "What you can do: Put `" ++ field.name ++
                    "` in exactly one of those three lists.\n",
            );
        }
    }

    fn countTag(comptime Tag: type, comptime tag: Tag, comptime list: []const Tag) usize {
        var count: usize = 0;
        for (list) |entry| if (entry == tag) {
            count += 1;
        };
        return count;
    }

    fn validNamespace(namespace: []const u8) bool {
        if (namespace.len == 0 or namespace[0] == '.' or namespace[namespace.len - 1] == '.') {
            return false;
        }
        var has_dot = false;
        for (namespace) |byte| switch (byte) {
            'a'...'z', '0'...'9', '-' => {},
            '.' => has_dot = true,
            else => return false,
        };
        return has_dot;
    }
};

pub const PlanError = error{
    OutOfMemory,
    AlternativeLimitExceeded,
    WorkLimitExceeded,
    DepthLimitExceeded,
    InvalidPlan,
    CostOverflow,
};

pub const Plan = struct {
    const Decision = struct {
        node: u32,
        instruction: Instruction,
        losses: [max_losses_per_alternative]u16,
        loss_count: u8,
        padding: [3]u8 = @splat(0),
    };

    comptime {
        assert(@sizeOf(Decision) == 32);
    }

    const BlockFrame = struct {
        node: u32,
        end: u32,
        children: LossCost = zero_cost,
    };

    const InlineFrame = struct {
        node: u32,
        end: u32,
        children: LossCost = zero_cost,
    };

    const DecisionCursor = decision_index.Cursor(Decision);

    gpa: std.mem.Allocator,
    doc: *const ast.Document,
    rules: []const Rule,
    exact_blocks: std.EnumSet(ast.BlockTag),
    exact_inlines: std.EnumSet(ast.InlineTag),
    refused_blocks: std.EnumSet(ast.BlockTag),
    refused_inlines: std.EnumSet(ast.InlineTag),
    block_decisions: std.ArrayList(Decision) = .empty,
    inline_decisions: std.ArrayList(Decision) = .empty,
    counts: []u32,
    observed: []u32,
    order: []u16,
    order_len: u32 = 0,
    total_cost: LossCost = zero_cost,
    work: u64 = 0,
    block_frames: []BlockFrame,
    inline_frames: []InlineFrame,
    block_ancestors: []u32,
    inline_ancestors: []u32,
    /// Reused proposal scratch for `choose`, allocated once. `choose` runs
    /// once per non-exact node; a fresh `[max_alternatives_hard]Alternative =
    /// undefined` per call is a ReleaseSafe fill that scales with node count
    /// (see the matching hoist in `ast.validate`). One arena buffer, refilled
    /// by `propose` on each call and read only up to `alternatives.len`,
    /// removes it. `choose` is not re-entrant, so sharing is sound.
    alternative_storage: *[max_alternatives_hard]Alternative,

    pub fn build(
        arena: std.mem.Allocator,
        caps: *const Capabilities,
        doc: *const ast.Document,
        limits: limits_mod.Limits,
    ) PlanError!Plan {
        if (limits.max_lowering_alternatives > max_alternatives_hard) {
            return error.AlternativeLimitExceeded;
        }
        var plan = try init(arena, caps, doc, limits.max_depth);
        var ranges = try reachability.discover(arena, doc);
        const range_costs = try arena.alloc(LossCost, ranges.order.len);
        @memset(range_costs, zero_cost);
        try plan.planReachable(caps, ranges.items(), range_costs, limits);
        std.mem.sort(Decision, plan.block_decisions.items, {}, decisionLessThan);
        std.mem.sort(Decision, plan.inline_decisions.items, {}, decisionLessThan);
        try plan.collectSelected(&ranges, range_costs);
        return plan;
    }

    fn init(
        arena: std.mem.Allocator,
        caps: *const Capabilities,
        doc: *const ast.Document,
        max_depth: u32,
    ) !Plan {
        assert(caps.rules.len <= std.math.maxInt(u16));
        assert(max_depth > 0 and max_depth <= limits_mod.max_depth_hard_cap);
        const counts = try arena.alloc(u32, caps.rules.len);
        const observed = if (std.debug.runtime_safety)
            try arena.alloc(u32, caps.rules.len)
        else
            &.{};
        @memset(counts, 0);
        if (std.debug.runtime_safety) @memset(observed, 0);
        return .{
            .gpa = arena,
            .doc = doc,
            .rules = caps.rules,
            .exact_blocks = .initMany(caps.exact_blocks),
            .exact_inlines = .initMany(caps.exact_inlines),
            .refused_blocks = .initMany(caps.refused_blocks),
            .refused_inlines = .initMany(caps.refused_inlines),
            .counts = counts,
            .observed = observed,
            .order = try arena.alloc(u16, caps.rules.len),
            .block_frames = try arena.alloc(BlockFrame, max_depth),
            .inline_frames = try arena.alloc(InlineFrame, max_depth),
            .block_ancestors = try arena.alloc(u32, max_depth),
            .inline_ancestors = try arena.alloc(u32, max_depth),
            .alternative_storage = try arena.create([max_alternatives_hard]Alternative),
        };
    }

    fn planReachable(
        plan: *Plan,
        caps: *const Capabilities,
        ranges: []const u32,
        range_costs: []LossCost,
        limits: limits_mod.Limits,
    ) PlanError!void {
        var cursor = ranges.len;
        while (cursor > 0) {
            cursor -= 1;
            const index = ranges[cursor];
            const range = plan.doc.store.block_ranges.items[index];
            range_costs[index] = try plan.planBlockRange(caps, range, limits);
        }
        plan.total_cost = try plan.planBlockRange(caps, plan.doc.body, limits);
    }

    fn planBlockRange(
        plan: *Plan,
        caps: *const Capabilities,
        range: ast.BlockRange,
        limits: limits_mod.Limits,
    ) PlanError!LossCost {
        const store = plan.doc.store;
        const stack = plan.block_frames;
        const ancestors = plan.block_ancestors;
        var depth: u32 = 0;
        var total = zero_cost;
        var cursor = range.startRaw();
        while (cursor < range.endRaw()) {
            try plan.closeBlockFrames(
                caps,
                stack,
                ancestors,
                &depth,
                &total,
                cursor,
                limits,
            );
            const tag = store.blocks.items(.tag)[cursor];
            const subtree_len = store.blocks.items(.subtree_len)[cursor];
            if (schema.blockContent(tag) == .blocks and subtree_len > 1) {
                if (depth >= stack.len) return error.DepthLimitExceeded;
                stack[depth] = .{ .node = cursor, .end = cursor + subtree_len };
                ancestors[depth] = cursor;
                depth += 1;
                cursor += 1;
                continue;
            }
            var children = zero_cost;
            const inline_range = store.blocks.items(.inlines)[cursor];
            if (!inline_range.isEmpty()) {
                children = try plan.planInlineRange(
                    caps,
                    ancestors[0..depth],
                    cursor,
                    inline_range,
                    limits,
                );
            }
            const selected = try plan.chooseBlock(
                caps,
                ancestors[0..depth],
                cursor,
                children,
                limits,
            );
            try addSelectedCost(stack, depth, &total, selected);
            cursor += 1;
        }
        try plan.closeBlockFrames(
            caps,
            stack,
            ancestors,
            &depth,
            &total,
            range.endRaw(),
            limits,
        );
        assert(depth == 0);
        return total;
    }

    fn planInlineRange(
        plan: *Plan,
        caps: *const Capabilities,
        block_ancestors: []const u32,
        owner: u32,
        range: ast.InlineRange,
        limits: limits_mod.Limits,
    ) PlanError!LossCost {
        const store = plan.doc.store;
        const stack = plan.inline_frames;
        const ancestors = plan.inline_ancestors;
        var depth: u32 = 0;
        var total = zero_cost;
        var cursor = range.startRaw();
        while (cursor < range.endRaw()) {
            try plan.closeInlineFrames(
                caps,
                block_ancestors,
                owner,
                stack,
                ancestors,
                &depth,
                &total,
                cursor,
                limits,
            );
            const subtree_len = store.inlines.items(.subtree_len)[cursor];
            if (schema.inlineHasChildren(store.inlines.items(.tag)[cursor]) and subtree_len > 1) {
                if (depth >= stack.len) return error.DepthLimitExceeded;
                stack[depth] = .{ .node = cursor, .end = cursor + subtree_len };
                ancestors[depth] = cursor;
                depth += 1;
                cursor += 1;
                continue;
            }
            const selected = try plan.chooseInline(
                caps,
                block_ancestors,
                ancestors[0..depth],
                owner,
                cursor,
                zero_cost,
                limits,
            );
            try addInlineSelectedCost(stack, depth, &total, selected);
            cursor += 1;
        }
        try plan.closeInlineFrames(
            caps,
            block_ancestors,
            owner,
            stack,
            ancestors,
            &depth,
            &total,
            range.endRaw(),
            limits,
        );
        assert(depth == 0);
        return total;
    }

    fn choose(
        plan: *Plan,
        caps: *const Capabilities,
        context: *const ProposalContext,
        node: Node,
        children_cost: LossCost,
        limits: limits_mod.Limits,
    ) PlanError!LossCost {
        var alternatives: Alternatives = .{
            .items = plan.alternative_storage,
            .limit = limits.max_lowering_alternatives,
        };
        assert(!plan.isExact(node));
        if (plan.isRefused(node)) return error.InvalidPlan;
        const propose = caps.propose orelse return error.InvalidPlan;
        try propose(context, node, &alternatives);
        if (alternatives.len == 0) return error.InvalidPlan;
        try plan.validateAlternatives(alternatives.slice());
        plan.work = std.math.add(u64, plan.work, alternatives.len) catch return error.CostOverflow;
        if (plan.work > limits.max_lowering_work) return error.WorkLimitExceeded;
        const selected = try plan.select(alternatives.slice(), children_cost);
        try plan.record(node, selected.alternative);
        return selected.cost;
    }

    fn chooseBlock(
        plan: *Plan,
        caps: *const Capabilities,
        ancestors: []const u32,
        node: u32,
        children: LossCost,
        limits: limits_mod.Limits,
    ) PlanError!LossCost {
        const tag = plan.doc.store.blocks.items(.tag)[node];
        if (plan.exact_blocks.contains(tag)) return children;
        const context = proposalContext(plan.doc, caps, ancestors, &.{}, no_node);
        return plan.choose(
            caps,
            &context,
            .{ .block = @enumFromInt(node) },
            children,
            limits,
        );
    }

    fn chooseInline(
        plan: *Plan,
        caps: *const Capabilities,
        block_ancestors: []const u32,
        inline_ancestors: []const u32,
        owner: u32,
        node: u32,
        children: LossCost,
        limits: limits_mod.Limits,
    ) PlanError!LossCost {
        const tag = plan.doc.store.inlines.items(.tag)[node];
        if (plan.exact_inlines.contains(tag)) return children;
        const context = proposalContext(
            plan.doc,
            caps,
            block_ancestors,
            inline_ancestors,
            owner,
        );
        return plan.choose(
            caps,
            &context,
            .{ .@"inline" = @enumFromInt(node) },
            children,
            limits,
        );
    }

    fn closeBlockFrames(
        plan: *Plan,
        caps: *const Capabilities,
        stack: []BlockFrame,
        ancestors: []u32,
        depth: *u32,
        total: *LossCost,
        cursor: u32,
        limits: limits_mod.Limits,
    ) PlanError!void {
        while (depth.* > 0 and stack[depth.* - 1].end == cursor) {
            depth.* -= 1;
            const frame = stack[depth.*];
            const selected = try plan.chooseBlock(
                caps,
                ancestors[0..depth.*],
                frame.node,
                frame.children,
                limits,
            );
            try addSelectedCost(stack, depth.*, total, selected);
        }
        assert(depth.* == 0 or stack[depth.* - 1].end > cursor);
    }

    fn closeInlineFrames(
        plan: *Plan,
        caps: *const Capabilities,
        block_ancestors: []const u32,
        owner: u32,
        stack: []InlineFrame,
        ancestors: []u32,
        depth: *u32,
        total: *LossCost,
        cursor: u32,
        limits: limits_mod.Limits,
    ) PlanError!void {
        while (depth.* > 0 and stack[depth.* - 1].end == cursor) {
            depth.* -= 1;
            const frame = stack[depth.*];
            const selected = try plan.chooseInline(
                caps,
                block_ancestors,
                ancestors[0..depth.*],
                owner,
                frame.node,
                frame.children,
                limits,
            );
            try addInlineSelectedCost(stack, depth.*, total, selected);
        }
        assert(depth.* == 0 or stack[depth.* - 1].end > cursor);
    }

    fn addSelectedCost(
        stack: []BlockFrame,
        depth: u32,
        total: *LossCost,
        selected: LossCost,
    ) CostError!void {
        if (depth == 0) {
            total.* = try addCost(total.*, selected);
        } else {
            stack[depth - 1].children = try addCost(stack[depth - 1].children, selected);
        }
    }

    fn addInlineSelectedCost(
        stack: []InlineFrame,
        depth: u32,
        total: *LossCost,
        selected: LossCost,
    ) CostError!void {
        if (depth == 0) {
            total.* = try addCost(total.*, selected);
        } else {
            stack[depth - 1].children = try addCost(stack[depth - 1].children, selected);
        }
    }

    const Selected = struct { alternative: Alternative, cost: LossCost };

    fn validateAlternatives(
        plan: *const Plan,
        alternatives: []const Alternative,
    ) error{InvalidPlan}!void {
        assert(alternatives.len > 0);
        assert(alternatives.len <= max_alternatives_hard);
        for (alternatives, 0..) |alternative, index| {
            if (alternative.loss_count > max_losses_per_alternative) {
                return error.InvalidPlan;
            }
            if (alternative.instruction.operation == .emit_exact and
                alternative.loss_count != 0)
            {
                return error.InvalidPlan;
            }
            for (alternative.losses[0..alternative.loss_count]) |rule| {
                if (rule >= plan.rules.len) return error.InvalidPlan;
            }
            for (alternatives[index + 1 ..]) |later| {
                if (alternative.instruction.stable_id == later.instruction.stable_id) {
                    return error.InvalidPlan;
                }
            }
        }
    }

    fn select(
        plan: *const Plan,
        alternatives: []const Alternative,
        children: LossCost,
    ) PlanError!Selected {
        var best: ?Selected = null;
        for (alternatives) |alternative| {
            var total = try plan.alternativeCost(alternative);
            if (alternative.instruction.delegates_children) total = try addCost(total, children);
            const candidate: Selected = .{ .alternative = alternative, .cost = total };
            if (best == null or selectedLessThan(candidate, best.?)) best = candidate;
        }
        return best.?;
    }

    fn alternativeCost(plan: *const Plan, alternative: Alternative) PlanError!LossCost {
        var total = zero_cost;
        for (alternative.losses[0..alternative.loss_count]) |rule| {
            if (rule >= plan.rules.len) return error.InvalidPlan;
            total = try addCost(total, plan.rules[rule].cost);
        }
        total[5] = std.math.add(u64, total[5], alternative.writer_cost) catch
            return error.CostOverflow;
        return total;
    }

    fn record(
        plan: *Plan,
        node: Node,
        alternative: Alternative,
    ) error{OutOfMemory}!void {
        const decision: Decision = .{
            .node = node.raw(),
            .instruction = alternative.instruction,
            .losses = alternative.losses,
            .loss_count = alternative.loss_count,
        };
        switch (node) {
            .block => try plan.block_decisions.append(plan.gpa, decision),
            .@"inline" => try plan.inline_decisions.append(plan.gpa, decision),
        }
    }

    fn recordRule(plan: *Plan, rule: u16) void {
        assert(rule < plan.rules.len);
        assert(plan.counts[rule] < std.math.maxInt(u32));
        if (plan.counts[rule] == 0) {
            plan.order[plan.order_len] = rule;
            plan.order_len += 1;
        }
        plan.counts[rule] += 1;
    }

    fn collectSelected(
        plan: *Plan,
        ranges: *reachability.Ranges,
        range_costs: []const LossCost,
    ) CostError!void {
        assert(plan.order_len == 0);
        assert(plan.block_decisions.items.len <= plan.doc.store.blocks.len);
        ranges.reset();
        plan.collectBlockRange(plan.doc.body, ranges);
        var cursor: u32 = 0;
        while (cursor < ranges.len) : (cursor += 1) {
            const index = ranges.order[cursor];
            plan.total_cost = try addCost(plan.total_cost, range_costs[index]);
            plan.collectBlockRange(plan.doc.store.block_ranges.items[index], ranges);
        }
    }

    fn collectBlockRange(
        plan: *Plan,
        range: ast.BlockRange,
        ranges: *reachability.Ranges,
    ) void {
        const store = plan.doc.store;
        var blocks: DecisionCursor = .{ .decisions = plan.block_decisions.items };
        var inlines: DecisionCursor = .{ .decisions = plan.inline_decisions.items };
        var cursor = range.startRaw();
        while (cursor < range.endRaw()) {
            const decision = blocks.at(cursor);
            if (decision) |selected| plan.collectLosses(selected);
            if (decision != null and !decision.?.instruction.delegates_children) {
                cursor += store.blocks.items(.subtree_len)[cursor];
                continue;
            }
            const inline_range = store.blocks.items(.inlines)[cursor];
            if (!inline_range.isEmpty()) {
                plan.collectInlineRange(inline_range, ranges, &inlines);
            }
            cursor += 1;
        }
        assert(cursor == range.endRaw());
    }

    fn collectInlineRange(
        plan: *Plan,
        range: ast.InlineRange,
        ranges: *reachability.Ranges,
        decisions: *DecisionCursor,
    ) void {
        const store = plan.doc.store;
        const lengths = store.inlines.items(.subtree_len);
        var cursor = range.startRaw();
        while (cursor < range.endRaw()) {
            const decision = decisions.at(cursor);
            if (decision) |selected| plan.collectLosses(selected);
            if (decision != null and !decision.?.instruction.delegates_children) {
                cursor += lengths[cursor];
            } else {
                if (store.inlines.items(.tag)[cursor] == .note) {
                    ranges.add(store.inlines.items(.payload)[cursor]);
                }
                cursor += 1;
            }
        }
        assert(cursor == range.endRaw());
    }

    fn collectLosses(plan: *Plan, decision: *const Decision) void {
        assert(decision.loss_count <= max_losses_per_alternative);
        assert(decision.node < std.math.maxInt(u32));
        for (decision.losses[0..decision.loss_count]) |rule| plan.recordRule(rule);
    }

    fn isExact(plan: *const Plan, node: Node) bool {
        return switch (node) {
            .block => |index| plan.exact_blocks.contains(plan.doc.blockTag(index)),
            .@"inline" => |index| plan.exact_inlines.contains(plan.doc.inlineTag(index)),
        };
    }

    fn isRefused(plan: *const Plan, node: Node) bool {
        return switch (node) {
            .block => |index| plan.refused_blocks.contains(plan.doc.blockTag(index)),
            .@"inline" => |index| plan.refused_inlines.contains(plan.doc.inlineTag(index)),
        };
    }

    pub fn cost(plan: *const Plan) LossCost {
        return plan.total_cost;
    }

    pub fn instruction(plan: *const Plan, node: Node) ?Instruction {
        return switch (node) {
            .block => |index| if (decision_index.find(
                Decision,
                plan.block_decisions.items,
                index.raw(),
            )) |decision|
                decision.instruction
            else
                null,
            .@"inline" => |index| if (decision_index.find(
                Decision,
                plan.inline_decisions.items,
                index.raw(),
            )) |decision|
                decision.instruction
            else
                null,
        };
    }

    /// Emission sites confirm the rule they enacted. Costs and reports were
    /// already fixed by planning; this is a debug-time contract check only.
    pub fn hit(plan: *Plan, rule: u16) void {
        if (!std.debug.runtime_safety) return;
        assert(rule < plan.rules.len);
        plan.observed[rule] += 1;
        assert(plan.observed[rule] <= plan.counts[rule]);
    }

    pub fn assertEmissionComplete(plan: *const Plan) void {
        if (!std.debug.runtime_safety) return;
        for (plan.counts, plan.observed) |expected, actual| assert(expected == actual);
    }

    pub fn flush(plan: *const Plan, reports: *report_mod.Reports) error{OutOfMemory}!void {
        for (plan.order[0..plan.order_len]) |rule| {
            var note = plan.rules[rule].note();
            note.count = plan.counts[rule];
            try reports.add(note);
        }
    }
};

fn decisionLessThan(_: void, a: Plan.Decision, b: Plan.Decision) bool {
    return a.node < b.node;
}

fn selectedLessThan(a: Plan.Selected, b: Plan.Selected) bool {
    if (costLessThan(a.cost, b.cost)) return true;
    if (costLessThan(b.cost, a.cost)) return false;
    if (a.alternative.instruction.stable_id != b.alternative.instruction.stable_id) {
        return a.alternative.instruction.stable_id < b.alternative.instruction.stable_id;
    }
    return @intFromEnum(a.alternative.instruction.operation) <
        @intFromEnum(b.alternative.instruction.operation);
}

fn proposalContext(
    doc: *const ast.Document,
    caps: *const Capabilities,
    block_ancestors: []const u32,
    inline_ancestors: []const u32,
    inline_owner: u32,
) ProposalContext {
    assert(block_ancestors.len <= limits_mod.max_depth_hard_cap);
    assert(inline_ancestors.len <= limits_mod.max_depth_hard_cap);
    return .{
        .doc = doc,
        .extensions = caps.extensions,
        .block_ancestors = block_ancestors,
        .inline_ancestors = inline_ancestors,
        .inline_owner = inline_owner,
    };
}

fn contains(comptime Tag: type, list: []const Tag, tag: Tag) bool {
    for (list) |candidate| if (candidate == tag) return true;
    return false;
}

/// Finds a construct that the writer refuses under every strictness grade.
pub fn findRefused(
    arena: std.mem.Allocator,
    caps: *const Capabilities,
    doc: *const ast.Document,
) error{OutOfMemory}!?[]const u8 {
    if (caps.refused_blocks.len == 0 and caps.refused_inlines.len == 0) {
        return null;
    }
    const ranges = try reachability.discover(arena, doc);
    if (findRefusedInRange(caps, doc, doc.body)) |name| return name;
    for (ranges.items()) |index| {
        const range = doc.store.block_ranges.items[index];
        if (findRefusedInRange(caps, doc, range)) |name| return name;
    }
    return null;
}

fn findRefusedInRange(
    caps: *const Capabilities,
    doc: *const ast.Document,
    range: ast.BlockRange,
) ?[]const u8 {
    const store = doc.store;
    var block = range.startRaw();
    while (block < range.endRaw()) : (block += 1) {
        const block_tag = store.blocks.items(.tag)[block];
        if (contains(ast.BlockTag, caps.refused_blocks, block_tag)) return @tagName(block_tag);
        const inlines = store.blocks.items(.inlines)[block];
        for (store.inlines.items(.tag)[inlines.startRaw()..inlines.endRaw()]) |inline_tag| {
            if (contains(ast.InlineTag, caps.refused_inlines, inline_tag)) {
                return @tagName(inline_tag);
            }
        }
    }
    return null;
}

pub fn reportedCost(reports: *const report_mod.Reports) CostError!LossCost {
    var total = zero_cost;
    for (reports.entries.items) |entry| {
        const loss = entry.report.loss orelse continue;
        const component: usize = switch (loss) {
            .dropped => 0,
            .structural => 1,
            .presentation => 2,
        };
        total[component] = std.math.add(u64, total[component], entry.report.count) catch
            return error.CostOverflow;
    }
    return total;
}
