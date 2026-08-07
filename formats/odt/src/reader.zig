//! The ODT reader (ZDS 0002, The other formats): the same container and
//! XML machinery as DOCX. `text:h` carries its level in
//! `text:outline-level`, easier than DOCX. Character styles are the hard
//! part: `text:span` names a style resolved through
//! `office:automatic-styles` and `styles.xml`, following
//! `style:parent-style-name` chains, to learn whether `fo:font-weight` is
//! bold. Lists are explicit, which removes the DOCX inference problem
//! entirely.

const std = @import("std");
const assert = std.debug.assert;
const core = @import("zenfmt_core");
const xml = @import("zenfmt_xml");
const ooxml = @import("zenfmt_ooxml");

pub const reader = core.Reader(.{
    .id = "ai.insan.zenfmt.odt",
    .format = "odt",
    .extensions = &.{"odt"},
    .input = .seekable,
    .read = read,
});

const text_ns = "urn:oasis:names:tc:opendocument:xmlns:text:1.0";
const office_ns = "urn:oasis:names:tc:opendocument:xmlns:office:1.0";
const style_ns = "urn:oasis:names:tc:opendocument:xmlns:style:1.0";
const fo_ns = "urn:oasis:names:tc:opendocument:xmlns:xsl-fo-compatible:1.0";
const table_ns = "urn:oasis:names:tc:opendocument:xmlns:table:1.0";
const xlink_ns = "http://www.w3.org/1999/xlink";
const draw_ns = "urn:oasis:names:tc:opendocument:xmlns:drawing:1.0";
const svg_ns = "urn:oasis:names:tc:opendocument:xmlns:svg-compatible:1.0";
const dc_ns = "http://purl.org/dc/elements/1.1/";

/// A comment's captured text is bounded: the facet is a marker, not a
/// second document.
const max_annotation_note_bytes = 256;

const TextProps = struct {
    strong: bool = false,
    emphasis: bool = false,
    strike: bool = false,
    superscript: bool = false,
    subscript: bool = false,
    small_caps: bool = false,
    underline: bool = false,

    fn eql(a: TextProps, b: TextProps) bool {
        return std.meta.eql(a, b);
    }

    fn any(props: TextProps) bool {
        return !props.eql(.{});
    }
};

const Styles = struct {
    /// Style name to resolved text properties, chains flattened.
    text: std.StringHashMapUnmanaged(TextProps) = .empty,
    /// List style name to "level 1 is numbered".
    ordered_lists: std.StringHashMapUnmanaged(bool) = .empty,
    /// Names declared in styles.xml: the document's common styles, the
    /// honest ones to surface as `StyleFacet` rows (ZDS 0013). Automatic
    /// "P1"-style names resolve through `parents` to one of these.
    common: std.StringHashMapUnmanaged(void) = .empty,
    /// Style name to parent style name, for automatic-style resolution.
    parents: std.StringHashMapUnmanaged([]const u8) = .empty,

    /// The nearest common ancestor of `name`, when one exists: the facet
    /// carries a name a person chose, never a generator's counter.
    fn commonName(styles: *const Styles, name: []const u8) ?[]const u8 {
        if (styles.common.contains(name)) return name;
        var current = name;
        var hops: u8 = 0;
        while (hops < 8) : (hops += 1) {
            current = styles.parents.get(current) orelse return null;
            if (styles.common.contains(current)) return current;
        }
        return null;
    }
};

pub fn read(ctx: *core.ReadContext) core.ReadError!void {
    const arena = ctx.gpa;
    var archive = ooxml.zip.Archive.openSource(arena, ooxml.zipSource(ctx), ctx.limits) catch |err| {
        try ctx.reports.add(archiveReport());
        return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.LimitExceeded => error.LimitExceeded,
            else => error.Malformed,
        };
    };

    const content_entry = archive.find("content.xml") orelse {
        try ctx.reports.add(missingContentReport());
        return error.Malformed;
    };
    const content_bytes = archive.extract(arena, content_entry, ctx.limits) catch |err| {
        try ctx.reports.add(archiveReport());
        return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.LimitExceeded => error.LimitExceeded,
            else => error.Malformed,
        };
    };

    var styles: Styles = .{};
    if (archive.find("styles.xml")) |entry| {
        if (archive.extract(arena, entry, ctx.limits)) |bytes| {
            parseStyles(arena, bytes, ctx.limits, &styles, true) catch {};
        } else |_| {}
    }
    // Automatic styles live in content.xml itself and win on collision.
    parseStyles(arena, content_bytes, ctx.limits, &styles, false) catch {};

    var machine: Machine = .{
        .ctx = ctx,
        .arena = arena,
        .styles = &styles,
        .archive = &archive,
    };
    defer machine.deinit();

    {
        var parser = xml.Parser.init(arena, content_bytes, ctx.limits.max_xml_depth);
        defer parser.deinit();
        machine.parser = &parser;
        machine.source = content_bytes;
        try machine.run(0);
    }
    try machine.emitNoteBodies(content_bytes);
}

