//! The ODP reader (anydoc-parity delivery): each slide becomes a heading
//! followed by the text of its frames, mirroring the PPTX conventions.
//! The heading comes from the frame classed `title`, falling back to the
//! slide's `draw:name`. Speaker notes append as a `container` with class
//! `notes`. Character styles resolve through `office:automatic-styles`
//! and `styles.xml` exactly as in the ODT reader.

const std = @import("std");
const assert = std.debug.assert;
const core = @import("zenfmt_core");
const xml = @import("zenfmt_xml");
const ooxml = @import("zenfmt_ooxml");

pub const reader = core.Reader(.{
    .id = "ai.insan.zenfmt.odp",
    .format = "odp",
    .extensions = &.{"odp"},
    .input = .seekable,
    .read = read,
});

const office_ns = "urn:oasis:names:tc:opendocument:xmlns:office:1.0";
const text_ns = "urn:oasis:names:tc:opendocument:xmlns:text:1.0";
const style_ns = "urn:oasis:names:tc:opendocument:xmlns:style:1.0";
const fo_ns = "urn:oasis:names:tc:opendocument:xmlns:xsl-fo-compatible:1.0";
const draw_ns = "urn:oasis:names:tc:opendocument:xmlns:drawing:1.0";
const table_ns = "urn:oasis:names:tc:opendocument:xmlns:table:1.0";
const presentation_ns = "urn:oasis:names:tc:opendocument:xmlns:presentation:1.0";
const svg_ns = "urn:oasis:names:tc:opendocument:xmlns:svg-compatible:1.0";
const xlink_ns = "http://www.w3.org/1999/xlink";

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
            parseStyles(arena, bytes, ctx.limits, &styles) catch {};
        } else |_| {}
    }
    parseStyles(arena, content_bytes, ctx.limits, &styles) catch {};

    try ctx.reports.add(projectionNote());

    var machine: Machine = .{ .ctx = ctx, .arena = arena, .styles = &styles };
    var parser = xml.Parser.init(arena, content_bytes, ctx.limits.max_xml_depth);
    defer parser.deinit();
    machine.parser = &parser;
    try machine.run();
}

// -------------------------------------------------------------- styles

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
    text: std.StringHashMapUnmanaged(TextProps) = .empty,
    ordered_lists: std.StringHashMapUnmanaged(bool) = .empty,
};

fn parseStyles(
    arena: std.mem.Allocator,
    bytes: []const u8,
    limits: core.Limits,
    styles: *Styles,
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
                        std.mem.eql(u8, family, "paragraph") or
                        std.mem.eql(u8, family, "presentation");
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
    page,
    title_frame,
    notes,
    paragraph,
    span,
    link,
    list,
    list_item,
    table,
    header_rows,
    table_row,
    table_cell,
};

const Frame = struct {
    kind: FrameKind,
    block_token: ?core.builder.BlockToken = null,
    inline_token: ?core.builder.InlineToken = null,
    restore_props: TextProps = .{},
    /// Table frames index into `tables`.
    table_index: u32 = 0,
};

const TableState = struct {
    token: core.builder.BlockToken,
    head_token: ?core.builder.BlockToken = null,
    body_token: ?core.builder.BlockToken = null,
    header_phase: bool = false,
};

