//! The Markdown reader: CommonMark block structure plus the GFM tables,
//! strikethrough, and footnotes used by the writer (ZDS 0002).
//!
//! The reference two-phase strategy: a line-driven block pass builds an
//! intermediate tree and collects link-reference and footnote definitions;
//! an emission walk then runs the inline parser over each leaf and streams
//! the result through the `Emitter`. Both passes keep explicit stacks and
//! never recurse.

const std = @import("std");
const assert = std.debug.assert;
const core = @import("zenfmt_core");
const inlines = @import("inlines.zig");

pub const reader = core.Reader(.{
    .id = "ai.insan.zenfmt.markdown",
    .format = "markdown",
    .extensions = &.{ "md", "markdown" },
    .read = read,
});

const null_index = std.math.maxInt(u32);

const Kind = enum(u8) {
    document,
    quote,
    list,
    item,
    footnote_def,
    paragraph,
    heading,
    fenced_code,
    indented_code,
    html_block,
    thematic_break,
    table,
    table_row,
};

const Block = struct {
    kind: Kind,
    parent: u32 = null_index,
    first_child: u32 = null_index,
    last_child: u32 = null_index,
    next: u32 = null_index,
    open: bool = true,
    /// Stripped after link-reference extraction consumed everything.
    deleted: bool = false,
    content: std.ArrayList(u8) = .empty,
    heading_level: u8 = 0,
    fence_char: u8 = 0,
    fence_len: u32 = 0,
    fence_indent: u32 = 0,
    info: []const u8 = "",
    ordered: bool = false,
    marker_char: u8 = 0,
    start: i64 = 1,
    delimiter: core.payload.NumberDelimiter = .period,
    tight: bool = true,
    /// Content column of an item or footnote definition.
    content_indent: u32 = 0,
    label: []const u8 = "",
    alignments: []core.payload.Alignment = &.{},
    /// Blank-line bookkeeping for list tightness.
    last_line_blank: bool = false,
    blank_inside: bool = false,
    /// Note index for footnote definitions.
    note: u32 = 0,
};

fn read(ctx: *core.ReadContext) core.ReadError!void {
    const bytes = ctx.input.bytes;
    if (!std.unicode.utf8ValidateSlice(bytes)) {
        try ctx.reports.add(invalidUtf8Report());
        return error.Malformed;
    }

    var parser: BlockParser = .{ .gpa = ctx.gpa, .limits = ctx.limits };
    try parser.blocks.append(ctx.gpa, .{ .kind = .document });

    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trimEnd(u8, raw_line, "\r");
        try parser.addLine(line);
    }
    try parser.closeFrom(0);

    var emitter_pass: EmitPass = .{ .ctx = ctx, .p = &parser };
    try emitter_pass.declareFootnotes();
    try emitter_pass.emitChildren(0, false);
    try emitter_pass.emitFootnotes();
}

// -------------------------------------------------------- block parsing