// -------------------------------------------------------------- styles

fn parseStyles(
    arena: std.mem.Allocator,
    bytes: []const u8,
    limits: core.Limits,
    styles: *Styles,
    common: bool,
) !void {
    var parser = xml.Parser.init(arena, bytes, limits.max_xml_depth);
    defer parser.deinit();

    const Raw = struct {
        name: []const u8,
        parent: []const u8,
        props: TextProps,
    };
    var raw: std.ArrayList(Raw) = .empty;
    defer raw.deinit(arena);

    var current: ?Raw = null;
    var list_style_name: []const u8 = "";
    var list_level_one_seen = false;
    while (true) {
        switch (try parser.next()) {
            .done => break,
            .element_start => |element| {
                if (element.name.is(style_ns, "style")) {
                    if (current) |value| try raw.append(arena, value);
                    var name: []const u8 = "";
                    var parent: []const u8 = "";
                    var family: []const u8 = "";
                    for (element.attributes) |attribute| {
                        if (attribute.name.is(style_ns, "name")) {
                            name = try arena.dupe(u8, attribute.value);
                        } else if (attribute.name.is(style_ns, "parent-style-name")) {
                            parent = try arena.dupe(u8, attribute.value);
                        } else if (attribute.name.is(style_ns, "family")) {
                            family = attribute.value;
                        }
                    }
                    const relevant = std.mem.eql(u8, family, "text") or
                        std.mem.eql(u8, family, "paragraph");
                    if (relevant and name.len > 0) {
                        if (common) try styles.common.put(arena, name, {});
                        if (parent.len > 0) try styles.parents.put(arena, name, parent);
                    }
                    current = if (relevant and !element.self_closing)
                        .{ .name = name, .parent = parent, .props = .{} }
                    else
                        null;
                } else if (element.name.is(style_ns, "text-properties")) {
                    if (current) |*value| {
                        for (element.attributes) |attribute| {
                            applyTextProperty(&value.props, attribute);
                        }
                    }
                } else if (element.name.is(text_ns, "list-style")) {
                    for (element.attributes) |attribute| {
                        if (attribute.name.is(style_ns, "name")) {
                            list_style_name = try arena.dupe(u8, attribute.value);
                            list_level_one_seen = false;
                        }
                    }
                } else if (element.name.is(text_ns, "list-level-style-number")) {
                    if (list_style_name.len > 0 and !list_level_one_seen) {
                        list_level_one_seen = true;
                        try styles.ordered_lists.put(arena, list_style_name, true);
                    }
                } else if (element.name.is(text_ns, "list-level-style-bullet")) {
                    if (list_style_name.len > 0 and !list_level_one_seen) {
                        list_level_one_seen = true;
                        try styles.ordered_lists.put(arena, list_style_name, false);
                    }
                }
            },
            .element_end => |name| {
                if (std.mem.eql(u8, name.local, "style")) {
                    if (current) |value| try raw.append(arena, value);
                    current = null;
                }
            },
            .text => {},
        }
    }
    if (current) |value| try raw.append(arena, value);

    // Flatten parent chains, bounded.
    for (raw.items) |style| {
        var props = style.props;
        var parent = style.parent;
        var hops: u32 = 0;
        while (parent.len > 0 and hops < 16) : (hops += 1) {
            const found = for (raw.items) |candidate| {
                if (std.mem.eql(u8, candidate.name, parent)) break candidate;
            } else break;
            mergeProps(&props, found.props);
            parent = found.parent;
        }
        if (props.any()) {
            try styles.text.put(arena, style.name, props);
        }
    }
}

