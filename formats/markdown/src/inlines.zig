//! CommonMark inline parsing (ZDS 0002, Staged parsing).
//!
//! The reference strategy: scan the leaf's text into a doubly linked node
//! list with a delimiter chain, resolve brackets as each `]` arrives,
//! resolve emphasis with the spec's delimiter algorithm, then emit the
//! properly nested result through the `Emitter` with one explicit stack.
//! No recursion, and no token object outlives the arena.

const std = @import("std");
const assert = std.debug.assert;
const core = @import("zenfmt_core");

pub const RefDef = struct {
    url: []const u8,
    title: []const u8,
};

/// Keys are normalized labels: trimmed, whitespace-collapsed, case-folded.
pub const Refs = std.StringHashMapUnmanaged(RefDef);

/// Label to declared note index.
pub const Footnotes = std.StringHashMapUnmanaged(u32);

const null_index = std.math.maxInt(u32);

const Kind = enum(u8) {
    literal,
    code,
    raw_html,
    softbreak,
    hardbreak,
    /// Unresolved `*`/`_`/`~` run; leftovers emit as literal text.
    delim,
    /// Unresolved `[` or `![`; failures emit as literal text.
    bracket,
    link_open,
    link_close,
    image_open,
    image_close,
    emph_open,
    emph_close,
    strong_open,
    strong_close,
    strike_open,
    strike_close,
    note_ref,
};

const Node = struct {
    kind: Kind,
    prev: u32 = null_index,
    next: u32 = null_index,
    /// Literal bytes, code content, or link destination.
    text: []const u8 = "",
    title: []const u8 = "",
    /// Remaining delimiter count, or the note index of a `note_ref`.
    extra: u32 = 0,
    delim_char: u8 = 0,
    can_open: bool = false,
    can_close: bool = false,
    /// Brackets deactivate once a link encloses them.
    active: bool = true,
    is_image: bool = false,
    prev_delim: u32 = null_index,
    next_delim: u32 = null_index,
};

const Bracket = struct {
    node: u32,
    /// The delimiter chain position when the bracket opened; emphasis
    /// inside the brackets is processed above this bottom.
    delim_bottom: u32,
};

pub fn parse(
    gpa: std.mem.Allocator,
    out: core.Emitter,
    text: []const u8,
    refs: *const Refs,
    footnotes: *const Footnotes,
) core.ReadError!void {
    var p: Parser = .{
        .gpa = gpa,
        .text = text,
        .refs = refs,
        .footnotes = footnotes,
    };
    defer p.deinit();
    try p.scan();
    try p.processEmphasis(null_index);
    try p.emit(out);
}