const Machine = struct {
    ctx: *core.ReadContext,
    arena: std.mem.Allocator,
    styles: *const Styles,
    parser: *xml.Parser = undefined,

    frames: [256]Frame = undefined,
    depth: u32 = 0,
    tables: [16]TableState = undefined,
    table_depth: u32 = 0,

    page_name: []const u8 = "",
    page_heading_done: bool = false,
    in_page: bool = false,
    /// Zero-based slide index of the open page, and the running counter
    /// that assigns it; the surface index of layout facets (ZDS 0013).
    current_slide: u32 = 0,
    slide_counter: u32 = 0,
    /// The most recent `draw:frame` geometry, attached to the next
    /// materialized block; frames without geometry clear it.
    pending_layout: ?core.facets.LayoutData = null,

    in_paragraph: bool = false,
    props: TextProps = .{},
    open_props: TextProps = .{},
    style_tokens: [8]core.builder.InlineToken = undefined,
    style_count: u8 = 0,

    fn run(m: *Machine) core.ReadError!void {
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
                .element_end => try m.popFrame(),
            }
        }
    }

    fn push(m: *Machine, frame: Frame) core.ReadError!void {
        if (m.depth >= m.frames.len) return error.DepthLimitExceeded;
        m.frames[m.depth] = frame;
        m.depth += 1;
    }

    fn inFrame(m: *Machine, kind: FrameKind) bool {
        var i = m.depth;
        while (i > 0) {
            i -= 1;
            if (m.frames[i].kind == kind) return true;
        }
        return false;
    }

    fn onText(m: *Machine, bytes: []const u8) core.ReadError!void {
        if (!m.in_paragraph) return;
        try m.ensureStyles();
        try m.ctx.out.text(bytes);
    }

    fn onElementStart(m: *Machine, element: xml.ElementStart) core.ReadError!void {
        const name = element.name;

        if (name.is(draw_ns, "page")) {
            if (element.self_closing) return;
            m.in_page = true;
            m.page_heading_done = false;
            m.page_name = "";
            m.current_slide = m.slide_counter;
            m.slide_counter += 1;
            m.pending_layout = null;
            for (element.attributes) |attribute| {
                if (attribute.name.is(draw_ns, "name")) {
                    m.page_name = try m.arena.dupe(u8, attribute.value);
                }
            }
            return m.push(.{ .kind = .page });
        }
        if (name.is(draw_ns, "frame")) {
            if (element.self_closing) return;
            var class: []const u8 = "";
            for (element.attributes) |attribute| {
                if (attribute.name.is(presentation_ns, "class")) {
                    class = attribute.value;
                }
            }
            m.pending_layout = frameLayout(element, m.current_slide);
            const is_title = std.mem.eql(u8, class, "title") and !m.page_heading_done;
            return m.push(.{ .kind = if (is_title) .title_frame else .transparent });
        }
        if (name.is(presentation_ns, "notes")) {
            if (element.self_closing) return;
            try m.ensurePageHeading();
            try m.ctx.out.attrs(.{ .classes = &.{"notes"} });
            const token = try m.ctx.out.beginBlock(.container);
            return m.push(.{ .kind = .notes, .block_token = token });
        }
        if (name.is(text_ns, "p") or name.is(text_ns, "h")) {
            return m.onParagraphStart(element);
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
            try m.ensurePageHeading();
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
            try m.takePendingLayout(token);
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
        if (name.is(table_ns, "table")) {
            if (element.self_closing) return;
            return m.onTableStart();
        }
        if (name.is(table_ns, "table-header-rows")) {
            if (element.self_closing) return;
            if (m.currentTable()) |table| table.header_phase = true;
            return m.push(.{ .kind = .header_rows });
        }
        if (name.is(table_ns, "table-row")) {
            return m.onRowStart(element);
        }
        if (name.is(table_ns, "table-cell")) {
            return m.onCellStart(element);
        }
        if (name.is(table_ns, "covered-table-cell")) {
            // Merged continuations fold into their originating cell.
            if (!element.self_closing) {
                m.parser.skipElement() catch return error.Malformed;
            }
            return;
        }
        if (name.is(office_ns, "annotation")) {
            try m.ctx.reports.add(annotationReport());
            if (!element.self_closing) {
                m.parser.skipElement() catch return error.Malformed;
            }
            return;
        }
        if (name.is(office_ns, "automatic-styles") or name.is(office_ns, "styles") or
            name.is(office_ns, "master-styles") or name.is(office_ns, "settings") or
            name.is(office_ns, "scripts") or name.is(office_ns, "meta") or
            name.is(office_ns, "font-face-decls") or
            name.is(presentation_ns, "settings"))
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
            .transparent, .skipped_paragraph_child, .title_frame => {},
            .page => {
                // An empty slide still contributes its name.
                try m.ensurePageHeading();
                m.in_page = false;
            },
            .notes => {
                if (frame.block_token) |token| m.ctx.out.endBlock(token);
            },
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
            .list, .list_item, .table_row, .table_cell => {
                if (frame.block_token) |token| m.ctx.out.endBlock(token);
            },
            .header_rows => {
                if (m.currentTable()) |table| table.header_phase = false;
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

    fn currentTable(m: *Machine) ?*TableState {
        var i = m.depth;
        while (i > 0) {
            i -= 1;
            if (m.frames[i].kind == .table) return &m.tables[m.frames[i].table_index];
        }
        return null;
    }

    /// A table embedded on a slide, ODT-style: streamed, with rows routed
    /// to `table_head` only when the deck declares header rows.
    fn onTableStart(m: *Machine) core.ReadError!void {
        try m.ensurePageHeading();
        var alignments: std.ArrayList(core.payload.Alignment) = .empty;
        defer alignments.deinit(m.arena);
        try alignments.appendNTimes(m.arena, .default, 1);
        const token = try m.ctx.out.beginTable(alignments.items);
        try m.takePendingLayout(token);
        assert(m.table_depth < m.tables.len);
        m.tables[m.table_depth] = .{ .token = token };
        try m.push(.{ .kind = .table, .table_index = m.table_depth });
        m.table_depth += 1;
    }

    fn onRowStart(m: *Machine, element: xml.ElementStart) core.ReadError!void {
        const table = m.currentTable() orelse {
            if (element.self_closing) return;
            return m.push(.{ .kind = .transparent });
        };
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
        // A self-closing row is an empty row: it still occupies the grid.
        if (element.self_closing) {
            m.ctx.out.endBlock(token);
            return;
        }
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
        // A self-closing cell is an empty cell: it still occupies the
        // grid, as in Table_with_Cell_Fill.odp's fill-only 2x2 table.
        if (element.self_closing) {
            const plain = try m.ctx.out.beginPlain();
            m.ctx.out.endBlock(plain);
            m.ctx.out.endBlock(token);
            return;
        }
        try m.push(.{ .kind = .table_cell, .block_token = token });
    }

    fn onParagraphStart(m: *Machine, element: xml.ElementStart) core.ReadError!void {
        if (m.in_paragraph) {
            if (!element.self_closing) try m.push(.{ .kind = .skipped_paragraph_child });
            return;
        }
        var token: core.builder.BlockToken = undefined;
        if (m.inFrame(.title_frame) and !m.page_heading_done) {
            token = try m.ctx.out.beginHeading(2);
            m.page_heading_done = true;
        } else {
            try m.ensurePageHeading();
            token = if (m.inFrame(.list_item))
                try m.ctx.out.beginPlain()
            else
                try m.ctx.out.beginParagraph();
        }
        try m.takePendingLayout(token);
        m.props = .{};
        if (styleAttribute(element.attributes)) |style_name| {
            if (m.styles.text.get(style_name)) |props| m.props = props;
        }
        m.in_paragraph = true;
        if (element.self_closing) {
            m.ctx.out.endBlock(token);
            m.in_paragraph = false;
            return;
        }
        try m.push(.{ .kind = .paragraph, .block_token = token });
    }

    /// Slides without a title frame still get a heading, from `draw:name`.
    fn ensurePageHeading(m: *Machine) core.ReadError!void {
        if (!m.in_page or m.page_heading_done) return;
        m.page_heading_done = true;
        const heading = try m.ctx.out.beginHeading(2);
        try m.ctx.out.text(if (m.page_name.len > 0) m.page_name else "Slide");
        m.ctx.out.endBlock(heading);
    }

    /// Attaches the pending frame geometry to `token`, once per frame.
    fn takePendingLayout(m: *Machine, token: core.builder.BlockToken) core.ReadError!void {
        const layout = m.pending_layout orelse return;
        m.pending_layout = null;
        try m.ctx.out.attachLayout(token, layout);
    }

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

/// The layout facet for a `draw:frame`, from its `svg:x`/`svg:y`/
/// `svg:width`/`svg:height` attributes; null when the frame names no
/// geometry. Lengths convert exactly to EMU (ZDS 0013, One coordinate
/// system); ODF's origin is already top-left.
fn frameLayout(element: xml.ElementStart, slide_index: u32) ?core.facets.LayoutData {
    var layout: core.facets.LayoutData = .{
        .surface = .slide,
        .surface_index = slide_index,
    };
    var seen = false;
    for (element.attributes) |attribute| {
        if (!std.mem.eql(u8, attribute.name.uri, svg_ns)) continue;
        const local = attribute.name.local;
        const emu = lengthToEmu(attribute.value) orelse continue;
        if (std.mem.eql(u8, local, "x")) {
            layout.x = emu;
        } else if (std.mem.eql(u8, local, "y")) {
            layout.y = emu;
        } else if (std.mem.eql(u8, local, "width")) {
            layout.width = @max(0, emu);
        } else if (std.mem.eql(u8, local, "height")) {
            layout.height = @max(0, emu);
        } else {
            continue;
        }
        seen = true;
    }
    return if (seen) layout else null;
}

/// An ODF length like `2.54cm` or `1in` as clamped EMU. The per-unit
/// factors are exact: cm 360000, mm 36000, in 914400, pt 12700, pc 152400,
/// px 9525.
fn lengthToEmu(value: []const u8) ?i32 {
    var digits_end: usize = 0;
    while (digits_end < value.len) : (digits_end += 1) {
        const byte = value[digits_end];
        const numeric = (byte >= '0' and byte <= '9') or byte == '.' or byte == '-' or byte == '+';
        if (!numeric) break;
    }
    if (digits_end == 0) return null;
    const number = std.fmt.parseFloat(f64, value[0..digits_end]) catch return null;
    const unit = value[digits_end..];
    const per_unit: f64 = if (std.mem.eql(u8, unit, "cm"))
        360000
    else if (std.mem.eql(u8, unit, "mm"))
        36000
    else if (std.mem.eql(u8, unit, "in"))
        914400
    else if (std.mem.eql(u8, unit, "pt"))
        12700
    else if (std.mem.eql(u8, unit, "pc"))
        152400
    else if (std.mem.eql(u8, unit, "px"))
        9525
    else
        return null;
    const emu = number * per_unit;
    if (!std.math.isFinite(emu)) return null;
    if (emu >= @as(f64, @floatFromInt(std.math.maxInt(i32)))) return std.math.maxInt(i32);
    if (emu <= @as(f64, @floatFromInt(std.math.minInt(i32)))) return std.math.minInt(i32);
    return @intFromFloat(@round(emu));
}

fn styleAttribute(attributes: []const xml.Attribute) ?[]const u8 {
    for (attributes) |attribute| {
        if (attribute.name.is(text_ns, "style-name")) return attribute.value;
    }
    return null;
}

// ------------------------------------------------------------- reports

fn archiveReport() core.Report {
    return .{
        .severity = .err,
        .code = "odp.not-an-archive",
        .title = "NOT A READABLE ODP ARCHIVE",
        .problem = "This file is not a ZIP archive zenfmt can read, or it " ++
            "trips an archive safety limit.",
        .consequence = "The conversion stopped and no output file was " ++
            "created.",
        .directions = &.{.{
            .title = "Check the file",
            .explanation = "Open the file in LibreOffice to verify it is " ++
                "intact, and check the detected format.",
        }},
    };
}

fn missingContentReport() core.Report {
    return .{
        .severity = .err,
        .code = "odp.missing-content",
        .title = "THE CONTENT PART IS MISSING",
        .problem = "The archive opens but contains no content.xml, so it " ++
            "is not an OpenDocument presentation.",
        .consequence = "The conversion stopped and no output file was " ++
            "created.",
        .directions = &.{.{
            .title = "Re-export the file",
            .explanation = "Re-save the presentation from LibreOffice or " ++
                "its producing application and convert the fresh copy.",
        }},
    };
}

fn malformedReport() core.Report {
    return .{
        .severity = .err,
        .code = "odp.malformed-xml",
        .title = "MALFORMED XML INSIDE THE PRESENTATION",
        .problem = "A part inside this presentation is not well-formed " ++
            "XML, or nests beyond the safety limit.",
        .consequence = "The conversion stopped and no output file was " ++
            "created.",
        .directions = &.{.{
            .title = "Re-export the file",
            .explanation = "Open the presentation in LibreOffice; if it " ++
                "opens, re-save it and convert the fresh copy.",
        }},
    };
}

fn annotationReport() core.Report {
    return .{
        .severity = .warning,
        .code = "odp.annotations-dropped",
        .title = "ANNOTATIONS DROPPED",
        .problem = "This presentation contains annotations (comments), " ++
            "and comments have no place in the shared document tree.",
        .consequence = "The annotations are absent from the output.",
        .loss = .dropped,
        .directions = &.{.{
            .title = "Keep the source",
            .explanation = "Keep the source ODP if the annotations " ++
                "matter; they exist only there.",
        }},
    };
}

fn projectionNote() core.Report {
    return .{
        .severity = .warning,
        .code = "odp.presentation-projection",
        .title = "A PRESENTATION LOSES THE MOST",
        .problem = "A slide deck is a spatial, animated medium, and this " ++
            "projection keeps only its text: titles, body text, and " ++
            "speaker notes.",
        .consequence = "Positioning, animation, transitions, images, " ++
            "charts, and non-text shapes are absent from the output.",
        .loss = .dropped,
        .directions = &.{.{
            .title = "Keep the source",
            .explanation = "Keep the source ODP; the visual design " ++
                "exists only there. Run with --strict to stop instead of " ++
                "converting with these losses.",
        }},
    };
}