fn applyTextProperty(props: *TextProps, attribute: xml.Attribute) void {
    if (attribute.name.is(fo_ns, "font-weight")) {
        props.strong = std.mem.eql(u8, attribute.value, "bold") or
            (attribute.value.len == 3 and std.mem.order(u8, attribute.value, "600") != .lt);
    } else if (attribute.name.is(fo_ns, "font-style")) {
        props.emphasis = std.mem.eql(u8, attribute.value, "italic") or
            std.mem.eql(u8, attribute.value, "oblique");
    } else if (attribute.name.is(style_ns, "text-underline-style")) {
        props.underline = !std.mem.eql(u8, attribute.value, "none");
    } else if (attribute.name.is(style_ns, "text-line-through-style")) {
        props.strike = !std.mem.eql(u8, attribute.value, "none");
    } else if (attribute.name.is(fo_ns, "font-variant")) {
        props.small_caps = std.mem.eql(u8, attribute.value, "small-caps");
    } else if (attribute.name.is(style_ns, "text-position")) {
        props.superscript = std.mem.startsWith(u8, attribute.value, "super");
        props.subscript = std.mem.startsWith(u8, attribute.value, "sub");
    }
}

fn mergeProps(into: *TextProps, from: TextProps) void {
    into.strong = into.strong or from.strong;
    into.emphasis = into.emphasis or from.emphasis;
    into.strike = into.strike or from.strike;
    into.superscript = into.superscript or from.superscript;
    into.subscript = into.subscript or from.subscript;
    into.small_caps = into.small_caps or from.small_caps;
    into.underline = into.underline or from.underline;
}

// -------------------------------------------------------------- machine

const FrameKind = enum {
    transparent,
    skipped_paragraph_child,
    paragraph,
    span,
    link,
    list,
    list_item,
    table,
    table_row,
    table_cell,
    section,
    draw_frame,
    image_desc,
    image_title,
};

const Frame = struct {
    kind: FrameKind,
    block_token: ?core.builder.BlockToken = null,
    inline_token: ?core.builder.InlineToken = null,
    /// For spans: the properties the span layered on.
    restore_props: TextProps = .{},
    /// For tables: state index.
    table_index: u32 = 0,
};

const TableState = struct {
    token: core.builder.BlockToken,
    head_token: ?core.builder.BlockToken = null,
    body_token: ?core.builder.BlockToken = null,
    header_phase: bool = false,
};

const PendingNote = struct {
    note: u32,
    /// Byte range of the note body's children within `content.xml`.
    body: []const u8,
};

const PendingImage = struct {
    href: []const u8 = "",
    frame_name: []const u8 = "",
    desc: std.ArrayList(u8) = .empty,
    title: std.ArrayList(u8) = .empty,
};