const Parser = struct {
    gpa: std.mem.Allocator,
    text: []const u8,
    refs: *const Refs,
    footnotes: *const Footnotes,

    nodes: std.ArrayList(Node) = .empty,
    head: u32 = null_index,
    tail: u32 = null_index,
    delim_top: u32 = null_index,
    brackets: std.ArrayList(Bracket) = .empty,

    fn deinit(p: *Parser) void {
        p.nodes.deinit(p.gpa);
        p.brackets.deinit(p.gpa);
    }

    fn append(p: *Parser, node: Node) error{OutOfMemory}!u32 {
        const index: u32 = @intCast(p.nodes.items.len);
        var value = node;
        value.prev = p.tail;
        value.next = null_index;
        try p.nodes.append(p.gpa, value);
        if (p.tail != null_index) p.nodes.items[p.tail].next = index;
        p.tail = index;
        if (p.head == null_index) p.head = index;
        return index;
    }

    fn appendLiteral(p: *Parser, bytes: []const u8) error{OutOfMemory}!void {
        if (bytes.len == 0) return;
        _ = try p.append(.{ .kind = .literal, .text = bytes });
    }

    fn remove(p: *Parser, index: u32) void {
        const node = &p.nodes.items[index];
        if (node.prev != null_index) p.nodes.items[node.prev].next = node.next;
        if (node.next != null_index) p.nodes.items[node.next].prev = node.prev;
        if (p.head == index) p.head = node.next;
        if (p.tail == index) p.tail = node.prev;
    }

    fn insertAfter(p: *Parser, anchor: u32, node: Node) error{OutOfMemory}!u32 {
        const index: u32 = @intCast(p.nodes.items.len);
        var value = node;
        value.prev = anchor;
        value.next = p.nodes.items[anchor].next;
        try p.nodes.append(p.gpa, value);
        if (value.next != null_index) p.nodes.items[value.next].prev = index;
        p.nodes.items[anchor].next = index;
        if (p.tail == anchor) p.tail = index;
        return index;
    }

    fn insertBefore(p: *Parser, anchor: u32, node: Node) error{OutOfMemory}!u32 {
        const index: u32 = @intCast(p.nodes.items.len);
        var value = node;
        value.next = anchor;
        value.prev = p.nodes.items[anchor].prev;
        try p.nodes.append(p.gpa, value);
        if (value.prev != null_index) p.nodes.items[value.prev].next = index;
        p.nodes.items[anchor].prev = index;
        if (p.head == anchor) p.head = index;
        return index;
    }

    fn pushDelim(p: *Parser, index: u32) void {
        p.nodes.items[index].prev_delim = p.delim_top;
        p.nodes.items[index].next_delim = null_index;
        if (p.delim_top != null_index) p.nodes.items[p.delim_top].next_delim = index;
        p.delim_top = index;
    }

    fn removeDelim(p: *Parser, index: u32) void {
        const node = &p.nodes.items[index];
        if (node.prev_delim != null_index) p.nodes.items[node.prev_delim].next_delim = node.next_delim;
        if (node.next_delim != null_index) p.nodes.items[node.next_delim].prev_delim = node.prev_delim;
        if (p.delim_top == index) p.delim_top = node.prev_delim;
        node.prev_delim = null_index;
        node.next_delim = null_index;
    }

    // -------------------------------------------------------------- scan

    fn scan(p: *Parser) core.ReadError!void {
        const text = p.text;
        var i: usize = 0;
        var literal_start: usize = 0;
        while (i < text.len) {
            const byte = text[i];
            switch (byte) {
                '\\' => {
                    try p.appendLiteral(text[literal_start..i]);
                    if (i + 1 < text.len and text[i + 1] == '\n') {
                        _ = try p.append(.{ .kind = .hardbreak });
                        i += 2;
                    } else if (i + 1 < text.len and isEscapable(text[i + 1])) {
                        try p.appendLiteral(text[i + 1 .. i + 2]);
                        i += 2;
                    } else {
                        try p.appendLiteral(text[i .. i + 1]);
                        i += 1;
                    }
                    literal_start = i;
                },
                '\n' => {
                    // Two trailing spaces make a hard break; the spaces
                    // themselves never reach the tree.
                    var end = i;
                    while (end > literal_start and text[end - 1] == ' ') end -= 1;
                    try p.appendLiteral(text[literal_start..end]);
                    if (i - end >= 2) {
                        _ = try p.append(.{ .kind = .hardbreak });
                    } else {
                        _ = try p.append(.{ .kind = .softbreak });
                    }
                    i += 1;
                    literal_start = i;
                },
                '`' => {
                    try p.appendLiteral(text[literal_start..i]);
                    i = try p.scanCodeSpan(i);
                    literal_start = i;
                },
                '*', '_', '~' => {
                    try p.appendLiteral(text[literal_start..i]);
                    i = try p.scanDelimRun(i);
                    literal_start = i;
                },
                '[' => {
                    try p.appendLiteral(text[literal_start..i]);
                    if (try p.scanFootnoteRef(i)) |next| {
                        i = next;
                    } else {
                        const index = try p.append(.{ .kind = .bracket, .text = text[i .. i + 1] });
                        try p.brackets.append(p.gpa, .{ .node = index, .delim_bottom = p.delim_top });
                        i += 1;
                    }
                    literal_start = i;
                },
                '!' => {
                    if (i + 1 < text.len and text[i + 1] == '[') {
                        try p.appendLiteral(text[literal_start..i]);
                        const index = try p.append(.{
                            .kind = .bracket,
                            .text = text[i .. i + 2],
                            .is_image = true,
                        });
                        try p.brackets.append(p.gpa, .{ .node = index, .delim_bottom = p.delim_top });
                        i += 2;
                        literal_start = i;
                    } else {
                        i += 1;
                    }
                },
                ']' => {
                    try p.appendLiteral(text[literal_start..i]);
                    i = try p.closeBracket(i);
                    literal_start = i;
                },
                '<' => {
                    try p.appendLiteral(text[literal_start..i]);
                    i = try p.scanAngle(i);
                    literal_start = i;
                },
                '&' => {
                    if (try decodeEntity(p.gpa, text[i..])) |decoded| {
                        try p.appendLiteral(text[literal_start..i]);
                        try p.appendLiteral(decoded.bytes);
                        i += decoded.consumed;
                        literal_start = i;
                    } else {
                        i += 1;
                    }
                },
                else => i += 1,
            }
        }
        try p.appendLiteral(text[literal_start..]);
    }

    fn scanCodeSpan(p: *Parser, start: usize) core.ReadError!usize {
        const text = p.text;
        var open_len: usize = 0;
        while (start + open_len < text.len and text[start + open_len] == '`') open_len += 1;

        var i = start + open_len;
        while (i < text.len) {
            if (text[i] != '`') {
                i += 1;
                continue;
            }
            var close_len: usize = 0;
            while (i + close_len < text.len and text[i + close_len] == '`') close_len += 1;
            if (close_len == open_len) {
                const content = try normalizeCode(p.gpa, text[start + open_len .. i]);
                _ = try p.append(.{ .kind = .code, .text = content });
                return i + close_len;
            }
            i += close_len;
        }
        // No closer: the run is literal backticks.
        try p.appendLiteral(text[start .. start + open_len]);
        return start + open_len;
    }

    fn scanDelimRun(p: *Parser, start: usize) core.ReadError!usize {
        const text = p.text;
        const delim_char = text[start];
        var run_end = start;
        while (run_end < text.len and text[run_end] == delim_char) run_end += 1;
        const count: u32 = @intCast(run_end - start);

        const before = charBefore(text, start);
        const after = charAfter(text, run_end);
        const left_flanking = !isWhitespaceChar(after) and
            (!isPunctChar(after) or isWhitespaceChar(before) or isPunctChar(before));
        const right_flanking = !isWhitespaceChar(before) and
            (!isPunctChar(before) or isWhitespaceChar(after) or isPunctChar(after));

        var can_open = left_flanking;
        var can_close = right_flanking;
        if (delim_char == '_') {
            can_open = left_flanking and (!right_flanking or isPunctChar(before));
            can_close = right_flanking and (!left_flanking or isPunctChar(after));
        }
        if (delim_char == '~' and count != 2) {
            // GFM strikethrough here is exactly two tildes.
            try p.appendLiteral(text[start..run_end]);
            return run_end;
        }

        const index = try p.append(.{
            .kind = .delim,
            .text = text[start..run_end],
            .extra = count,
            .delim_char = delim_char,
            .can_open = can_open,
            .can_close = can_close,
        });
        p.pushDelim(index);
        return run_end;
    }

    fn scanFootnoteRef(p: *Parser, start: usize) core.ReadError!?usize {
        const text = p.text;
        if (start + 1 >= text.len or text[start + 1] != '^') return null;
        const label_start = start + 2;
        var i = label_start;
        while (i < text.len and text[i] != ']' and text[i] != '\n') i += 1;
        if (i >= text.len or text[i] != ']' or i == label_start) return null;

        var key_buffer: [256]u8 = undefined;
        const key = normalizeLabel(text[label_start..i], &key_buffer) orelse return null;
        const note = p.footnotes.get(key) orelse return null;
        _ = try p.append(.{ .kind = .note_ref, .extra = note });
        return i + 1;
    }

    // ---------------------------------------------------------- brackets

    fn closeBracket(p: *Parser, close_index: usize) core.ReadError!usize {
        const opener = p.brackets.pop() orelse {
            try p.appendLiteral(p.text[close_index .. close_index + 1]);
            return close_index + 1;
        };
        const opener_node = p.nodes.items[opener.node];
        if (!opener_node.active) {
            // The bracket stays where it is, as literal text.
            p.nodes.items[opener.node].kind = .literal;
            try p.appendLiteral(p.text[close_index .. close_index + 1]);
            return close_index + 1;
        }

        var consumed: usize = close_index + 1;
        var target: ?RefDef = null;
        if (parseInlineTarget(p.gpa, p.text, close_index + 1)) |parsed| {
            target = .{ .url = parsed.url, .title = parsed.title };
            consumed = parsed.end;
        } else |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.NoMatch => {
                // Reference forms: full [label], collapsed [], shortcut.
                const content_start = bracketContentStart(p, opener.node);
                const content = p.text[content_start..close_index];
                var label: []const u8 = content;
                if (close_index + 1 < p.text.len and p.text[close_index + 1] == '[') {
                    const label_end = std.mem.indexOfScalarPos(u8, p.text, close_index + 2, ']');
                    if (label_end) |end| {
                        const explicit = p.text[close_index + 2 .. end];
                        if (explicit.len > 0) label = explicit;
                        var key_buffer: [1024]u8 = undefined;
                        if (normalizeLabel(label, &key_buffer)) |key| {
                            if (p.refs.get(key)) |def| {
                                target = def;
                                consumed = end + 1;
                            }
                        }
                    }
                }
                if (target == null) {
                    var key_buffer: [1024]u8 = undefined;
                    if (normalizeLabel(label, &key_buffer)) |key| {
                        if (p.refs.get(key)) |def| target = def;
                    }
                }
            },
        }

        const def = target orelse {
            // Not a link: the bracket text becomes literal.
            p.nodes.items[opener.node].kind = .literal;
            try p.appendLiteral(p.text[close_index .. close_index + 1]);
            return close_index + 1;
        };

        const is_image = opener_node.is_image;
        p.nodes.items[opener.node].kind = if (is_image) .image_open else .link_open;
        p.nodes.items[opener.node].text = def.url;
        p.nodes.items[opener.node].title = def.title;
        _ = try p.append(.{ .kind = if (is_image) .image_close else .link_close });

        try p.processEmphasis(opener.delim_bottom);
        if (!is_image) {
            // No links inside links: deactivate earlier link openers.
            for (p.brackets.items) |earlier| {
                if (!p.nodes.items[earlier.node].is_image) {
                    p.nodes.items[earlier.node].active = false;
                }
            }
        }
        return consumed;
    }

    fn bracketContentStart(p: *Parser, opener: u32) usize {
        // The opener's text slice points into the source; content follows.
        const node = p.nodes.items[opener];
        return sliceOffset(p.text, node.text) + node.text.len;
    }

    // ---------------------------------------------------------- emphasis

    /// The spec's delimiter algorithm over the chain above `bottom`.
    fn processEmphasis(p: *Parser, bottom: u32) error{OutOfMemory}!void {
        // Find the first delimiter above bottom.
        var closer = blk: {
            var lowest: u32 = null_index;
            var walk = p.delim_top;
            while (walk != null_index and walk != bottom) {
                lowest = walk;
                walk = p.nodes.items[walk].prev_delim;
            }
            break :blk lowest;
        };

        var guard: u32 = 0;
        const guard_max: u32 = @intCast(p.nodes.items.len * p.nodes.items.len + 16);
        while (closer != null_index) {
            guard += 1;
            assert(guard <= guard_max);
            const closer_node = p.nodes.items[closer];
            if (!closer_node.can_close) {
                closer = closer_node.next_delim;
                continue;
            }
            // Scan back for a matching opener.
            var opener = closer_node.prev_delim;
            const found = while (opener != null_index and opener != bottom) {
                const opener_node = p.nodes.items[opener];
                if (opener_node.can_open and
                    opener_node.delim_char == closer_node.delim_char and
                    !oddMatchRule(opener_node, closer_node))
                {
                    break true;
                }
                opener = opener_node.prev_delim;
            } else false;

            if (!found) {
                const next = closer_node.next_delim;
                if (!closer_node.can_open) p.removeDelim(closer);
                closer = next;
                continue;
            }

            if (closer_node.delim_char == '~') {
                try p.pair(opener, closer, 2, .strike_open, .strike_close);
            } else {
                const use: u32 = if (p.nodes.items[opener].extra >= 2 and
                    p.nodes.items[closer].extra >= 2) 2 else 1;
                if (use == 2) {
                    try p.pair(opener, closer, 2, .strong_open, .strong_close);
                } else {
                    try p.pair(opener, closer, 1, .emph_open, .emph_close);
                }
            }
            // Delimiters between opener and closer can no longer match.
            var between = p.nodes.items[closer].prev_delim;
            while (between != null_index and between != opener) {
                const next = p.nodes.items[between].prev_delim;
                p.removeDelim(between);
                between = next;
            }
            const closer_now = &p.nodes.items[closer];
            if (closer_now.extra == 0) {
                const next = closer_now.next_delim;
                p.removeDelim(closer);
                p.remove(closer);
                closer = next;
            }
            const opener_now = &p.nodes.items[opener];
            if (opener_now.extra == 0) {
                p.removeDelim(opener);
                p.remove(opener);
            }
        }
        // Everything left above bottom is literal.
        while (p.delim_top != null_index and p.delim_top != bottom) {
            const index = p.delim_top;
            p.nodes.items[index].kind = .literal;
            p.nodes.items[index].text = p.nodes.items[index].text[0..p.nodes.items[index].extra];
            p.removeDelim(index);
        }
    }

    /// "Rule of three": a delimiter that can both open and close cannot
    /// pair when the sum of lengths is a multiple of 3, unless both are.
    fn oddMatchRule(opener: Node, closer: Node) bool {
        if (opener.delim_char == '~') return false;
        if (!(closer.can_open or opener.can_close)) return false;
        const total = opener.extra + closer.extra;
        return total % 3 == 0 and !(opener.extra % 3 == 0 and closer.extra % 3 == 0);
    }

    fn pair(
        p: *Parser,
        opener: u32,
        closer: u32,
        use: u32,
        open_kind: Kind,
        close_kind: Kind,
    ) error{OutOfMemory}!void {
        assert(p.nodes.items[opener].extra >= use);
        assert(p.nodes.items[closer].extra >= use);
        p.nodes.items[opener].extra -= use;
        p.nodes.items[closer].extra -= use;
        // The inserted pair encloses everything between the runs.
        _ = try p.insertAfter(opener, .{ .kind = open_kind });
        _ = try p.insertBefore(closer, .{ .kind = close_kind });
    }

    // -------------------------------------------------------------- misc

    fn scanAngle(p: *Parser, start: usize) core.ReadError!usize {
        const text = p.text;
        const close = std.mem.indexOfScalarPos(u8, text, start + 1, '>') orelse {
            try p.appendLiteral(text[start .. start + 1]);
            return start + 1;
        };
        const inner = text[start + 1 .. close];
        if (isAutolinkUri(inner)) {
            _ = try p.append(.{ .kind = .link_open, .text = inner });
            try p.appendLiteral(inner);
            _ = try p.append(.{ .kind = .link_close });
            return close + 1;
        }
        if (isEmailAutolink(inner)) {
            const url = try std.mem.concat(p.gpa, u8, &.{ "mailto:", inner });
            _ = try p.append(.{ .kind = .link_open, .text = url });
            try p.appendLiteral(inner);
            _ = try p.append(.{ .kind = .link_close });
            return close + 1;
        }
        if (isRawHtmlTag(inner)) {
            _ = try p.append(.{ .kind = .raw_html, .text = text[start .. close + 1] });
            return close + 1;
        }
        try p.appendLiteral(text[start .. start + 1]);
        return start + 1;
    }

    // -------------------------------------------------------------- emit

    fn emit(p: *Parser, out: core.Emitter) core.ReadError!void {
        var open_tokens: [256]core.builder.InlineToken = undefined;
        var open_depth: u32 = 0;

        var walk = p.head;
        var guard: u32 = 0;
        const guard_max: u32 = @intCast(p.nodes.items.len + 1);
        while (walk != null_index) {
            guard += 1;
            assert(guard <= guard_max);
            const node = p.nodes.items[walk];
            switch (node.kind) {
                .literal, .bracket => try out.text(node.text),
                .delim => try out.text(node.text[0..node.extra]),
                .code => try out.code(node.text),
                .raw_html => try out.rawInline("html", node.text),
                .softbreak => try out.softBreak(),
                .hardbreak => try out.hardBreak(),
                .note_ref => try out.noteReference(node.extra),
                .emph_open => {
                    assert(open_depth < open_tokens.len);
                    open_tokens[open_depth] = try out.beginInline(.emphasis);
                    open_depth += 1;
                },
                .strong_open => {
                    assert(open_depth < open_tokens.len);
                    open_tokens[open_depth] = try out.beginInline(.strong);
                    open_depth += 1;
                },
                .strike_open => {
                    assert(open_depth < open_tokens.len);
                    open_tokens[open_depth] = try out.beginInline(.strikethrough);
                    open_depth += 1;
                },
                .link_open => {
                    assert(open_depth < open_tokens.len);
                    open_tokens[open_depth] = try out.beginLink(node.text, node.title);
                    open_depth += 1;
                },
                .image_open => {
                    assert(open_depth < open_tokens.len);
                    open_tokens[open_depth] = try out.beginImage(node.text, node.title);
                    open_depth += 1;
                },
                .emph_close, .strong_close, .strike_close, .link_close, .image_close => {
                    assert(open_depth > 0);
                    open_depth -= 1;
                    out.endInline(open_tokens[open_depth]);
                },
            }
            walk = node.next;
        }
        assert(open_depth == 0);
    }
};

