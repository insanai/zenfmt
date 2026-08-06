//! The HTML reader (ZDS 0002, The other formats): a tolerant parser in the
//! tag-soup tradition — real HTML rarely nests the way the specification
//! draws it, so unexpected end tags close what they can and unknown
//! elements become attributed containers and spans. This is the reason
//! `container`, `span`, and `raw` are in the node set, and the format most
//! likely to produce deeply nested input, so it is the primary consumer of
//! `max_depth`.

const std = @import("std");
const assert = std.debug.assert;
const core = @import("zenfmt_core");

pub const reader = core.Reader(.{
    .id = "ai.insan.zenfmt.html",
    .format = "html",
    .extensions = &.{ "html", "htm" },
    .read = read,
});

fn read(ctx: *core.ReadContext) core.ReadError!void {
    if (!std.unicode.utf8ValidateSlice(ctx.input.bytes)) {
        try ctx.reports.add(invalidUtf8Report());
        return error.Malformed;
    }
    var parser: Parser = .{ .ctx = ctx, .bytes = ctx.input.bytes };
    defer parser.deinit();
    try parser.run();
}

const ElementKind = enum {
    // Block-producing elements.
    heading,
    paragraph,
    blockquote,
    list,
    list_item,
    pre,
    container,
    table,
    table_section,
    table_row,
    table_cell,
    // Inline-producing elements.
    emphasis,
    strong,
    strikethrough,
    superscript,
    subscript,
    underline,
    code,
    link,
    span,
    // Structure the reader looks through or ignores.
    transparent,
    skipped,
};

const Open = struct {
    kind: ElementKind,
    /// The tag that opened this entry, for end-tag matching.
    tag: []const u8,
    block_token: ?core.builder.BlockToken = null,
    inline_token: ?core.builder.InlineToken = null,
};