const BlockParser = struct {
    gpa: std.mem.Allocator,
    limits: core.Limits,
    blocks: std.ArrayList(Block) = .empty,
    refs: inlines.Refs = .empty,
    footnotes: inlines.Footnotes = .empty,
    /// Footnote definition nodes in order of appearance.
    footnote_order: std.ArrayList(u32) = .empty,

    fn node(p: *BlockParser, index: u32) *Block {
        return &p.blocks.items[index];
    }

    /// The chain of open blocks from the document to the deepest leaf.
    fn openChain(p: *BlockParser, out: *[core.limits.max_depth_hard_cap]u32) u32 {
        var depth: u32 = 0;
        var index: u32 = 0;
        while (true) {
            out[depth] = index;
            depth += 1;
            const last = p.node(index).last_child;
            if (last == null_index or !p.node(last).open) break;
            index = last;
        }
        return depth;
    }

    fn appendChild(p: *BlockParser, parent: u32, block: Block) error{OutOfMemory}!u32 {
        const index: u32 = @intCast(p.blocks.items.len);
        var value = block;
        value.parent = parent;
        try p.blocks.append(p.gpa, value);
        const parent_node = p.node(parent);
        if (parent_node.last_child != null_index) {
            p.node(parent_node.last_child).next = index;
        } else {
            parent_node.first_child = index;
        }
        parent_node.last_child = index;
        return index;
    }

    /// Closes open blocks until the spine is `keep` levels deep; the
    /// document is level one.
    fn closeDeeperThan(p: *BlockParser, keep: u32) error{OutOfMemory}!void {
        var deepest: u32 = 0;
        var walk: u32 = 0;
        var depth: u32 = 0;
        while (true) {
            deepest = walk;
            depth += 1;
            const last = p.node(walk).last_child;
            if (last == null_index or !p.node(last).open) break;
            walk = last;
        }
        while (depth > keep) : (depth -= 1) {
            const parent = p.node(deepest).parent;
            try p.closeBlock(deepest);
            deepest = parent;
        }
    }

    fn closeFrom(p: *BlockParser, root: u32) error{OutOfMemory}!void {
        // Close the whole open spine down from `root`.
        var chain: [core.limits.max_depth_hard_cap]u32 = undefined;
        const depth = p.openChain(&chain);
        var i = depth;
        while (i > 0) {
            i -= 1;
            if (chain[i] == root) break;
            try p.closeBlock(chain[i]);
        }
        if (root == 0) p.node(0).open = false;
    }

    fn closeBlock(p: *BlockParser, index: u32) error{OutOfMemory}!void {
        const block = p.node(index);
        assert(block.open);
        block.open = false;
        switch (block.kind) {
            .paragraph => try p.finalizeParagraph(index),
            .list => p.finalizeList(index),
            .footnote_def => {},
            else => {},
        }
    }

    fn finalizeList(p: *BlockParser, index: u32) void {
        const list = p.node(index);
        var loose = false;
        var item = list.first_child;
        while (item != null_index) {
            const item_node = p.node(item);
            if (item_node.blank_inside) loose = true;
            if (item_node.last_line_blank and item_node.next != null_index) loose = true;
            item = item_node.next;
        }
        list.tight = !loose;
    }

    /// Extracts leading link-reference definitions, then drops the
    /// paragraph entirely when nothing else remains.
    fn finalizeParagraph(p: *BlockParser, index: u32) error{OutOfMemory}!void {
        const block = p.node(index);
        var text = std.mem.trimEnd(u8, block.content.items, " \t\n");
        while (parseRefDef(text)) |parsed| {
            var key_buffer: [1024]u8 = undefined;
            const key = inlines.normalizeLabel(parsed.label, &key_buffer) orelse break;
            const entry = try p.refs.getOrPut(p.gpa, try p.gpa.dupe(u8, key));
            if (!entry.found_existing) {
                entry.value_ptr.* = .{
                    .url = try p.gpa.dupe(u8, parsed.url),
                    .title = try p.gpa.dupe(u8, parsed.title),
                };
            }
            text = std.mem.trimStart(u8, text[parsed.consumed..], " \t\n");
        }
        if (text.len == 0) {
            block.deleted = true;
        } else if (text.ptr != block.content.items.ptr or text.len != block.content.items.len) {
            std.mem.copyForwards(u8, block.content.items[0..text.len], text);
            block.content.shrinkRetainingCapacity(text.len);
        }
    }

    // ---------------------------------------------------------- one line

    fn addLine(p: *BlockParser, line: []const u8) core.ReadError!void {
        var chain: [core.limits.max_depth_hard_cap]u32 = undefined;
        const chain_depth = p.openChain(&chain);

        // Phase A: how many open containers does this line continue?
        var rest = line;
        var matched: u32 = 1;
        var container_depth: u32 = 1;
        for (chain[1..chain_depth]) |index| {
            const block = p.node(index);
            switch (block.kind) {
                .quote => {
                    const after = matchQuoteMarker(rest) orelse break;
                    rest = after;
                    matched = container_depth + 1;
                },
                .list => matched = container_depth + 1,
                .item, .footnote_def => {
                    if (isBlank(rest)) {
                        matched = container_depth + 1;
                    } else {
                        const width = indentWidth(rest);
                        if (width >= block.content_indent) {
                            rest = consumeIndent(rest, block.content_indent);
                            matched = container_depth + 1;
                        } else break;
                    }
                },
                else => break,
            }
            container_depth += 1;
        }
        const deepest_open = chain[chain_depth - 1];
        const containers_matched = matched >= chain_depth - 1;

        // Phase B: leaves that swallow lines whole.
        if (p.node(deepest_open).open) switch (p.node(deepest_open).kind) {
            .fenced_code => if (containers_matched) {
                try p.continueFencedCode(deepest_open, rest);
                return;
            },
            .html_block => if (containers_matched) {
                if (isBlank(rest)) {
                    try p.closeDeeperThan(matched);
                } else {
                    const block = p.node(deepest_open);
                    try block.content.appendSlice(p.gpa, rest);
                    try block.content.append(p.gpa, '\n');
                }
                return;
            },
            .indented_code => if (containers_matched) {
                const width = indentWidth(rest);
                if (isBlank(rest)) {
                    const block = p.node(deepest_open);
                    try block.content.append(p.gpa, '\n');
                    p.markBlank(chain[0..chain_depth]);
                    return;
                }
                if (width >= 4) {
                    const block = p.node(deepest_open);
                    try block.content.appendSlice(p.gpa, consumeIndent(rest, 4));
                    try block.content.append(p.gpa, '\n');
                    return;
                }
            },
            .table => if (containers_matched and !isBlank(rest) and
                std.mem.indexOfScalar(u8, rest, '|') != null)
            {
                const row = try p.appendChild(deepest_open, .{ .kind = .table_row, .open = false });
                try p.node(row).content.appendSlice(p.gpa, std.mem.trim(u8, rest, " \t"));
                return;
            },
            else => {},
        };

        // Blank lines close paragraphs and mark containers for tightness.
        if (isBlank(rest)) {
            const open_leaf = p.openLeaf();
            if (open_leaf) |leaf| {
                if (p.node(leaf).kind == .paragraph or p.node(leaf).kind == .table or
                    p.node(leaf).kind == .indented_code or p.node(leaf).kind == .html_block)
                {
                    try p.closeDeeperThan(depthOf(p, leaf) - 1);
                }
            }
            p.markBlank(chain[0..chain_depth]);
            return;
        }

        // Phase C: new container and leaf starts on the remainder.
        var parent = chain[matched - 1];
        var guard: u32 = 0;
        while (true) {
            guard += 1;
            assert(guard <= core.limits.max_depth_hard_cap);
            const width = indentWidth(rest);

            // Indented code, only when no paragraph can continue.
            if (width >= 4) {
                if (p.paragraphOpenUnder(parent)) {
                    // Lazy continuation of the paragraph.
                    break;
                }
                try p.closeDeeperThan(depthOf(p, parent));
                parent = try p.nonItemParent(parent);
                const code = try p.appendChild(parent, .{ .kind = .indented_code });
                try p.node(code).content.appendSlice(p.gpa, consumeIndent(rest, 4));
                try p.node(code).content.append(p.gpa, '\n');
                return;
            }

            const trimmed = std.mem.trimStart(u8, rest, " ");
            if (matchQuoteMarker(rest)) |after| {
                try p.closeDeeperThan(depthOf(p, parent));
                parent = try p.nonItemParent(parent);
                parent = try p.appendChild(parent, .{ .kind = .quote });
                rest = after;
                continue;
            }
            if (matchFootnoteDef(trimmed)) |def| {
                try p.closeDeeperThan(depthOf(p, parent));
                parent = try p.nonItemParent(parent);
                const footnote = try p.appendChild(parent, .{
                    .kind = .footnote_def,
                    .label = try p.gpa.dupe(u8, def.label),
                    .content_indent = 4,
                });
                var key_buffer: [1024]u8 = undefined;
                if (inlines.normalizeLabel(def.label, &key_buffer)) |key| {
                    if (!p.footnotes.contains(key)) {
                        try p.footnotes.put(p.gpa, try p.gpa.dupe(u8, key), 0);
                        try p.footnote_order.append(p.gpa, footnote);
                    }
                }
                parent = footnote;
                rest = def.rest;
                continue;
            }
            if (matchListMarker(trimmed)) |marker| {
                // An ordered marker other than 1 cannot interrupt a
                // paragraph, and neither can an empty item — but a new item
                // of an already-open matching list is a continuation, not
                // an interruption.
                const continues_list = p.node(parent).kind == .list and
                    p.node(parent).open and p.node(parent).marker_char == marker.char;
                const interrupting = p.paragraphOpenUnder(parent) and !continues_list;
                if (interrupting and (marker.ordered and marker.start != 1)) break;
                if (interrupting and isBlank(marker.rest)) break;

                try p.closeDeeperThan(depthOf(p, parent));
                const list_matches = p.node(parent).kind == .list and
                    p.node(parent).marker_char == marker.char;
                if (p.node(parent).kind == .list and !list_matches) {
                    try p.closeBlock(parent);
                    parent = p.node(parent).parent;
                }
                if (p.node(parent).kind != .list or !p.node(parent).open) {
                    parent = try p.appendChild(parent, .{
                        .kind = .list,
                        .ordered = marker.ordered,
                        .marker_char = marker.char,
                        .start = marker.start,
                        .delimiter = marker.delimiter,
                    });
                }
                parent = try p.appendChild(parent, .{
                    .kind = .item,
                    .content_indent = width + marker.width,
                    .marker_char = marker.char,
                });
                rest = marker.rest;
                continue;
            }

            // Leaves.
            if (matchAtxHeading(trimmed)) |heading| {
                try p.closeDeeperThan(depthOf(p, parent));
                parent = try p.nonItemParent(parent);
                const index = try p.appendChild(parent, .{
                    .kind = .heading,
                    .heading_level = heading.level,
                    .open = false,
                });
                try p.node(index).content.appendSlice(p.gpa, heading.text);
                return;
            }
            if (matchFence(trimmed)) |fence| {
                try p.closeDeeperThan(depthOf(p, parent));
                parent = try p.nonItemParent(parent);
                _ = try p.appendChild(parent, .{
                    .kind = .fenced_code,
                    .fence_char = fence.char,
                    .fence_len = fence.len,
                    .fence_indent = width,
                    .info = try p.gpa.dupe(u8, fence.info),
                });
                return;
            }
            if (p.paragraphOpenUnder(parent)) {
                if (matchSetext(trimmed)) |level| {
                    const leaf = p.openLeaf().?;
                    const paragraph = p.node(leaf);
                    if (paragraph.kind == .paragraph and paragraph.content.items.len > 0) {
                        paragraph.kind = .heading;
                        paragraph.heading_level = level;
                        paragraph.open = false;
                        return;
                    }
                }
                if (delimiterRowAlignments(p.gpa, trimmed) catch null) |alignments| {
                    const leaf = p.openLeaf().?;
                    const paragraph = p.node(leaf);
                    const one_line = paragraph.kind == .paragraph and
                        std.mem.indexOfScalar(u8, std.mem.trimEnd(u8, paragraph.content.items, "\n"), '\n') == null;
                    if (one_line and pipeCount(paragraph.content.items) > 0) {
                        paragraph.kind = .table;
                        paragraph.alignments = alignments;
                        return;
                    }
                    p.gpa.free(alignments);
                }
            }
            if (matchThematicBreak(trimmed)) {
                try p.closeDeeperThan(depthOf(p, parent));
                parent = try p.nonItemParent(parent);
                _ = try p.appendChild(parent, .{ .kind = .thematic_break, .open = false });
                return;
            }
            if (trimmed.len > 0 and trimmed[0] == '<' and !p.paragraphOpenUnder(parent) and
                looksLikeHtmlBlock(trimmed))
            {
                try p.closeDeeperThan(depthOf(p, parent));
                parent = try p.nonItemParent(parent);
                const index = try p.appendChild(parent, .{ .kind = .html_block });
                try p.node(index).content.appendSlice(p.gpa, rest);
                try p.node(index).content.append(p.gpa, '\n');
                return;
            }
            break;
        }

        // Phase D: paragraph text, possibly lazily continuing.
        const open_leaf = p.openLeaf();
        if (open_leaf) |leaf| {
            if (p.node(leaf).kind == .paragraph) {
                const paragraph = p.node(leaf);
                try paragraph.content.appendSlice(p.gpa, rest);
                try paragraph.content.append(p.gpa, '\n');
                p.clearBlankOnSpine(leaf);
                return;
            }
        }
        try p.closeDeeperThan(depthOf(p, parent));
        parent = try p.nonItemParent(parent);
        const paragraph = try p.appendChild(parent, .{ .kind = .paragraph });
        try p.node(paragraph).content.appendSlice(p.gpa, std.mem.trimStart(u8, rest, " \t"));
        try p.node(paragraph).content.append(p.gpa, '\n');
        p.clearBlankOnSpine(paragraph);
    }

    fn continueFencedCode(p: *BlockParser, index: u32, rest: []const u8) core.ReadError!void {
        const block = p.node(index);
        {
            const trimmed = std.mem.trimStart(u8, rest, " ");
            if (trimmed.len >= block.fence_len and indentWidth(rest) < 4) {
                var run: u32 = 0;
                while (run < trimmed.len and trimmed[run] == block.fence_char) run += 1;
                if (run >= block.fence_len and isBlank(trimmed[run..])) {
                    block.open = false;
                    return;
                }
            }
        }
        // Content lines drop up to the opening fence's indent.
        var content = rest;
        var stripped: u32 = 0;
        while (stripped < block.fence_indent and content.len > 0 and content[0] == ' ') {
            content = content[1..];
            stripped += 1;
        }
        try block.content.appendSlice(p.gpa, content);
        try block.content.append(p.gpa, '\n');
    }

    /// Only `item` may live under `list`: any other new block closes the
    /// list (and any list it in turn sits in) and attaches above it.
    fn nonItemParent(p: *BlockParser, parent: u32) error{OutOfMemory}!u32 {
        var index = parent;
        while (p.node(index).kind == .list) {
            try p.closeBlock(index);
            index = p.node(index).parent;
        }
        return index;
    }

    fn openLeaf(p: *BlockParser) ?u32 {
        var index: u32 = 0;
        while (true) {
            const last = p.node(index).last_child;
            if (last == null_index or !p.node(last).open) break;
            index = last;
        }
        if (index == 0) return null;
        return switch (p.node(index).kind) {
            .paragraph, .fenced_code, .indented_code, .html_block, .table => index,
            else => null,
        };
    }

    fn paragraphOpenUnder(p: *BlockParser, parent: u32) bool {
        _ = parent;
        const leaf = p.openLeaf() orelse return false;
        return p.node(leaf).kind == .paragraph;
    }

    fn depthOf(p: *BlockParser, index: u32) u32 {
        var depth: u32 = 1;
        var walk = index;
        while (walk != 0) {
            walk = p.node(walk).parent;
            depth += 1;
        }
        return depth;
    }

    fn markBlank(p: *BlockParser, chain: []const u32) void {
        for (chain) |index| {
            const block = p.node(index);
            if (block.kind == .item or block.kind == .footnote_def) {
                if (block.first_child != null_index) block.last_line_blank = true;
            }
        }
    }

    fn clearBlankOnSpine(p: *BlockParser, from: u32) void {
        var walk = from;
        while (walk != null_index) {
            const block = p.node(walk);
            if ((block.kind == .item or block.kind == .footnote_def) and block.last_line_blank) {
                block.blank_inside = true;
                block.last_line_blank = false;
            }
            walk = block.parent;
        }
    }
};