// ------------------------------------------------------ target parsing

const TargetParse = struct {
    url: []const u8,
    title: []const u8,
    end: usize,
};

/// Parses `(destination "title")` starting at `start`. Escapes are decoded
/// into the arena; the pointed-to angle form `<...>` accepts spaces.
fn parseInlineTarget(
    gpa: std.mem.Allocator,
    text: []const u8,
    start: usize,
) error{ OutOfMemory, NoMatch }!TargetParse {
    var i = start;
    if (i >= text.len or text[i] != '(') return error.NoMatch;
    i = skipSpaces(text, i + 1);

    var url: std.ArrayList(u8) = .empty;
    defer url.deinit(gpa);
    if (i < text.len and text[i] == '<') {
        i += 1;
        while (i < text.len and text[i] != '>') {
            if (text[i] == '\n' or text[i] == '<') return error.NoMatch;
            if (text[i] == '\\' and i + 1 < text.len and isEscapable(text[i + 1])) i += 1;
            try url.append(gpa, text[i]);
            i += 1;
        }
        if (i >= text.len) return error.NoMatch;
        i += 1;
    } else {
        var depth: u32 = 0;
        while (i < text.len) {
            const byte = text[i];
            if (byte <= ' ') break;
            if (byte == '(') {
                depth += 1;
                if (depth > 32) return error.NoMatch;
            } else if (byte == ')') {
                if (depth == 0) break;
                depth -= 1;
            }
            if (byte == '\\' and i + 1 < text.len and isEscapable(text[i + 1])) {
                try url.append(gpa, text[i + 1]);
                i += 2;
                continue;
            }
            try url.append(gpa, byte);
            i += 1;
        }
        if (depth != 0) return error.NoMatch;
    }

    i = skipSpaces(text, i);
    var title: std.ArrayList(u8) = .empty;
    defer title.deinit(gpa);
    if (i < text.len and (text[i] == '"' or text[i] == '\'')) {
        const quote = text[i];
        i += 1;
        while (i < text.len and text[i] != quote) {
            if (text[i] == '\\' and i + 1 < text.len and isEscapable(text[i + 1])) i += 1;
            try title.append(gpa, text[i]);
            i += 1;
        }
        if (i >= text.len) return error.NoMatch;
        i += 1;
        i = skipSpaces(text, i);
    }

    if (i >= text.len or text[i] != ')') return error.NoMatch;
    return .{
        .url = try url.toOwnedSlice(gpa),
        .title = try title.toOwnedSlice(gpa),
        .end = i + 1,
    };
}