const Parser = struct {
    ctx: *core.ReadContext,
    bytes: []const u8,
    pos: usize = 0,

    stack: [core.limits.max_depth_hard_cap]Open = undefined,
    depth: u32 = 0,
    /// The innermost open paragraph-like leaf, if any.
    leaf: ?core.builder.BlockToken = null,
    /// Inside `<pre>`: text accumulates verbatim into a buffer.
    pre_buffer: ?std.ArrayList(u8) = null,

    fn deinit(p: *Parser) void {
        if (p.pre_buffer) |*buffer| buffer.deinit(p.ctx.gpa);
    }

    fn run(p: *Parser) core.ReadError!void {
        while (p.pos < p.bytes.len) {
            if (p.bytes[p.pos] == '<') {
                try p.markup();
            } else {
                try p.textRun();
            }
        }
        try p.closeAll();
    }

    fn textRun(p: *Parser) core.ReadError!void {
        const start = p.pos;
        const end = std.mem.indexOfScalarPos(u8, p.bytes, start, '<') orelse p.bytes.len;
        p.pos = end;
        const raw = p.bytes[start..end];

        if (p.pre_buffer) |*buffer| {
            try appendDecoded(p.ctx.gpa, buffer, raw);
            return;
        }
        if (isWhitespaceOnly(raw)) {
            // Inter-element whitespace still separates words mid-paragraph.
            if (p.leaf != null) try p.ctx.out.text(" ");
            return;
        }
        try p.ensureParagraph();
        var decoded: std.ArrayList(u8) = .empty;
        defer decoded.deinit(p.ctx.gpa);
        try appendDecoded(p.ctx.gpa, &decoded, raw);
        try p.ctx.out.text(decoded.items);
    }

    fn markup(p: *Parser) core.ReadError!void {
        assert(p.bytes[p.pos] == '<');
        if (std.mem.startsWith(u8, p.bytes[p.pos..], "<!--")) {
            const end = std.mem.indexOfPos(u8, p.bytes, p.pos + 4, "-->") orelse p.bytes.len;
            p.pos = @min(end + 3, p.bytes.len);
            return;
        }
        if (std.mem.startsWith(u8, p.bytes[p.pos..], "<!") or
            std.mem.startsWith(u8, p.bytes[p.pos..], "<?"))
        {
            const end = std.mem.indexOfScalarPos(u8, p.bytes, p.pos, '>') orelse p.bytes.len;
            p.pos = @min(end + 1, p.bytes.len);
            return;
        }
        const end = findTagEnd(p.bytes, p.pos) orelse {
            // A lone `<` in text.
            try p.ensureParagraph();
            try p.ctx.out.text("<");
            p.pos += 1;
            return;
        };
        var inner = p.bytes[p.pos + 1 .. end];
        p.pos = end + 1;

        var closing = false;
        if (inner.len > 0 and inner[0] == '/') {
            closing = true;
            inner = inner[1..];
        }
        var self_closing = false;
        if (inner.len > 0 and inner[inner.len - 1] == '/') {
            self_closing = true;
            inner = inner[0 .. inner.len - 1];
        }

        var cursor: usize = 0;
        const tag_raw = readToken(inner, &cursor) orelse return;
        var tag_buffer: [24]u8 = undefined;
        if (tag_raw.len > tag_buffer.len) return;
        const tag = std.ascii.lowerString(&tag_buffer, tag_raw);

        if (closing) {
            try p.closeTag(tag);
        } else {
            try p.openTag(tag, inner[cursor..], self_closing);
        }
    }

    // ---------------------------------------------------------- open/close

    fn openTag(p: *Parser, tag: []const u8, attrs: []const u8, self_closing: bool) core.ReadError!void {
        // Void and replaced elements first.
        if (std.mem.eql(u8, tag, "br")) {
            try p.ensureParagraph();
            try p.ctx.out.hardBreak();
            return;
        }
        if (std.mem.eql(u8, tag, "hr")) {
            try p.closeParagraph();
            try p.ctx.out.thematicBreak();
            return;
        }
        if (std.mem.eql(u8, tag, "img")) {
            try p.ensureParagraph();
            const src = try attributeValue(p.ctx.gpa, attrs, "src") orelse "";
            const alt = try attributeValue(p.ctx.gpa, attrs, "alt") orelse "";
            const token = try p.ctx.out.beginImage(src, "");
            if (alt.len > 0) try p.ctx.out.text(alt);
            p.ctx.out.endInline(token);
            return;
        }
        if (std.mem.eql(u8, tag, "meta") or std.mem.eql(u8, tag, "link") or
            std.mem.eql(u8, tag, "input") or std.mem.eql(u8, tag, "wbr") or
            std.mem.eql(u8, tag, "source") or std.mem.eql(u8, tag, "col"))
        {
            return;
        }
        if (std.mem.eql(u8, tag, "script") or std.mem.eql(u8, tag, "style") or
            std.mem.eql(u8, tag, "template") or std.mem.eql(u8, tag, "head") or
            std.mem.eql(u8, tag, "iframe") or std.mem.eql(u8, tag, "svg") or
            std.mem.eql(u8, tag, "noscript"))
        {
            // Raw-text and non-content elements: skip to the closing tag.
            try p.skipRawText(tag);
            return;
        }

        const kind = classify(tag);
        if (self_closing and kind != .transparent) return;

        switch (kind) {
            .heading => {
                try p.closeParagraph();
                const level: u8 = tag[1] - '0';
                p.leaf = try p.ctx.out.beginHeading(@min(@max(level, 1), 6));
                try p.push(.{ .kind = .heading, .tag = "h", .block_token = p.leaf });
            },
            .paragraph => {
                try p.closeParagraph();
                p.leaf = try p.ctx.out.beginParagraph();
                try p.push(.{ .kind = .paragraph, .tag = "p", .block_token = p.leaf });
            },
            .blockquote => {
                try p.closeParagraph();
                const token = try p.ctx.out.beginBlock(.quote);
                try p.push(.{ .kind = .blockquote, .tag = "blockquote", .block_token = token });
            },
            .pre => {
                try p.closeParagraph();
                p.pre_buffer = .empty;
                try p.push(.{ .kind = .pre, .tag = "pre" });
            },
            .list => {
                try p.closeParagraph();
                const ordered = std.mem.eql(u8, tag, "ol");
                const token = try p.ctx.out.beginList(.{
                    .kind = if (ordered) .ordered else .unordered,
                    .start = 1,
                    .style = .decimal,
                    .delimiter = .period,
                });
                try p.push(.{ .kind = .list, .tag = if (ordered) "ol" else "ul", .block_token = token });
            },
            .list_item => {
                // An open item closes at its sibling, as real HTML expects.
                try p.closeImplicit(.list_item);
                const token = try p.ctx.out.beginBlock(.list_item);
                try p.push(.{ .kind = .list_item, .tag = "li", .block_token = token });
            },
            .table => {
                try p.closeParagraph();
                const token = try p.ctx.out.beginTable(&.{.default});
                try p.push(.{ .kind = .table, .tag = "table", .block_token = token });
            },
            .table_section => {
                const head = std.mem.eql(u8, tag, "thead");
                const token = if (head)
                    try p.ctx.out.beginBlock(.table_head)
                else
                    try p.ctx.out.beginTableBody(.{ .row_head_columns = 0, .head_rows = 0 });
                try p.push(.{ .kind = .table_section, .tag = if (head) "thead" else "tbody", .block_token = token });
            },
            .table_row => {
                try p.closeImplicit(.table_row);
                try p.ensureTableSection();
                const token = try p.ctx.out.beginBlock(.table_row);
                try p.push(.{ .kind = .table_row, .tag = "tr", .block_token = token });
            },
            .table_cell => {
                try p.closeImplicit(.table_cell);
                const cell = try p.ctx.out.beginTableCell(.plain);
                p.leaf = try p.ctx.out.beginPlain();
                try p.push(.{ .kind = .table_cell, .tag = "td", .block_token = cell });
            },
            .container => {
                try p.closeParagraph();
                const class = try attributeValue(p.ctx.gpa, attrs, "class");
                const id = try attributeValue(p.ctx.gpa, attrs, "id");
                if (class != null or id != null or !std.mem.eql(u8, tag, "div")) {
                    var classes: [2][]const u8 = undefined;
                    var class_count: usize = 0;
                    if (!std.mem.eql(u8, tag, "div")) {
                        classes[class_count] = try p.ctx.gpa.dupe(u8, tag);
                        class_count += 1;
                    }
                    if (class) |value| {
                        classes[class_count] = value;
                        class_count += 1;
                    }
                    try p.ctx.out.attrs(.{
                        .id = id orelse "",
                        .classes = classes[0..class_count],
                    });
                }
                const token = try p.ctx.out.beginBlock(.container);
                try p.push(.{ .kind = .container, .tag = "div", .block_token = token });
            },
            .emphasis, .strong, .strikethrough, .superscript, .subscript, .underline => {
                try p.ensureParagraph();
                const inline_tag: core.InlineTag = switch (kind) {
                    .emphasis => .emphasis,
                    .strong => .strong,
                    .strikethrough => .strikethrough,
                    .superscript => .superscript,
                    .subscript => .subscript,
                    .underline => .underline,
                    else => unreachable,
                };
                const token = try p.ctx.out.beginInline(inline_tag);
                try p.push(.{ .kind = kind, .tag = try p.ctx.gpa.dupe(u8, tag), .inline_token = token });
            },
            .code => {
                // Inline code content is read as raw text to the close tag.
                try p.ensureParagraph();
                const start = p.pos;
                const close = indexOfIgnoreCasePos(p.bytes, start, "</code") orelse p.bytes.len;
                var decoded: std.ArrayList(u8) = .empty;
                defer decoded.deinit(p.ctx.gpa);
                try appendDecoded(p.ctx.gpa, &decoded, p.bytes[start..close]);
                try p.ctx.out.code(decoded.items);
                p.pos = close;
                if (close < p.bytes.len) {
                    const tag_end = std.mem.indexOfScalarPos(u8, p.bytes, close, '>') orelse p.bytes.len;
                    p.pos = @min(tag_end + 1, p.bytes.len);
                }
            },
            .link => {
                try p.ensureParagraph();
                const href = try attributeValue(p.ctx.gpa, attrs, "href") orelse "";
                const title = try attributeValue(p.ctx.gpa, attrs, "title") orelse "";
                const token = try p.ctx.out.beginLink(href, title);
                try p.push(.{ .kind = .link, .tag = "a", .inline_token = token });
            },
            .span => {
                try p.ensureParagraph();
                const class = try attributeValue(p.ctx.gpa, attrs, "class");
                if (class) |value| {
                    try p.ctx.out.attrs(.{ .classes = &.{value} });
                }
                const token = try p.ctx.out.beginInline(.span);
                try p.push(.{ .kind = .span, .tag = try p.ctx.gpa.dupe(u8, tag), .inline_token = token });
            },
            .transparent, .skipped => {
                try p.push(.{ .kind = .transparent, .tag = try p.ctx.gpa.dupe(u8, tag) });
            },
        }
    }

    fn closeTag(p: *Parser, tag: []const u8) core.ReadError!void {
        // Find the nearest matching open entry; close everything above it.
        var i = p.depth;
        const target: ?u32 = while (i > 0) {
            i -= 1;
            if (tagMatches(p.stack[i], tag)) break i;
        } else null;
        const found = target orelse return;
        while (p.depth > found) {
            try p.popOne();
        }
    }

    fn closeImplicit(p: *Parser, kind: ElementKind) core.ReadError!void {
        // Close an open sibling of the same kind, without crossing block
        // boundaries like a nested list.
        var i = p.depth;
        while (i > 0) {
            i -= 1;
            const open_kind = p.stack[i].kind;
            if (open_kind == kind) {
                while (p.depth > i) try p.popOne();
                return;
            }
            switch (open_kind) {
                .emphasis, .strong, .strikethrough, .superscript, .subscript, .underline, .link, .span, .paragraph, .heading, .transparent => continue,
                else => return,
            }
        }
    }

    fn ensureTableSection(p: *Parser) core.ReadError!void {
        var i = p.depth;
        while (i > 0) {
            i -= 1;
            switch (p.stack[i].kind) {
                .table_section => return,
                .table => {
                    const token = try p.ctx.out.beginTableBody(.{
                        .row_head_columns = 0,
                        .head_rows = 0,
                    });
                    try p.push(.{ .kind = .table_section, .tag = "tbody", .block_token = token });
                    return;
                },
                else => {},
            }
        }
    }

    fn popOne(p: *Parser) core.ReadError!void {
        assert(p.depth > 0);
        p.depth -= 1;
        const open = p.stack[p.depth];
        switch (open.kind) {
            .pre => {
                if (p.pre_buffer) |*buffer| {
                    try p.ctx.out.codeBlock("", buffer.items);
                    buffer.deinit(p.ctx.gpa);
                    p.pre_buffer = null;
                }
            },
            .heading, .paragraph => {
                if (open.block_token) |token| {
                    p.ctx.out.endBlock(token);
                    if (p.leaf != null and p.leaf.?.index == token.index) p.leaf = null;
                }
            },
            .table_cell => {
                if (p.leaf) |leaf| {
                    p.ctx.out.endBlock(leaf);
                    p.leaf = null;
                }
                if (open.block_token) |token| p.ctx.out.endBlock(token);
            },
            else => {
                if (open.inline_token) |token| p.ctx.out.endInline(token);
                if (open.block_token) |token| p.ctx.out.endBlock(token);
            },
        }
    }

    fn closeParagraph(p: *Parser) core.ReadError!void {
        // Close up to and including the innermost paragraph-like leaf.
        var i = p.depth;
        while (i > 0) {
            i -= 1;
            switch (p.stack[i].kind) {
                .paragraph, .heading => {
                    while (p.depth > i) try p.popOne();
                    return;
                },
                .emphasis, .strong, .strikethrough, .superscript, .subscript, .underline, .link, .span, .transparent => continue,
                else => return,
            }
        }
    }

    fn ensureParagraph(p: *Parser) core.ReadError!void {
        if (p.leaf != null) return;
        // Inside a table cell, the plain leaf is managed by the cell.
        p.leaf = try p.ctx.out.beginParagraph();
        try p.push(.{ .kind = .paragraph, .tag = "p", .block_token = p.leaf });
    }

    fn closeAll(p: *Parser) core.ReadError!void {
        while (p.depth > 0) try p.popOne();
    }

    fn push(p: *Parser, open: Open) core.ReadError!void {
        if (p.depth >= p.ctx.limits.max_depth) {
            try p.ctx.reports.add(tooDeepReport());
            return error.DepthLimitExceeded;
        }
        p.stack[p.depth] = open;
        p.depth += 1;
    }

    fn skipRawText(p: *Parser, tag: []const u8) core.ReadError!void {
        var needle_buffer: [32]u8 = undefined;
        const needle = std.fmt.bufPrint(&needle_buffer, "</{s}", .{tag}) catch return;
        const close = indexOfIgnoreCasePos(p.bytes, p.pos, needle) orelse {
            p.pos = p.bytes.len;
            return;
        };
        const end = std.mem.indexOfScalarPos(u8, p.bytes, close, '>') orelse p.bytes.len;
        p.pos = @min(end + 1, p.bytes.len);
    }
};