// Line classification lives in `lines.zig`.
const lines_mod = @import("lines.zig");
const isBlank = lines_mod.isBlank;
const indentWidth = lines_mod.indentWidth;
const consumeIndent = lines_mod.consumeIndent;
const matchQuoteMarker = lines_mod.matchQuoteMarker;
const ListMarker = lines_mod.ListMarker;
const matchListMarker = lines_mod.matchListMarker;
const matchAtxHeading = lines_mod.matchAtxHeading;
const matchFence = lines_mod.matchFence;
const matchSetext = lines_mod.matchSetext;
const matchThematicBreak = lines_mod.matchThematicBreak;
const matchFootnoteDef = lines_mod.matchFootnoteDef;
const looksLikeHtmlBlock = lines_mod.looksLikeHtmlBlock;
const pipeCount = lines_mod.pipeCount;
const delimiterRowAlignments = lines_mod.delimiterRowAlignments;
const parseRefDef = lines_mod.parseRefDef;

// ------------------------------------------------------------ emission

const EmitPass = struct {
    ctx: *core.ReadContext,
    p: *BlockParser,

    fn declareFootnotes(pass: *EmitPass) core.ReadError!void {
        for (pass.p.footnote_order.items) |index| {
            const def = pass.p.node(index);
            const note = try pass.ctx.out.declareNote();
            def.note = note;
            var key_buffer: [1024]u8 = undefined;
            const key = inlines.normalizeLabel(def.label, &key_buffer).?;
            const entry = pass.p.footnotes.getPtr(key).?;
            entry.* = note;
        }
    }

    fn emitFootnotes(pass: *EmitPass) core.ReadError!void {
        for (pass.p.footnote_order.items) |index| {
            const def = pass.p.node(index);
            pass.ctx.out.beginNoteBody(def.note);
            try pass.emitChildren(index, false);
            pass.ctx.out.endNoteBody(def.note);
        }
    }

    const Frame = struct {
        node: u32,
        child: u32,
        token: ?core.builder.BlockToken,
        tight: bool,
    };

    /// Emits the children of `root`, skipping footnote definitions; the
    /// walk keeps one explicit frame stack.
    fn emitChildren(pass: *EmitPass, root: u32, root_tight: bool) core.ReadError!void {
        var stack: [core.limits.max_depth_hard_cap]Frame = undefined;
        var depth: u32 = 1;
        stack[0] = .{
            .node = root,
            .child = pass.p.node(root).first_child,
            .token = null,
            .tight = root_tight,
        };

        while (depth > 0) {
            const frame = &stack[depth - 1];
            const child = frame.child;
            if (child == null_index) {
                if (frame.token) |token| pass.ctx.out.endBlock(token);
                depth -= 1;
                continue;
            }
            frame.child = pass.p.node(child).next;

            const block = pass.p.node(child);
            if (block.deleted or block.kind == .footnote_def) continue;
            switch (block.kind) {
                .document, .footnote_def => unreachable,
                .paragraph => try pass.emitParagraph(block, frame.tight),
                .heading => {
                    const level = @min(@max(block.heading_level, 1), 6);
                    const token = try pass.ctx.out.beginHeading(level);
                    try pass.parseInlines(paragraphText(block));
                    pass.ctx.out.endBlock(token);
                },
                .thematic_break => try pass.ctx.out.thematicBreak(),
                .fenced_code => try pass.ctx.out.codeBlock(block.info, block.content.items),
                .indented_code => try pass.ctx.out.codeBlock("", block.content.items),
                .html_block => try pass.ctx.out.rawBlock("html", block.content.items),
                .table => try pass.emitTable(child),
                .table_row => unreachable,
                .quote => {
                    assert(depth < core.limits.max_depth_hard_cap);
                    const token = try pass.ctx.out.beginBlock(.quote);
                    stack[depth] = .{
                        .node = child,
                        .child = block.first_child,
                        .token = token,
                        .tight = false,
                    };
                    depth += 1;
                },
                .list => {
                    assert(depth < core.limits.max_depth_hard_cap);
                    const token = try pass.ctx.out.beginList(.{
                        .kind = if (block.ordered) .ordered else .unordered,
                        .start = block.start,
                        .style = .decimal,
                        .delimiter = block.delimiter,
                    });
                    stack[depth] = .{
                        .node = child,
                        .child = block.first_child,
                        .token = token,
                        .tight = block.tight,
                    };
                    depth += 1;
                },
                .item => {
                    assert(depth < core.limits.max_depth_hard_cap);
                    const token = try pass.ctx.out.beginBlock(.list_item);
                    stack[depth] = .{
                        .node = child,
                        .child = block.first_child,
                        .token = token,
                        .tight = frame.tight,
                    };
                    depth += 1;
                },
            }
        }
    }

    fn emitParagraph(pass: *EmitPass, block: *Block, tight: bool) core.ReadError!void {
        const token = if (tight)
            try pass.ctx.out.beginPlain()
        else
            try pass.ctx.out.beginParagraph();
        try pass.parseInlines(paragraphText(block));
        pass.ctx.out.endBlock(token);
    }

    fn parseInlines(pass: *EmitPass, text: []const u8) core.ReadError!void {
        try inlines.parse(pass.ctx.gpa, pass.ctx.out, text, &pass.p.refs, &pass.p.footnotes);
    }

    fn emitTable(pass: *EmitPass, index: u32) core.ReadError!void {
        const table = pass.p.node(index);
        const token = try pass.ctx.out.beginTable(table.alignments);

        // The header line is the table's own content; rows are children.
        {
            const head = try pass.ctx.out.beginBlock(.table_head);
            try pass.emitTableRow(paragraphText(table), table.alignments.len);
            pass.ctx.out.endBlock(head);
        }
        if (table.first_child != null_index) {
            const body = try pass.ctx.out.beginTableBody(.{
                .row_head_columns = 0,
                .head_rows = 0,
            });
            var row = table.first_child;
            while (row != null_index) {
                try pass.emitTableRow(pass.p.node(row).content.items, table.alignments.len);
                row = pass.p.node(row).next;
            }
            pass.ctx.out.endBlock(body);
        }
        pass.ctx.out.endBlock(token);
    }

    fn emitTableRow(pass: *EmitPass, line: []const u8, columns: usize) core.ReadError!void {
        const row = try pass.ctx.out.beginBlock(.table_row);
        defer pass.ctx.out.endBlock(row);

        const trimmed = std.mem.trim(u8, std.mem.trimEnd(u8, line, "\n"), " \t");
        var emitted: usize = 0;
        var cell_start: usize = 0;
        var i: usize = 0;
        const inner = std.mem.trim(u8, trimmed, "|");
        while (i <= inner.len) : (i += 1) {
            const at_end = i == inner.len;
            if (!at_end and inner[i] == '\\') {
                i += 1;
                continue;
            }
            if (at_end or inner[i] == '|') {
                if (emitted < columns) {
                    try pass.emitTableCell(std.mem.trim(u8, inner[cell_start..i], " \t"));
                    emitted += 1;
                }
                cell_start = i + 1;
            }
        }
        while (emitted < columns) : (emitted += 1) {
            try pass.emitTableCell("");
        }
    }

    fn emitTableCell(pass: *EmitPass, content: []const u8) core.ReadError!void {
        const cell = try pass.ctx.out.beginTableCell(.plain);
        defer pass.ctx.out.endBlock(cell);
        const plain = try pass.ctx.out.beginPlain();
        defer pass.ctx.out.endBlock(plain);
        if (content.len > 0) try pass.parseInlines(content);
    }
};

fn paragraphText(block: *Block) []const u8 {
    return std.mem.trimEnd(u8, block.content.items, " \t\n");
}

fn invalidUtf8Report() core.Report {
    return .{
        .severity = .err,
        .code = "markdown.invalid-utf8",
        .title = "THE INPUT IS NOT VALID UTF-8",
        .problem = "This file contains bytes that are not valid UTF-8, so " ++
            "I cannot read it as Markdown.",
        .consequence = "The conversion stopped and no output file was " ++
            "created.",
        .directions = &.{.{
            .title = "Convert the encoding first",
            .explanation = "Convert the file to UTF-8 — for example with " ++
                "`iconv -f windows-1252 -t utf-8` — and run zenfmt on the " ++
                "result.",
        }},
    };
}