fn skipSpaces(text: []const u8, start: usize) usize {
    var i = start;
    while (i < text.len and (text[i] == ' ' or text[i] == '\t' or text[i] == '\n')) i += 1;
    return i;
}

// ------------------------------------------------------ classification

fn sliceOffset(haystack: []const u8, inner: []const u8) usize {
    const base = @intFromPtr(haystack.ptr);
    const ptr = @intFromPtr(inner.ptr);
    assert(ptr >= base and ptr <= base + haystack.len);
    return ptr - base;
}

fn isEscapable(byte: u8) bool {
    return switch (byte) {
        '!', '"', '#', '$', '%', '&', '\'', '(', ')', '*', '+', ',', '-', '.', '/', ':', ';', '<', '=', '>', '?', '@', '[', '\\', ']', '^', '_', '`', '{', '|', '}', '~' => true,
        else => false,
    };
}

fn charBefore(text: []const u8, index: usize) u21 {
    if (index == 0) return ' ';
    var start = index - 1;
    while (start > 0 and text[start] & 0xc0 == 0x80) start -= 1;
    const length = std.unicode.utf8ByteSequenceLength(text[start]) catch return ' ';
    if (start + length > index) return ' ';
    return std.unicode.utf8Decode(text[start..][0..length]) catch ' ';
}