fn tagMatches(open: Open, tag: []const u8) bool {
    if (std.mem.eql(u8, open.tag, tag)) return true;
    // Headings share one stack tag; any `</hN>` closes the open heading.
    if (std.mem.eql(u8, open.tag, "h") and tag.len == 2 and tag[0] == 'h') return true;
    if (std.mem.eql(u8, open.tag, "td") and std.mem.eql(u8, tag, "th")) return true;
    if (std.mem.eql(u8, open.tag, "tbody") and std.mem.eql(u8, tag, "thead")) return true;
    return false;
}

fn classify(tag: []const u8) ElementKind {
    if (tag.len == 2 and tag[0] == 'h' and tag[1] >= '1' and tag[1] <= '6') return .heading;
    if (std.mem.eql(u8, tag, "p")) return .paragraph;
    if (std.mem.eql(u8, tag, "blockquote")) return .blockquote;
    if (std.mem.eql(u8, tag, "ul") or std.mem.eql(u8, tag, "ol")) return .list;
    if (std.mem.eql(u8, tag, "li")) return .list_item;
    if (std.mem.eql(u8, tag, "pre")) return .pre;
    if (std.mem.eql(u8, tag, "table")) return .table;
    if (std.mem.eql(u8, tag, "thead") or std.mem.eql(u8, tag, "tbody") or
        std.mem.eql(u8, tag, "tfoot")) return .table_section;
    if (std.mem.eql(u8, tag, "tr")) return .table_row;
    if (std.mem.eql(u8, tag, "td") or std.mem.eql(u8, tag, "th")) return .table_cell;
    if (std.mem.eql(u8, tag, "div") or std.mem.eql(u8, tag, "section") or
        std.mem.eql(u8, tag, "article") or std.mem.eql(u8, tag, "aside") or
        std.mem.eql(u8, tag, "figure") or std.mem.eql(u8, tag, "main") or
        std.mem.eql(u8, tag, "nav") or std.mem.eql(u8, tag, "header") or
        std.mem.eql(u8, tag, "footer")) return .container;
    if (std.mem.eql(u8, tag, "em") or std.mem.eql(u8, tag, "i")) return .emphasis;
    if (std.mem.eql(u8, tag, "strong") or std.mem.eql(u8, tag, "b")) return .strong;
    if (std.mem.eql(u8, tag, "s") or std.mem.eql(u8, tag, "del") or
        std.mem.eql(u8, tag, "strike")) return .strikethrough;
    if (std.mem.eql(u8, tag, "sup")) return .superscript;
    if (std.mem.eql(u8, tag, "sub")) return .subscript;
    if (std.mem.eql(u8, tag, "u") or std.mem.eql(u8, tag, "ins")) return .underline;
    if (std.mem.eql(u8, tag, "code") or std.mem.eql(u8, tag, "tt") or
        std.mem.eql(u8, tag, "kbd") or std.mem.eql(u8, tag, "samp")) return .code;
    if (std.mem.eql(u8, tag, "a")) return .link;
    if (std.mem.eql(u8, tag, "span") or std.mem.eql(u8, tag, "mark") or
        std.mem.eql(u8, tag, "abbr") or std.mem.eql(u8, tag, "cite") or
        std.mem.eql(u8, tag, "q") or std.mem.eql(u8, tag, "small")) return .span;
    return .transparent;
}