const Machine = struct {
    ctx: *core.ReadContext,
    arena: std.mem.Allocator,
    styles: *const Styles,
    parser: *xml.Parser = undefined,
    source: []const u8 = "",

    frames: [256]Frame = undefined,
    depth: u32 = 0,
    tables: [16]TableState = undefined,
    table_depth: u32 = 0,

    in_paragraph: bool = false,
    /// Current effective character properties (paragraph style + spans).
    props: TextProps = .{},
    open_props: TextProps = .{},
    style_tokens: [8]core.builder.InlineToken = undefined,
    style_count: u8 = 0,

    notes: std.ArrayList(PendingNote) = .empty,
    image: ?PendingImage = null,

    // Facet state (ZDS 0013): the archive for media extraction, and an
    // annotation met between paragraphs, held for the next one.
    archive: ?*ooxml.zip.Archive = null,
    pending_comment: ?PendingComment = null,

    const PendingComment = struct {
        author: []const u8,
        timestamp: []const u8,
        note: []const u8,
    };

    fn deinit(m: *Machine) void {
        m.notes.deinit(m.arena);
    }

    /// The open paragraph's block token, for facet attachment; null
    /// between paragraphs.
    fn currentParagraphToken(m: *Machine) ?core.builder.BlockToken {
        var i = m.depth;
        while (i > 0) {
            i -= 1;
            if (m.frames[i].kind == .paragraph) return m.frames[i].block_token;
        }
        return null;
    }

    fn run(m: *Machine, stop_depth: u32) core.ReadError!void {
        while (true) {
            const event = m.parser.next() catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.DoctypeRefused, error.Malformed => {
                    try m.ctx.reports.add(malformedReport());
                    return error.Malformed;
                },
                error.DepthLimitExceeded => {
                    try m.ctx.reports.add(malformedReport());
                    return error.LimitExceeded;
                },
            };
            switch (event) {
                .done => return,
                .text => |bytes| try m.onText(bytes),
                .element_start => |element| try m.onElementStart(element),
                .element_end => {
                    try m.popFrame();
                    if (m.parser.depth <= stop_depth) return;
                },
            }
            if (m.parser.depth < stop_depth) return;
        }
    }

    fn push(m: *Machine, frame: Frame) core.ReadError!void {
        if (m.depth >= m.frames.len) return error.DepthLimitExceeded;
        m.frames[m.depth] = frame;
        m.depth += 1;
    }

    fn onText(m: *Machine, bytes: []const u8) core.ReadError!void {
        if (m.depth > 0) {
            const kind = m.frames[m.depth - 1].kind;
            if (kind == .image_desc or kind == .image_title) {
                if (m.image) |*image| {
                    const buffer = if (kind == .image_desc) &image.desc else &image.title;
                    try buffer.appendSlice(m.arena, bytes);
                }
                return;
            }
        }
        if (!m.in_paragraph) return;
        try m.ensureStyles();
        try m.ctx.out.text(bytes);
    }

    fn onElementStart(m: *Machine, element: xml.ElementStart) core.ReadError!void {
        const name = element.name;

        if (name.is(text_ns, "h") or name.is(text_ns, "p")) {
            return m.onParagraphStart(element, name.is(text_ns, "h"));
        }
        if (name.is(text_ns, "span")) {
            if (element.self_closing) return;
            const saved = m.props;
            if (styleAttribute(element.attributes)) |style_name| {
                if (m.styles.text.get(style_name)) |props| {
                    mergeProps(&m.props, props);
                }
            }
            return m.push(.{ .kind = .span, .restore_props = saved });
        }
        if (name.is(text_ns, "a")) {
            if (element.self_closing) return;
            if (!m.in_paragraph) return m.push(.{ .kind = .transparent });
            var target: []const u8 = "";
            for (element.attributes) |attribute| {
                if (attribute.name.is(xlink_ns, "href")) {
                    target = try m.arena.dupe(u8, attribute.value);
                }
            }
            try m.closeStyles();
            const token = try m.ctx.out.beginLink(target, "");
            return m.push(.{ .kind = .link, .inline_token = token });
        }
        if (name.is(text_ns, "list")) {
            if (element.self_closing) return;
            var ordered = false;
            if (styleAttribute(element.attributes)) |style_name| {
                ordered = m.styles.ordered_lists.get(style_name) orelse false;
            }
            const token = try m.ctx.out.beginList(.{
                .kind = if (ordered) .ordered else .unordered,
                .start = 1,
                .style = .decimal,
                .delimiter = .period,
            });
            return m.push(.{ .kind = .list, .block_token = token });
        }
        if (name.is(text_ns, "list-item") or name.is(text_ns, "list-header")) {
            if (element.self_closing) return;
            const token = try m.ctx.out.beginBlock(.list_item);
            return m.push(.{ .kind = .list_item, .block_token = token });
        }
        if (name.is(text_ns, "s") or name.is(text_ns, "tab")) {
            if (m.in_paragraph) try m.ctx.out.text(" ");
            if (!element.self_closing) try m.push(.{ .kind = .transparent });
            return;
        }
        if (name.is(text_ns, "line-break")) {
            if (m.in_paragraph) try m.ctx.out.hardBreak();
            if (!element.self_closing) try m.push(.{ .kind = .transparent });
            return;
        }
        if (name.is(text_ns, "note")) {
            if (element.self_closing) return;
            return m.onNoteStart();
        }
        if (name.is(text_ns, "section")) {
            if (element.self_closing) return;
            if (m.in_paragraph) return m.push(.{ .kind = .transparent });
            try m.ctx.out.attrs(.{ .classes = &.{"section"} });
            const token = try m.ctx.out.beginBlock(.container);
            return m.push(.{ .kind = .section, .block_token = token });
        }
        if (name.is(draw_ns, "frame")) {
            if (element.self_closing) return;
            // A frame inside a frame (an image inside a text box) keeps
            // the outer capture; the inner one flows as regular content.
            if (m.image != null) return m.push(.{ .kind = .transparent });
            var frame_name: []const u8 = "";
            for (element.attributes) |attribute| {
                if (attribute.name.is(draw_ns, "name")) {
                    frame_name = try m.arena.dupe(u8, attribute.value);
                }
            }
            m.image = .{ .frame_name = frame_name };
            return m.push(.{ .kind = .draw_frame });
        }
        if (name.is(draw_ns, "image")) {
            if (m.image) |*image| {
                for (element.attributes) |attribute| {
                    if (attribute.name.is(xlink_ns, "href")) {
                        image.href = try m.arena.dupe(u8, attribute.value);
                    }
                }
            }
            // The subtree may hold base64 binary data; never let it leak
            // into the document text.
            if (!element.self_closing) {
                m.parser.skipElement() catch return error.Malformed;
            }
            return;
        }
        if (name.is(svg_ns, "desc") or name.is(svg_ns, "title")) {
            if (element.self_closing) return;
            if (m.image != null) {
                const kind: FrameKind = if (name.is(svg_ns, "desc")) .image_desc else .image_title;
                return m.push(.{ .kind = kind });
            }
            return m.push(.{ .kind = .transparent });
        }
        if (name.is(table_ns, "table")) {
            if (element.self_closing) return;
            return m.onTableStart();
        }
        if (name.is(table_ns, "table-header-rows")) {
            if (element.self_closing) return;
            if (m.currentTable()) |table| table.header_phase = true;
            return m.push(.{ .kind = .transparent });
        }
        if (name.is(table_ns, "table-row")) {
            if (element.self_closing) return;
            return m.onRowStart();
        }
        if (name.is(table_ns, "table-cell")) {
            if (element.self_closing) return;
            return m.onCellStart(element);
        }
        if (name.is(table_ns, "covered-table-cell")) {
            if (!element.self_closing) {
                m.parser.skipElement() catch return error.Malformed;
            }
            return;
        }
        if (name.is(office_ns, "annotation")) {
            // Comments: dropped from the flow, counted through
            // aggregation, and carried as a `RevisionFacet` (ZDS 0013).
            try m.ctx.reports.add(annotationReport());
            if (element.self_closing) return;
            try m.onAnnotation();
            return;
        }
        if (name.is(text_ns, "tracked-changes") or name.is(office_ns, "forms") or
            name.is(text_ns, "sequence-decls") or name.is(office_ns, "font-face-decls") or
            name.is(office_ns, "automatic-styles") or name.is(office_ns, "styles") or
            name.is(office_ns, "master-styles") or name.is(office_ns, "settings") or
            name.is(office_ns, "scripts") or name.is(office_ns, "meta"))
        {
            if (!element.self_closing) {
                m.parser.skipElement() catch return error.Malformed;
            }
            return;
        }

        if (element.self_closing) return;
        try m.push(.{ .kind = .transparent });
    }

    fn popFrame(m: *Machine) core.ReadError!void {
        if (m.depth == 0) return;
        const frame = &m.frames[m.depth - 1];
        switch (frame.kind) {
            .transparent, .skipped_paragraph_child, .image_desc, .image_title => {},
            .section => {
                if (frame.block_token) |token| m.ctx.out.endBlock(token);
            },
            .draw_frame => try m.emitImage(),
            .paragraph => {
                try m.closeStyles();
                m.props = .{};
                if (frame.block_token) |token| m.ctx.out.endBlock(token);
                m.in_paragraph = false;
            },
            .span => {
                m.props = frame.restore_props;
            },
            .link => {
                try m.closeStyles();
                if (frame.inline_token) |token| m.ctx.out.endInline(token);
            },
            .list, .list_item, .table_row => {
                if (frame.block_token) |token| m.ctx.out.endBlock(token);
            },
            .table_cell => {
                if (frame.block_token) |token| m.ctx.out.endBlock(token);
            },
            .table => {
                const table = &m.tables[frame.table_index];
                if (table.head_token) |token| m.ctx.out.endBlock(token);
                if (table.body_token) |token| m.ctx.out.endBlock(token);
                m.ctx.out.endBlock(table.token);
                m.table_depth -= 1;
            },
        }
        m.depth -= 1;
    }

    fn onParagraphStart(m: *Machine, element: xml.ElementStart, is_heading: bool) core.ReadError!void {
        if (m.in_paragraph) {
            // A paragraph inside a paragraph-level construct the reader
            // looked through: treat as content of the open one.
            if (!element.self_closing) try m.push(.{ .kind = .skipped_paragraph_child });
            return;
        }
        var token: core.builder.BlockToken = undefined;
        if (is_heading) {
            var level: u8 = 1;
            for (element.attributes) |attribute| {
                if (attribute.name.is(text_ns, "outline-level")) {
                    level = std.fmt.parseInt(u8, attribute.value, 10) catch 1;
                }
            }
            token = try m.ctx.out.beginHeading(@min(@max(level, 1), 6));
        } else if (m.inListItem()) {
            token = try m.ctx.out.beginPlain();
        } else {
            token = try m.ctx.out.beginParagraph();
        }
        // The paragraph style contributes character properties too; a
        // common style name additionally rides as a `StyleFacet`.
        m.props = .{};
        if (styleAttribute(element.attributes)) |style_name| {
            if (m.styles.text.get(style_name)) |props| m.props = props;
            if (m.styles.commonName(style_name)) |common| {
                try m.ctx.out.attachStyle(token, .{ .name = common });
            }
        }
        if (m.pending_comment) |comment| {
            m.pending_comment = null;
            try m.ctx.out.attachRevision(token, .{
                .kind = .comment,
                .author = comment.author,
                .timestamp = comment.timestamp,
                .note = comment.note,
            });
        }
        m.in_paragraph = true;
        if (element.self_closing) {
            m.ctx.out.endBlock(token);
            m.in_paragraph = false;
            return;
        }
        try m.push(.{ .kind = .paragraph, .block_token = token });
    }

    fn inListItem(m: *Machine) bool {
        var i = m.depth;
        while (i > 0) {
            i -= 1;
            switch (m.frames[i].kind) {
                .list_item => return true,
                .table_cell => return false,
                else => {},
            }
        }
        return false;
    }

    fn currentTable(m: *Machine) ?*TableState {
        var i = m.depth;
        while (i > 0) {
            i -= 1;
            if (m.frames[i].kind == .table) return &m.tables[m.frames[i].table_index];
        }
        return null;
    }

    fn onTableStart(m: *Machine) core.ReadError!void {
        // Column count arrives as table:table-column elements before rows;
        // GFM alignment is unknown, so a generous default set suffices.
        var alignments: std.ArrayList(core.payload.Alignment) = .empty;
        defer alignments.deinit(m.arena);
        try alignments.appendNTimes(m.arena, .default, 1);
        const token = try m.ctx.out.beginTable(alignments.items);
        assert(m.table_depth < m.tables.len);
        m.tables[m.table_depth] = .{ .token = token };
        try m.push(.{ .kind = .table, .table_index = m.table_depth });
        m.table_depth += 1;
    }

    fn onRowStart(m: *Machine) core.ReadError!void {
        const table = m.currentTable() orelse return m.push(.{ .kind = .transparent });
        if (table.header_phase and table.body_token == null) {
            if (table.head_token == null) {
                table.head_token = try m.ctx.out.beginBlock(.table_head);
            }
        } else {
            if (table.head_token) |token| {
                m.ctx.out.endBlock(token);
                table.head_token = null;
            }
            if (table.body_token == null) {
                table.body_token = try m.ctx.out.beginTableBody(.{
                    .row_head_columns = 0,
                    .head_rows = 0,
                });
            }
        }
        const token = try m.ctx.out.beginBlock(.table_row);
        try m.push(.{ .kind = .table_row, .block_token = token });
    }

    fn onCellStart(m: *Machine, element: xml.ElementStart) core.ReadError!void {
        var col_span: u32 = 1;
        for (element.attributes) |attribute| {
            if (attribute.name.is(table_ns, "number-columns-spanned")) {
                col_span = std.fmt.parseInt(u32, attribute.value, 10) catch 1;
            }
        }
        const token = try m.ctx.out.beginTableCell(.{
            .alignment = .default,
            .row_span = 1,
            .col_span = col_span,
        });
        try m.push(.{ .kind = .table_cell, .block_token = token });
    }

    /// The end of a `draw:frame`: everything the frame carried is known,
    /// so the image reference can be emitted where the frame sat.
    fn emitImage(m: *Machine) core.ReadError!void {
        const image = m.image orelse return;
        m.image = null;
        const alt = if (image.desc.items.len > 0)
            image.desc.items
        else if (image.title.items.len > 0)
            image.title.items
        else
            image.frame_name;
        if (image.href.len == 0 and alt.len == 0) {
            try m.ctx.reports.add(frameDroppedReport());
            return;
        }
        if (m.in_paragraph) {
            try m.ensureStyles();
            const token = try m.ctx.out.beginImage(image.href, "");
            if (alt.len > 0) try m.ctx.out.text(alt);
            m.ctx.out.endInline(token);
            try m.registerImage(image.href);
            return;
        }
        const paragraph = try m.ctx.out.beginParagraph();
        const token = try m.ctx.out.beginImage(image.href, "");
        if (alt.len > 0) try m.ctx.out.text(alt);
        m.ctx.out.endInline(token);
        m.ctx.out.endBlock(paragraph);
        try m.registerImage(image.href);
    }

    /// Consumes an `office:annotation` subtree, harvesting the creator,
    /// date, and a bounded slice of the comment text into a
    /// `RevisionFacet` on the containing paragraph, or on the next one
    /// when the comment sits between paragraphs.
    fn onAnnotation(m: *Machine) core.ReadError!void {
        const target = m.parser.depth;
        var author: []const u8 = "";
        var timestamp: []const u8 = "";
        var note: std.ArrayList(u8) = .empty;
        defer note.deinit(m.arena);
        var capture: enum { none, creator, date, body } = .none;
        while (m.parser.depth >= target) {
            const event = m.parser.next() catch return error.Malformed;
            switch (event) {
                .done => break,
                .element_start => |child| {
                    if (child.name.is(dc_ns, "creator")) {
                        capture = .creator;
                    } else if (child.name.is(dc_ns, "date")) {
                        capture = .date;
                    } else if (child.name.is(text_ns, "p")) {
                        capture = .body;
                    }
                },
                .element_end => capture = .none,
                .text => |bytes| switch (capture) {
                    .none => {},
                    .creator => author = try m.arena.dupe(u8, bytes),
                    .date => timestamp = try m.arena.dupe(u8, bytes),
                    .body => {
                        const room = max_annotation_note_bytes -| note.items.len;
                        const take = @min(room, bytes.len);
                        try note.appendSlice(m.arena, bytes[0..take]);
                    },
                },
            }
        }

        const data: core.facets.RevisionData = .{
            .kind = .comment,
            .author = author,
            .timestamp = timestamp,
            .note = note.items,
        };
        if (m.currentParagraphToken()) |token| {
            try m.ctx.out.attachRevision(token, data);
            return;
        }
        if (m.pending_comment == null) {
            m.pending_comment = .{
                .author = author,
                .timestamp = timestamp,
                .note = try m.arena.dupe(u8, note.items),
            };
        }
    }

    /// Extracts an internal image part and registers it with the resource
    /// store under the same source name the `image` node carries. External
    /// references and broken parts keep the old behavior; a part past the
    /// resource limits degrades to a counted note.
    fn registerImage(m: *Machine, source: []const u8) core.ReadError!void {
        if (source.len == 0) return;
        if (std.mem.indexOfScalar(u8, source, ':') != null) return;
        const archive = m.archive orelse return;
        const lookup = if (std.mem.startsWith(u8, source, "./")) source[2..] else source;
        const entry = archive.find(lookup) orelse return;
        const bytes = archive.extract(m.arena, entry, m.ctx.limits) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.LimitExceeded => {
                try m.ctx.reports.add(mediaLimitNote());
                return;
            },
            else => return,
        };
        if (bytes.len == 0) return;
        _ = m.ctx.out.resource(source, bytes, imageMime(lookup)) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.DepthLimitExceeded => return error.DepthLimitExceeded,
            error.LimitExceeded => {
                try m.ctx.reports.add(mediaLimitNote());
                return;
            },
        };
    }

    /// A footnote sits inline in `content.xml`; its body is captured as a
    /// byte range and re-parsed after the document body, where note bodies
    /// belong.
    fn onNoteStart(m: *Machine) core.ReadError!void {
        const note = try m.ctx.out.declareNote();
        if (m.in_paragraph) try m.ctx.out.noteReference(note);

        // Consume the note subtree, capturing the body's byte range.
        const target = m.parser.depth;
        var body: []const u8 = "";
        while (m.parser.depth >= target) {
            const event = m.parser.next() catch return error.Malformed;
            switch (event) {
                .done => break,
                .element_start => |child| {
                    if (child.name.is(text_ns, "note-body") and !child.self_closing) {
                        const start = m.parser.pos;
                        m.parser.skipElement() catch return error.Malformed;
                        // The captured range ends before `</text:note-body>`.
                        const close = std.mem.lastIndexOf(
                            u8,
                            m.source[start..m.parser.pos],
                            "</",
                        ) orelse 0;
                        body = m.source[start .. start + close];
                    } else if (!child.self_closing) {
                        m.parser.skipElement() catch return error.Malformed;
                    }
                },
                else => {},
            }
        }
        try m.notes.append(m.arena, .{ .note = note, .body = body });
    }

    /// Note bodies re-parse wrapped in an element that re-binds the ODF
    /// prefixes the fragment references.
    fn emitNoteBodies(m: *Machine, source: []const u8) core.ReadError!void {
        _ = source;
        for (m.notes.items) |pending| {
            m.ctx.out.beginNoteBody(pending.note);
            if (pending.body.len > 0) {
                const wrapped = try std.fmt.allocPrint(
                    m.arena,
                    "<office:wrap xmlns:office=\"{s}\" xmlns:text=\"{s}\" " ++
                        "xmlns:style=\"{s}\" xmlns:fo=\"{s}\" " ++
                        "xmlns:table=\"{s}\" xmlns:xlink=\"{s}\" " ++
                        "xmlns:draw=\"{s}\" xmlns:svg=\"{s}\">{s}</office:wrap>",
                    .{
                        office_ns,    text_ns,  style_ns, fo_ns,
                        table_ns,     xlink_ns, draw_ns,  svg_ns,
                        pending.body,
                    },
                );
                var parser = xml.Parser.init(m.arena, wrapped, m.ctx.limits.max_xml_depth);
                defer parser.deinit();
                m.parser = &parser;
                m.source = wrapped;
                m.run(0) catch {};
                // A malformed fragment leaves an empty note body rather
                // than failing the whole conversion.
                try m.closeStyles();
                if (m.in_paragraph) m.in_paragraph = false;
            }
            m.ctx.out.endNoteBody(pending.note);
        }
    }

    // ------------------------------------------------------------ styles

    fn ensureStyles(m: *Machine) core.ReadError!void {
        if (m.props.eql(m.open_props)) return;
        try m.closeStyles();
        m.open_props = m.props;
        const order = [_]struct { on: bool, tag: core.InlineTag }{
            .{ .on = m.props.strong, .tag = .strong },
            .{ .on = m.props.emphasis, .tag = .emphasis },
            .{ .on = m.props.strike, .tag = .strikethrough },
            .{ .on = m.props.superscript, .tag = .superscript },
            .{ .on = m.props.subscript, .tag = .subscript },
            .{ .on = m.props.small_caps, .tag = .small_caps },
            .{ .on = m.props.underline, .tag = .underline },
        };
        for (order) |entry| {
            if (!entry.on) continue;
            assert(m.style_count < m.style_tokens.len);
            m.style_tokens[m.style_count] = try m.ctx.out.beginInline(entry.tag);
            m.style_count += 1;
        }
    }

    fn closeStyles(m: *Machine) core.ReadError!void {
        while (m.style_count > 0) {
            m.style_count -= 1;
            m.ctx.out.endInline(m.style_tokens[m.style_count]);
        }
        m.open_props = .{};
    }
};

fn styleAttribute(attributes: []const xml.Attribute) ?[]const u8 {
    for (attributes) |attribute| {
        if (attribute.name.is(text_ns, "style-name")) return attribute.value;
    }
    return null;
}

// The report constructors and media helpers live in `reports.zig`
// (file-size rule).
const reports_mod = @import("reports.zig");
const archiveReport = reports_mod.archiveReport;
const missingContentReport = reports_mod.missingContentReport;
const malformedReport = reports_mod.malformedReport;
const imageMime = reports_mod.imageMime;
const mediaLimitNote = reports_mod.mediaLimitNote;
const annotationReport = reports_mod.annotationReport;
const frameDroppedReport = reports_mod.frameDroppedReport;