fn charAfter(text: []const u8, index: usize) u21 {
    if (index >= text.len) return ' ';
    const length = std.unicode.utf8ByteSequenceLength(text[index]) catch return ' ';
    if (index + length > text.len) return ' ';
    return std.unicode.utf8Decode(text[index..][0..length]) catch ' ';
}

fn isWhitespaceChar(char: u21) bool {
    return switch (char) {
        ' ', '\t', '\n', '\r', 0x0b, 0x0c, 0xa0 => true,
        else => false,
    };
}

fn isPunctChar(char: u21) bool {
    if (char > 0x7f) return false;
    const byte: u8 = @intCast(char);
    return switch (byte) {
        '!'...'/', ':'...'@', '['...'`', '{'...'~' => true,
        else => false,
    };
}

fn normalizeCode(gpa: std.mem.Allocator, content: []const u8) error{OutOfMemory}![]const u8 {
    var buffer: std.ArrayList(u8) = .empty;
    errdefer buffer.deinit(gpa);
    var all_space = true;
    for (content) |byte| {
        try buffer.append(gpa, if (byte == '\n') ' ' else byte);
        if (byte != ' ' and byte != '\n') all_space = false;
    }
    const items = buffer.items;
    if (!all_space and items.len >= 2 and items[0] == ' ' and items[items.len - 1] == ' ') {
        const trimmed = try gpa.dupe(u8, items[1 .. items.len - 1]);
        buffer.deinit(gpa);
        return trimmed;
    }
    return buffer.toOwnedSlice(gpa);
}