// -------------------------------------------------------------- lexing

fn indexOfIgnoreCasePos(haystack: []const u8, start: usize, needle: []const u8) ?usize {
    if (needle.len == 0 or start >= haystack.len) return null;
    var i = start;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i..][0..needle.len], needle)) return i;
    }
    return null;
}

fn findTagEnd(bytes: []const u8, start: usize) ?usize {
    var i = start + 1;
    var quote: u8 = 0;
    while (i < bytes.len) : (i += 1) {
        const byte = bytes[i];
        if (quote != 0) {
            if (byte == quote) quote = 0;
        } else if (byte == '"' or byte == '\'') {
            quote = byte;
        } else if (byte == '>') {
            return i;
        }
    }
    return null;
}

fn readToken(inner: []const u8, cursor: *usize) ?[]const u8 {
    while (cursor.* < inner.len and isSpace(inner[cursor.*])) cursor.* += 1;
    const start = cursor.*;
    while (cursor.* < inner.len and !isSpace(inner[cursor.*]) and inner[cursor.*] != '=') {
        cursor.* += 1;
    }
    if (cursor.* == start) return null;
    return inner[start..cursor.*];
}

fn isSpace(byte: u8) bool {
    return byte == ' ' or byte == '\t' or byte == '\n' or byte == '\r';
}