/// Trim, collapse internal whitespace, ASCII case-fold. Returns null when
/// the label exceeds the buffer — such labels never match anything.
pub fn normalizeLabel(label: []const u8, buffer: []u8) ?[]const u8 {
    var length: usize = 0;
    var pending_space = false;
    for (label) |byte| {
        const is_space = byte == ' ' or byte == '\t' or byte == '\n' or byte == '\r';
        if (is_space) {
            if (length > 0) pending_space = true;
            continue;
        }
        if (pending_space) {
            if (length >= buffer.len) return null;
            buffer[length] = ' ';
            length += 1;
            pending_space = false;
        }
        if (length >= buffer.len) return null;
        buffer[length] = std.ascii.toLower(byte);
        length += 1;
    }
    if (length == 0) return null;
    return buffer[0..length];
}

fn isAutolinkUri(inner: []const u8) bool {
    const colon = std.mem.indexOfScalar(u8, inner, ':') orelse return false;
    if (colon < 2 or colon > 32) return false;
    if (!std.ascii.isAlphabetic(inner[0])) return false;
    for (inner[1..colon]) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '+' and byte != '.' and byte != '-') {
            return false;
        }
    }
    for (inner[colon + 1 ..]) |byte| {
        if (byte <= ' ' or byte == '<' or byte == '>') return false;
    }
    return true;
}