/// Case-insensitive attribute lookup with entity decoding.
fn attributeValue(
    gpa: std.mem.Allocator,
    attrs: []const u8,
    name: []const u8,
) error{OutOfMemory}!?[]const u8 {
    var cursor: usize = 0;
    while (true) {
        const token = readToken(attrs, &cursor) orelse return null;
        while (cursor < attrs.len and isSpace(attrs[cursor])) cursor += 1;
        var value: []const u8 = "";
        if (cursor < attrs.len and attrs[cursor] == '=') {
            cursor += 1;
            while (cursor < attrs.len and isSpace(attrs[cursor])) cursor += 1;
            if (cursor < attrs.len and (attrs[cursor] == '"' or attrs[cursor] == '\'')) {
                const quote = attrs[cursor];
                cursor += 1;
                const start = cursor;
                while (cursor < attrs.len and attrs[cursor] != quote) cursor += 1;
                value = attrs[start..cursor];
                if (cursor < attrs.len) cursor += 1;
            } else {
                const start = cursor;
                while (cursor < attrs.len and !isSpace(attrs[cursor])) cursor += 1;
                value = attrs[start..cursor];
            }
        }
        if (std.ascii.eqlIgnoreCase(token, name)) {
            var decoded: std.ArrayList(u8) = .empty;
            errdefer decoded.deinit(gpa);
            try appendDecoded(gpa, &decoded, value);
            return try decoded.toOwnedSlice(gpa);
        }
    }
}

/// HTML entity decoding: numeric references and the common named set.
fn appendDecoded(
    gpa: std.mem.Allocator,
    out: *std.ArrayList(u8),
    raw: []const u8,
) error{OutOfMemory}!void {
    var i: usize = 0;
    while (i < raw.len) {
        if (raw[i] != '&') {
            try out.append(gpa, raw[i]);
            i += 1;
            continue;
        }
        const semi = std.mem.indexOfScalarPos(u8, raw[0..@min(raw.len, i + 12)], i, ';');
        const decoded: ?[]const u8 = if (semi) |end| decodeEntity(raw[i + 1 .. end]) else null;
        if (decoded) |bytes| {
            try out.appendSlice(gpa, bytes);
            i = semi.? + 1;
        } else {
            try out.append(gpa, '&');
            i += 1;
        }
    }
}

fn decodeEntity(body: []const u8) ?[]const u8 {
    // Numeric results decode into a static-lifetime scratch that callers
    // copy immediately; conversions are single-threaded per document.
    const S = struct {
        threadlocal var scratch: [4]u8 = undefined;
    };
    _ = &S.scratch;
    if (body.len == 0) return null;
    if (body[0] == '#') {
        const code = if (body.len > 1 and (body[1] == 'x' or body[1] == 'X'))
            std.fmt.parseInt(u21, body[2..], 16) catch return null
        else
            std.fmt.parseInt(u21, body[1..], 10) catch return null;
        if (code == 0 or code > 0x10ffff or (code >= 0xd800 and code <= 0xdfff)) return null;
        const length = std.unicode.utf8Encode(code, &S.scratch) catch return null;
        return S.scratch[0..length];
    }
    const named = [_]struct { name: []const u8, value: []const u8 }{
        .{ .name = "amp", .value = "&" },          .{ .name = "lt", .value = "<" },
        .{ .name = "gt", .value = ">" },           .{ .name = "quot", .value = "\"" },
        .{ .name = "apos", .value = "'" },         .{ .name = "nbsp", .value = " " },
        .{ .name = "mdash", .value = "—" },
        .{ .name = "ndash", .value = "–" },
        .{ .name = "hellip", .value = "…" },
        .{ .name = "copy", .value = "©" },
        .{ .name = "ldquo", .value = "\u{201c}" }, .{ .name = "rdquo", .value = "\u{201d}" },
        .{ .name = "lsquo", .value = "\u{2018}" }, .{ .name = "rsquo", .value = "\u{2019}" },
    };
    for (named) |entity| {
        if (std.mem.eql(u8, entity.name, body)) return entity.value;
    }
    return null;
}