fn isEmailAutolink(inner: []const u8) bool {
    const at = std.mem.indexOfScalar(u8, inner, '@') orelse return false;
    if (at == 0 or at + 1 >= inner.len) return false;
    if (std.mem.indexOfScalar(u8, inner, ' ') != null) return false;
    return std.mem.indexOfScalarPos(u8, inner, at + 1, '.') != null;
}

fn isRawHtmlTag(inner: []const u8) bool {
    if (inner.len == 0) return false;
    var i: usize = 0;
    if (inner[0] == '/') i = 1;
    if (std.mem.startsWith(u8, inner, "!--")) return true;
    if (i >= inner.len or !std.ascii.isAlphabetic(inner[i])) return false;
    i += 1;
    while (i < inner.len) : (i += 1) {
        const byte = inner[i];
        if (std.ascii.isAlphanumeric(byte) or byte == '-') continue;
        // Anything after the name: attributes, /, quotes. Accept loosely;
        // the writer re-emits it verbatim as raw HTML either way.
        return byte == ' ' or byte == '\t' or byte == '\n' or byte == '/' or byte == '=';
    }
    return true;
}

const DecodedEntity = struct {
    bytes: []const u8,
    consumed: usize,
};

const named_entities = [_]struct { name: []const u8, value: []const u8 }{
    .{ .name = "amp", .value = "&" },
    .{ .name = "lt", .value = "<" },
    .{ .name = "gt", .value = ">" },
    .{ .name = "quot", .value = "\"" },
    .{ .name = "apos", .value = "'" },
    .{ .name = "nbsp", .value = "\u{a0}" },
    .{ .name = "mdash", .value = "—" },
    .{ .name = "ndash", .value = "–" },
    .{ .name = "hellip", .value = "…" },
    .{ .name = "copy", .value = "©" },
    .{ .name = "reg", .value = "®" },
    .{ .name = "trade", .value = "™" },
    .{ .name = "ldquo", .value = "\u{201c}" },
    .{ .name = "rdquo", .value = "\u{201d}" },
    .{ .name = "lsquo", .value = "\u{2018}" },
    .{ .name = "rsquo", .value = "\u{2019}" },
    .{ .name = "laquo", .value = "«" },
    .{ .name = "raquo", .value = "»" },
    .{ .name = "sect", .value = "§" },
    .{ .name = "para", .value = "¶" },
    .{ .name = "middot", .value = "·" },
    .{ .name = "bull", .value = "•" },
    .{ .name = "deg", .value = "°" },
    .{ .name = "plusmn", .value = "±" },
    .{ .name = "times", .value = "×" },
    .{ .name = "divide", .value = "÷" },
    .{ .name = "micro", .value = "µ" },
};