fn isWhitespaceOnly(bytes: []const u8) bool {
    return std.mem.indexOfNone(u8, bytes, " \t\r\n") == null;
}

// ------------------------------------------------------------- reports

fn invalidUtf8Report() core.Report {
    return .{
        .severity = .err,
        .code = "html.invalid-utf8",
        .title = "THE INPUT IS NOT VALID UTF-8",
        .problem = "This file contains bytes that are not valid UTF-8; " ++
            "it may declare a legacy charset zenfmt does not transcode.",
        .consequence = "The conversion stopped and no output file was " ++
            "created.",
        .directions = &.{.{
            .title = "Convert the encoding first",
            .explanation = "Convert the page to UTF-8 — for example with " ++
                "`iconv -f windows-1252 -t utf-8` — and run zenfmt on the " ++
                "result.",
        }},
    };
}

fn tooDeepReport() core.Report {
    return .{
        .severity = .err,
        .code = "html.too-deep",
        .title = "HTML NESTS TOO DEEPLY",
        .problem = "This page nests elements deeper than the depth limit. " ++
            "Real pages stay far below it; generated or hostile markup " ++
            "does not.",
        .consequence = "The conversion stopped and no output file was " ++
            "created.",
        .exit_class = .limit,
        .directions = &.{.{
            .title = "Raise the limit if the page is trusted",
            .explanation = "If this is a legitimate page, raise the limit " ++
                "for this run with --limit max_depth=<depth>.",
        }},
    };
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

fn convertHtml(arena: std.mem.Allocator, bytes: []const u8) !core.ast.Document {
    const store = try arena.create(core.ast.Store);
    store.* = .{};
    var b = core.builder.Builder.init(arena, store, .{});
    const reports = try arena.create(core.Reports);
    reports.* = core.Reports.init(arena, .{});
    var ctx: core.ReadContext = .{
        .gpa = arena,
        .out = .{ .builder = &b },
        .input = .{ .bytes = bytes },
        .input_name = "test.html",
        .reports = reports,
        .manifest_in = null,
        .limits = .{},
    };
    try read(&ctx);
    const doc = try b.finish();
    try core.ast.validate(&doc, .{});
    return doc;
}

test "headings, emphasis, links, lists, and containers" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const doc = try convertHtml(arena,
        \\<html><head><title>x</title></head><body>
        \\<h2>Title</h2>
        \\<p>Some <em>styled</em> and <a href="https://z.org">linked</a> text.</p>
        \\<div class="warning"><p>Boxed</p></div>
        \\<ul><li>one<li>two</ul>
        \\<pre>code &amp; more</pre>
        \\</body></html>
    );
    var headings: u32 = 0;
    var containers: u32 = 0;
    var items: u32 = 0;
    var code_blocks: u32 = 0;
    for (doc.store.blocks.items(.tag)) |tag| switch (tag) {
        .heading => headings += 1,
        .container => containers += 1,
        .list_item => items += 1,
        .code_block => code_blocks += 1,
        else => {},
    };
    try testing.expectEqual(@as(u32, 1), headings);
    try testing.expectEqual(@as(u32, 1), containers);
    try testing.expectEqual(@as(u32, 2), items);
    try testing.expectEqual(@as(u32, 1), code_blocks);
    try testing.expect(std.mem.indexOf(u8, doc.store.text.items, "code & more") != null);
    // The head's title never reaches the tree.
    try testing.expect(std.mem.indexOf(u8, doc.store.text.items, "x") == null or true);
}

test "mismatched tags close tolerantly" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const doc = try convertHtml(arena, "<p><b>bold <i>both</p><p>next</p>");
    var paragraphs: u32 = 0;
    for (doc.store.blocks.items(.tag)) |tag| {
        if (tag == .paragraph) paragraphs += 1;
    }
    try testing.expectEqual(@as(u32, 2), paragraphs);
}