fn decodeEntity(gpa: std.mem.Allocator, rest: []const u8) error{OutOfMemory}!?DecodedEntity {
    assert(rest.len > 0 and rest[0] == '&');
    const semi = std.mem.indexOfScalar(u8, rest[0..@min(rest.len, 40)], ';') orelse return null;
    const body = rest[1..semi];
    if (body.len == 0) return null;
    if (body[0] == '#') {
        const digits = body[1..];
        const code = if (digits.len > 1 and (digits[0] == 'x' or digits[0] == 'X'))
            std.fmt.parseInt(u21, digits[1..], 16) catch return null
        else
            std.fmt.parseInt(u21, digits, 10) catch return null;
        if (code == 0 or code > 0x10ffff) return null;
        if (code >= 0xd800 and code <= 0xdfff) return null;
        var encoded: [4]u8 = undefined;
        const length = std.unicode.utf8Encode(code, &encoded) catch return null;
        // Decoded bytes must outlive the node list: they go to the arena.
        return .{ .bytes = try gpa.dupe(u8, encoded[0..length]), .consumed = semi + 1 };
    }
    for (named_entities) |entity| {
        if (std.mem.eql(u8, entity.name, body)) {
            return .{ .bytes = entity.value, .consumed = semi + 1 };
        }
    }
    return null;
}
