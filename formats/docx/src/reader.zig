//! The DOCX reader (ZDS 0002, Reading the Office Formats).
//!
//! One flat, non-recursive machine: XML events in, `Emitter` calls out,
//! with an explicit frame stack mirroring the open elements the reader
//! cares about and a list stack synthesizing list structure from numbering
//! properties. Every deliberate omission emits a report; an unrecognized
//! construct is an `UNHANDLED CONSTRUCT` warning, visible in the field
//! rather than silent.
//!
//! The package front end lives in `package.zig` and the table handlers in
//! `tables.zig`; both operate on this file's `Machine`.

const std = @import("std");
const assert = std.debug.assert;
const core = @import("zenfmt_core");
const xml = @import("zenfmt_xml");
const ooxml = @import("zenfmt_ooxml");
const styles_mod = @import("styles.zig");
const numbering_mod = @import("numbering.zig");
const util = @import("util.zig");
const runStyleTags = util.runStyleTags;
const stringLessThan = util.stringLessThan;
const stringAttribute = util.stringAttribute;
const toggleValue = util.toggleValue;
const isMonospaceFont = util.isMonospaceFont;
const parseHyperlinkInstruction = util.parseHyperlinkInstruction;

pub const reader = core.Reader(.{
    .id = "ai.insan.zenfmt.docx",
    .format = "docx",
    .extensions = &.{ "docx", "docm" },
    .input = .seekable,
    .data_version = 1,
    .read = @import("package.zig").read,
});

const tables = @import("tables.zig");

pub const w_ns = "http://schemas.openxmlformats.org/wordprocessingml/2006/main";
const r_ns = "http://schemas.openxmlformats.org/officeDocument/2006/relationships";

// -------------------------------------------------------------- machine

pub const RunProps = struct {
    strong: bool = false,
    emphasis: bool = false,
    strike: bool = false,
    superscript: bool = false,
    subscript: bool = false,
    small_caps: bool = false,
    underline: bool = false,
    code: bool = false,

    fn eql(a: RunProps, b: RunProps) bool {
        return std.meta.eql(a, b);
    }
};

pub const FrameKind = enum {
    transparent,
    paragraph,
    run,
    hyperlink,
    instr_text,
    text_run,
    table,
    table_row,
    table_cell,
    sdt,
    sdt_content_block,
    sdt_content_inline,
};

pub const Frame = struct {
    kind: FrameKind,
    block_token: ?core.builder.BlockToken = null,
    inline_token: ?core.builder.InlineToken = null,
    /// For context-establishing frames: where this context's lists begin.
    list_base: u32 = 0,
    /// Table frames index into `tables`.
    table_index: u32 = 0,
};

pub const TableState = struct {
    columns: u32,
    head_token: ?core.builder.BlockToken = null,
    body_token: ?core.builder.BlockToken = null,
    spans_noted: bool = false,
};

const ListLevel = struct {
    num_id: u32,
    ilvl: u8,
    list_token: core.builder.BlockToken,
    item_token: ?core.builder.BlockToken,
};

const ParaProps = struct {
    style_id: []const u8 = "",
    num: ?struct { id: u32, ilvl: u8 } = null,
};

const FieldState = enum { none, instr, display };

const NoteEntry = struct {
    id: []const u8,
    note: u32,
    emitted: bool = false,
};

pub const Machine = struct {
    ctx: *core.ReadContext,
    arena: std.mem.Allocator,
    styles: *const styles_mod.Styles,
    numbering: *const numbering_mod.Numbering,
    rels: *const ooxml.Relationships,
    parser: *xml.Parser = undefined,
    pending: ?xml.Event = null,

    frames: [256]Frame = undefined,
    depth: u32 = 0,
    tables: [32]TableState = undefined,
    table_depth: u32 = 0,
    lists: [64]ListLevel = undefined,
    list_depth: u32 = 0,

    // Paragraph-scoped state; paragraphs never nest.
    in_paragraph: bool = false,
    style_tokens: [8]core.builder.InlineToken = undefined,
    style_count: u8 = 0,
    style_props: RunProps = .{},
    field: FieldState = .none,
    field_url: ?[]const u8 = null,
    field_link: ?core.builder.InlineToken = null,
    instr_buffer: std.ArrayList(u8) = .empty,

    note_order: std.ArrayList(NoteEntry) = .empty,
    style_ids_seen: std.StringHashMapUnmanaged(void) = .empty,
    pending_sdt_tag: ?[]const u8 = null,

    // Facet state (ZDS 0013): the archive for media extraction, the first
    // body block as the page-layout anchor, and a revision met between
    // paragraphs.
    archive: ?*ooxml.zip.Archive = null,
    first_block_token: ?core.builder.BlockToken = null,
    layout_attached: bool = false,
    pending_revision: ?facets_mod.PendingRevision = null,

    // Deliberate-omission counters, reported once at the end.
    count_comments: u32 = 0,
    count_deletions: u32 = 0,
    count_page_breaks: u32 = 0,
    count_bookmarks: u32 = 0,
    count_section_properties: u32 = 0,
    count_text_boxes: u32 = 0,
    count_objects: u32 = 0,
    count_heading_clamped: u32 = 0,

    pub fn deinit(m: *Machine) void {
        m.instr_buffer.deinit(m.arena);
        m.note_order.deinit(m.arena);
        m.style_ids_seen.deinit(m.arena);
    }

    pub fn next(m: *Machine) core.ReadError!xml.Event {
        if (m.pending) |event| {
            m.pending = null;
            return event;
        }
        return m.parser.next() catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.DoctypeRefused => {
                try m.ctx.reports.add(doctypeReport(m.ctx.input_name));
                return error.Malformed;
            },
            error.DepthLimitExceeded => {
                try m.ctx.reports.add(xmlDepthReport(m.ctx.input_name));
                return error.LimitExceeded;
            },
            error.Malformed => {
                try m.ctx.reports.add(malformedXmlReport(m.ctx.input_name));
                return error.Malformed;
            },
        };
    }

    /// Processes events until the parser returns to `stop_depth`.
    pub fn run(m: *Machine, stop_depth: u32) core.ReadError!void {
        while (true) {
            const event = try m.next();
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

    pub fn top(m: *Machine) ?*Frame {
        if (m.depth == 0) return null;
        return &m.frames[m.depth - 1];
    }

    /// The open paragraph's block token, for facet attachment from run
    /// context; null between paragraphs.
    pub fn currentParagraphToken(m: *Machine) ?core.builder.BlockToken {
        var i = m.depth;
        while (i > 0) {
            i -= 1;
            if (m.frames[i].kind == .paragraph) return m.frames[i].block_token;
        }
        return null;
    }

    pub fn push(m: *Machine, frame: Frame) core.ReadError!void {
        if (m.depth >= m.frames.len) return error.DepthLimitExceeded;
        m.frames[m.depth] = frame;
        m.depth += 1;
    }

    // ------------------------------------------------------- text events

    /// Only `w:t` content is significant; whitespace between structural
    /// elements is XML formatting, not document text.
    fn onText(m: *Machine, bytes: []const u8) core.ReadError!void {
        const frame = m.top() orelse return;
        if (frame.kind == .instr_text) {
            try m.instr_buffer.appendSlice(m.arena, bytes);
            return;
        }
        if (frame.kind != .text_run) return;
        if (!m.in_paragraph) return;
        if (m.field == .instr) return;
        if (m.style_props.code) {
            const trimmed = std.mem.trim(u8, bytes, "\r\n");
            if (trimmed.len > 0) try m.ctx.out.code(trimmed);
            return;
        }
        try m.ctx.out.text(bytes);
    }

    // ---------------------------------------------------- element events

    fn onElementStart(m: *Machine, element: xml.ElementStart) core.ReadError!void {
        const name = element.name;
        if (!std.mem.eql(u8, name.uri, w_ns)) {
            // Foreign namespaces: markup compatibility wrappers, drawings
            // met outside `w:drawing`, and similar. Look through them.
            if (element.self_closing) return;
            try m.push(.{ .kind = .transparent });
            return;
        }

        const local = name.local;
        if (std.mem.eql(u8, local, "p")) return m.onParagraphStart(element);
        if (std.mem.eql(u8, local, "r")) return m.onRunStart(element);
        if (std.mem.eql(u8, local, "t") or std.mem.eql(u8, local, "delText")) {
            if (element.self_closing) return;
            return m.push(.{ .kind = .text_run });
        }
        if (std.mem.eql(u8, local, "hyperlink")) return m.onHyperlinkStart(element);
        if (std.mem.eql(u8, local, "tbl")) return tables.onTableStart(m, element);
        if (std.mem.eql(u8, local, "tr")) return tables.onRowStart(m, element);
        if (std.mem.eql(u8, local, "tc")) return tables.onCellStart(m, element);
        if (std.mem.eql(u8, local, "sdt")) {
            if (element.self_closing) return;
            return m.push(.{ .kind = .sdt });
        }
        if (std.mem.eql(u8, local, "sdtPr")) {
            if (element.self_closing) return;
            // The content control's tag becomes the container's class.
            m.pending_sdt_tag = try m.scanSubtreeAttribute("tag", "val");
            return;
        }
        if (std.mem.eql(u8, local, "sdtContent")) return m.onSdtContentStart(element);
        if (std.mem.eql(u8, local, "br")) {
            var is_page = false;
            for (element.attributes) |attribute| {
                if (std.mem.eql(u8, attribute.name.local, "type") and
                    std.mem.eql(u8, attribute.value, "page"))
                {
                    is_page = true;
                }
            }
            if (is_page) {
                m.count_page_breaks += 1;
            } else if (m.in_paragraph) {
                try m.ctx.out.hardBreak();
            }
            if (!element.self_closing) try m.push(.{ .kind = .transparent });
            return;
        }
        if (std.mem.eql(u8, local, "tab")) {
            if (m.in_paragraph and m.field != .instr) try m.ctx.out.text(" ");
            if (!element.self_closing) try m.push(.{ .kind = .transparent });
            return;
        }
        if (std.mem.eql(u8, local, "footnoteReference")) {
            if (stringAttribute(element.attributes, "id")) |id| {
                const note = try m.noteFor(id);
                if (m.in_paragraph) try m.ctx.out.noteReference(note);
            }
            if (!element.self_closing) try m.push(.{ .kind = .transparent });
            return;
        }
        if (std.mem.eql(u8, local, "fldChar")) {
            const kind = stringAttribute(element.attributes, "fldCharType") orelse "";
            try m.onFieldChar(kind);
            if (!element.self_closing) try m.push(.{ .kind = .transparent });
            return;
        }
        if (std.mem.eql(u8, local, "instrText")) {
            if (element.self_closing) return;
            return m.push(.{ .kind = .instr_text });
        }
        if (std.mem.eql(u8, local, "drawing") or std.mem.eql(u8, local, "pict")) {
            if (element.self_closing) return;
            return m.onDrawing();
        }
        if (std.mem.eql(u8, local, "object")) {
            m.count_objects += 1;
            if (!element.self_closing) try m.skipCurrent();
            return;
        }
        if (std.mem.eql(u8, local, "txbxContent")) {
            m.count_text_boxes += 1;
            if (!element.self_closing) try m.skipCurrent();
            return;
        }
        if (std.mem.eql(u8, local, "del") or std.mem.eql(u8, local, "moveFrom")) {
            m.count_deletions += 1;
            try facets_mod.onRevision(m, element, .deletion);
            if (!element.self_closing) try m.skipCurrent();
            return;
        }
        if (std.mem.eql(u8, local, "ins") or std.mem.eql(u8, local, "moveTo")) {
            try facets_mod.onRevision(m, element, .insertion);
            if (element.self_closing) return;
            return m.push(.{ .kind = .transparent });
        }
        if (std.mem.eql(u8, local, "smartTag") or std.mem.eql(u8, local, "body") or
            std.mem.eql(u8, local, "document"))
        {
            if (element.self_closing) return;
            return m.push(.{ .kind = .transparent });
        }
        if (std.mem.eql(u8, local, "commentRangeStart") or
            std.mem.eql(u8, local, "commentRangeEnd") or
            std.mem.eql(u8, local, "commentReference"))
        {
            if (std.mem.eql(u8, local, "commentReference")) m.count_comments += 1;
            if (!element.self_closing) try m.skipCurrent();
            return;
        }
        if (std.mem.eql(u8, local, "bookmarkStart") or std.mem.eql(u8, local, "bookmarkEnd")) {
            if (std.mem.eql(u8, local, "bookmarkStart")) m.count_bookmarks += 1;
            if (!element.self_closing) try m.skipCurrent();
            return;
        }
        if (std.mem.eql(u8, local, "sectPr")) {
            m.count_section_properties += 1;
            if (!element.self_closing) try facets_mod.onSectionProperties(m);
            return;
        }
        if (std.mem.eql(u8, local, "proofErr") or std.mem.eql(u8, local, "lastRenderedPageBreak") or
            std.mem.eql(u8, local, "noProof"))
        {
            if (!element.self_closing) try m.skipCurrent();
            return;
        }

        // Recognized as WordprocessingML, handled by nobody: say so.
        try m.ctx.reports.add(unhandledReport(try m.arena.dupe(u8, local)));
        if (element.self_closing) return;
        try m.push(.{ .kind = .transparent });
    }

    fn popFrame(m: *Machine) core.ReadError!void {
        const frame = m.top() orelse return;
        switch (frame.kind) {
            .transparent, .instr_text, .text_run, .sdt => {},
            .paragraph => {
                try m.closeRunStyles();
                if (m.field_link) |token| {
                    m.ctx.out.endInline(token);
                    m.field_link = null;
                    m.field = .none;
                }
                if (frame.block_token) |token| m.ctx.out.endBlock(token);
                m.in_paragraph = false;
            },
            .run => {},
            .hyperlink => {
                try m.closeRunStyles();
                if (frame.inline_token) |token| m.ctx.out.endInline(token);
            },
            .table => {
                const table = &m.tables[frame.table_index];
                if (table.head_token) |token| m.ctx.out.endBlock(token);
                if (table.body_token) |token| m.ctx.out.endBlock(token);
                if (frame.block_token) |token| m.ctx.out.endBlock(token);
                m.table_depth -= 1;
            },
            .table_row => {
                if (frame.block_token) |token| m.ctx.out.endBlock(token);
            },
            .table_cell => {
                try m.closeLists(frame.list_base);
                if (frame.block_token) |token| m.ctx.out.endBlock(token);
            },
            .sdt_content_block => {
                try m.closeLists(frame.list_base);
                if (frame.block_token) |token| m.ctx.out.endBlock(token);
            },
            .sdt_content_inline => {
                if (frame.inline_token) |token| m.ctx.out.endInline(token);
            },
        }
        m.depth -= 1;
    }

    // --------------------------------------------------------- paragraphs

    fn onParagraphStart(m: *Machine, element: xml.ElementStart) core.ReadError!void {
        assert(!m.in_paragraph);
        var props: ParaProps = .{};
        if (!element.self_closing) {
            const first = try m.next();
            if (first == .element_start and first.element_start.name.is(w_ns, "pPr")) {
                if (!first.element_start.self_closing) try m.parseParagraphProperties(&props);
            } else {
                m.pending = first;
            }
        }

        var block_token: ?core.builder.BlockToken = null;
        var style_facet: ?[]const u8 = null;
        if (props.num) |num| {
            try m.enterListItem(num.id, num.ilvl);
            block_token = try m.ctx.out.beginPlain();
        } else {
            try m.closeLists(m.contextListBase());
            if (props.style_id.len > 0) {
                if (m.styles.headingLevel(props.style_id)) |raw_level| {
                    var level = raw_level;
                    if (level > 6) {
                        level = 6;
                        m.count_heading_clamped += 1;
                    }
                    block_token = try m.ctx.out.beginHeading(level);
                } else {
                    try m.style_ids_seen.put(m.arena, try m.arena.dupe(u8, props.style_id), {});
                    style_facet = props.style_id;
                }
            }
            if (block_token == null) block_token = try m.ctx.out.beginParagraph();
        }

        // Facets (ZDS 0013): the named style rides beside the kernel node,
        // the first block anchors the page layout, and a paragraph-level
        // tracked change stashed by `w:ins` lands here.
        if (m.first_block_token == null) m.first_block_token = block_token;
        if (style_facet) |name| {
            try m.ctx.out.attachStyle(block_token.?, .{ .name = name });
        }
        try facets_mod.applyPendingRevision(m, block_token.?);

        m.in_paragraph = true;
        m.style_props = .{};
        m.style_count = 0;
        if (element.self_closing) {
            // An empty paragraph: open and close on the spot.
            m.ctx.out.endBlock(block_token.?);
            m.in_paragraph = false;
            return;
        }
        try m.push(.{ .kind = .paragraph, .block_token = block_token });
    }

    /// Consumes a non-self-closing `w:pPr` subtree.
    fn parseParagraphProperties(m: *Machine, props: *ParaProps) core.ReadError!void {
        const target = m.parser.depth;
        var num_id: ?u32 = null;
        var ilvl: u8 = 0;
        while (m.parser.depth >= target) {
            const event = try m.next();
            switch (event) {
                .done => return,
                .element_start => |child| {
                    if (child.name.is(w_ns, "pStyle")) {
                        if (stringAttribute(child.attributes, "val")) |value| {
                            props.style_id = try m.arena.dupe(u8, value);
                        }
                    } else if (child.name.is(w_ns, "numId")) {
                        if (stringAttribute(child.attributes, "val")) |value| {
                            num_id = std.fmt.parseInt(u32, value, 10) catch null;
                        }
                    } else if (child.name.is(w_ns, "ilvl")) {
                        if (stringAttribute(child.attributes, "val")) |value| {
                            ilvl = std.fmt.parseInt(u8, value, 10) catch 0;
                        }
                    } else if (child.name.is(w_ns, "sectPr")) {
                        m.count_section_properties += 1;
                    }
                },
                .element_end => {},
                .text => {},
            }
        }
        if (num_id) |id| props.num = .{ .id = id, .ilvl = ilvl };
    }

    // -------------------------------------------------------------- runs

    fn onRunStart(m: *Machine, element: xml.ElementStart) core.ReadError!void {
        if (element.self_closing) return;
        var props: RunProps = .{};
        const first = try m.next();
        if (first == .element_start and first.element_start.name.is(w_ns, "rPr")) {
            if (!first.element_start.self_closing) try m.parseRunProperties(&props);
        } else {
            m.pending = first;
        }
        if (m.in_paragraph and m.field != .instr) {
            try m.ensureRunStyles(props);
        }
        try m.push(.{ .kind = .run });
    }

    fn parseRunProperties(m: *Machine, props: *RunProps) core.ReadError!void {
        const target = m.parser.depth;
        while (m.parser.depth >= target) {
            const event = try m.next();
            switch (event) {
                .done => return,
                .element_start => |child| {
                    const on = toggleValue(child.attributes);
                    if (child.name.is(w_ns, "b")) {
                        props.strong = on;
                    } else if (child.name.is(w_ns, "i")) {
                        props.emphasis = on;
                    } else if (child.name.is(w_ns, "strike") or child.name.is(w_ns, "dstrike")) {
                        props.strike = on;
                    } else if (child.name.is(w_ns, "smallCaps")) {
                        props.small_caps = on;
                    } else if (child.name.is(w_ns, "u")) {
                        const value = stringAttribute(child.attributes, "val") orelse "single";
                        props.underline = !std.mem.eql(u8, value, "none");
                    } else if (child.name.is(w_ns, "vertAlign")) {
                        const value = stringAttribute(child.attributes, "val") orelse "";
                        props.superscript = std.mem.eql(u8, value, "superscript");
                        props.subscript = std.mem.eql(u8, value, "subscript");
                    } else if (child.name.is(w_ns, "rFonts")) {
                        if (stringAttribute(child.attributes, "ascii")) |font| {
                            if (isMonospaceFont(font)) props.code = true;
                        }
                    }
                },
                .element_end => {},
                .text => {},
            }
        }
    }

    /// The flag-to-nesting conversion: containers open in the canonical
    /// order, so bold-italic produces one tree no matter which flag the
    /// source listed first. The common prefix of open containers stays
    /// open, so consecutive runs share structure where their styles agree.
    fn ensureRunStyles(m: *Machine, props: RunProps) core.ReadError!void {
        if (props.eql(m.style_props)) return;

        var wanted: [8]core.InlineTag = undefined;
        const wanted_count = if (props.code) 0 else runStyleTags(props, &wanted);
        var have: [8]core.InlineTag = undefined;
        const have_count = if (m.style_props.code) 0 else runStyleTags(m.style_props, &have);

        var common: u8 = 0;
        while (common < wanted_count and common < have_count and
            wanted[common] == have[common])
        {
            common += 1;
        }
        while (m.style_count > common) {
            m.style_count -= 1;
            m.ctx.out.endInline(m.style_tokens[m.style_count]);
        }
        while (m.style_count < wanted_count) {
            m.style_tokens[m.style_count] = try m.ctx.out.beginInline(wanted[m.style_count]);
            m.style_count += 1;
        }
        m.style_props = props;
    }

    fn closeRunStyles(m: *Machine) core.ReadError!void {
        while (m.style_count > 0) {
            m.style_count -= 1;
            m.ctx.out.endInline(m.style_tokens[m.style_count]);
        }
        m.style_props = .{};
    }

    // ------------------------------------------------------- hyperlinks

    fn onHyperlinkStart(m: *Machine, element: xml.ElementStart) core.ReadError!void {
        var target: []const u8 = "";
        for (element.attributes) |attribute| {
            if (std.mem.eql(u8, attribute.name.uri, r_ns) and
                std.mem.eql(u8, attribute.name.local, "id"))
            {
                if (m.rels.byId(attribute.value)) |relationship| {
                    target = try m.arena.dupe(u8, relationship.target);
                }
            } else if (std.mem.eql(u8, attribute.name.local, "anchor")) {
                target = try std.fmt.allocPrint(m.arena, "#{s}", .{attribute.value});
            }
        }
        if (!m.in_paragraph or element.self_closing) {
            if (!element.self_closing) try m.push(.{ .kind = .transparent });
            return;
        }
        try m.closeRunStyles();
        const token = try m.ctx.out.beginLink(target, "");
        try m.push(.{ .kind = .hyperlink, .inline_token = token });
    }

    // ------------------------------------------------------------ fields

    fn onFieldChar(m: *Machine, kind: []const u8) core.ReadError!void {
        if (std.mem.eql(u8, kind, "begin")) {
            m.field = .instr;
            m.field_url = null;
            m.instr_buffer.clearRetainingCapacity();
        } else if (std.mem.eql(u8, kind, "separate")) {
            m.field_url = parseHyperlinkInstruction(m.arena, m.instr_buffer.items) catch null;
            m.field = .display;
            if (m.field_url) |url| {
                if (m.in_paragraph) {
                    try m.closeRunStyles();
                    m.field_link = try m.ctx.out.beginLink(url, "");
                }
            }
        } else if (std.mem.eql(u8, kind, "end")) {
            if (m.field == .instr) {
                // No separate: the field has no cached result to keep.
                m.field = .none;
                return;
            }
            if (m.field_link) |token| {
                try m.closeRunStyles();
                m.ctx.out.endInline(token);
                m.field_link = null;
            }
            m.field = .none;
        }
    }

    // ---------------------------------------------------------- content controls

    fn onSdtContentStart(m: *Machine, element: xml.ElementStart) core.ReadError!void {
        if (element.self_closing) return;
        const tag = m.pending_sdt_tag orelse "";
        m.pending_sdt_tag = null;
        if (m.in_paragraph) {
            if (tag.len > 0) try m.ctx.out.attrs(.{ .classes = &.{tag} });
            const token = try m.ctx.out.beginInline(.span);
            try m.push(.{ .kind = .sdt_content_inline, .inline_token = token });
        } else {
            if (tag.len > 0) try m.ctx.out.attrs(.{ .classes = &.{tag} });
            const token = try m.ctx.out.beginBlock(.container);
            try m.push(.{
                .kind = .sdt_content_block,
                .block_token = token,
                .list_base = m.list_depth,
            });
        }
    }

    // ---------------------------------------------------------- drawings

    /// Consumes a `w:drawing`/`w:pict` subtree, harvesting the embedded
    /// relationship id and description on the way past.
    fn onDrawing(m: *Machine) core.ReadError!void {
        const target = m.parser.depth;
        var embed_id: ?[]const u8 = null;
        var description: ?[]const u8 = null;
        while (m.parser.depth >= target) {
            const event = try m.next();
            switch (event) {
                .done => return,
                .element_start => |child| {
                    for (child.attributes) |attribute| {
                        if (std.mem.eql(u8, attribute.name.local, "embed") and
                            embed_id == null)
                        {
                            embed_id = try m.arena.dupe(u8, attribute.value);
                        } else if (std.mem.eql(u8, attribute.name.local, "descr") and
                            description == null)
                        {
                            description = try m.arena.dupe(u8, attribute.value);
                        }
                    }
                },
                else => {},
            }
        }
        if (!m.in_paragraph) return;

        var source: []const u8 = "";
        if (embed_id) |id| {
            if (m.rels.byId(id)) |relationship| {
                source = try ooxml.resolveTarget(m.arena, "word", relationship.target);
            }
        }
        // Sourceless, descriptionless drawings are decorative shapes;
        // emitting an empty image would only litter the output.
        if (source.len == 0 and (description == null or description.?.len == 0)) return;
        const token = try m.ctx.out.beginImage(source, "");
        if (description) |alt| try m.ctx.out.text(alt);
        m.ctx.out.endInline(token);
        try facets_mod.registerImage(m, source);
    }

    // ------------------------------------------------------------- lists

    pub fn contextListBase(m: *Machine) u32 {
        var i = m.depth;
        while (i > 0) {
            i -= 1;
            switch (m.frames[i].kind) {
                .table_cell, .sdt_content_block => return m.frames[i].list_base,
                else => {},
            }
        }
        return 0;
    }

    /// The numbering inference machine (ZDS 0002): open on rising `ilvl`,
    /// close on falling `ilvl` or a changed `numId`, and open intervening
    /// levels as empty items when `ilvl` jumps.
    fn enterListItem(m: *Machine, num_id: u32, ilvl: u8) core.ReadError!void {
        const base = m.contextListBase();

        // Close levels deeper than the target, and a same-level list whose
        // numbering identity changed.
        while (m.list_depth > base) {
            const current = &m.lists[m.list_depth - 1];
            const current_relative = m.list_depth - base - 1;
            if (current_relative > ilvl) {
                try m.closeOneList();
            } else if (current_relative == @as(u32, ilvl) and current.num_id != num_id) {
                try m.closeOneList();
                break;
            } else {
                break;
            }
        }

        // Open levels up to the target; jumped-over levels get empty items.
        while (m.list_depth - base <= ilvl) {
            const relative: u8 = @intCast(m.list_depth - base);
            const definition = m.numbering.level(num_id, relative);
            const list_token = try m.ctx.out.beginList(.{
                .kind = if (definition.ordered) .ordered else .unordered,
                .start = definition.start,
                .style = .decimal,
                .delimiter = .period,
            });
            assert(m.list_depth < m.lists.len);
            m.lists[m.list_depth] = .{
                .num_id = num_id,
                .ilvl = relative,
                .list_token = list_token,
                .item_token = null,
            };
            m.list_depth += 1;
            if (m.list_depth - base <= ilvl) {
                // An intervening level: it holds only the deeper list.
                m.lists[m.list_depth - 1].item_token = try m.ctx.out.beginBlock(.list_item);
            }
        }

        // A fresh item at the target level.
        const level = &m.lists[m.list_depth - 1];
        if (level.item_token) |token| m.ctx.out.endBlock(token);
        level.item_token = try m.ctx.out.beginBlock(.list_item);
    }

    fn closeOneList(m: *Machine) core.ReadError!void {
        assert(m.list_depth > 0);
        const level = &m.lists[m.list_depth - 1];
        if (level.item_token) |token| m.ctx.out.endBlock(token);
        m.ctx.out.endBlock(level.list_token);
        m.list_depth -= 1;
    }

    pub fn closeLists(m: *Machine, base: u32) core.ReadError!void {
        while (m.list_depth > base) try m.closeOneList();
    }

    // --------------------------------------------------------- footnotes

    fn noteFor(m: *Machine, id: []const u8) core.ReadError!u32 {
        for (m.note_order.items) |entry| {
            if (std.mem.eql(u8, entry.id, id)) return entry.note;
        }
        const note = try m.ctx.out.declareNote();
        try m.note_order.append(m.arena, .{
            .id = try m.arena.dupe(u8, id),
            .note = note,
        });
        return note;
    }

    pub fn readFootnotes(m: *Machine, bytes: []const u8) core.ReadError!void {
        var parser = xml.Parser.init(m.arena, bytes, m.ctx.limits.max_xml_depth);
        defer parser.deinit();
        m.parser = &parser;
        m.pending = null;

        while (true) {
            const event = try m.next();
            switch (event) {
                .done => return,
                .element_start => |element| {
                    if (!element.name.is(w_ns, "footnote") or element.self_closing) continue;
                    const id = stringAttribute(element.attributes, "id") orelse "";
                    const entry = m.findNote(id) orelse {
                        parser.skipElement() catch return error.Malformed;
                        continue;
                    };
                    entry.emitted = true;
                    m.ctx.out.beginNoteBody(entry.note);
                    const content_depth = parser.depth;
                    try m.run(content_depth);
                    try m.closeLists(0);
                    m.ctx.out.endNoteBody(entry.note);
                },
                else => {},
            }
        }
    }

    fn findNote(m: *Machine, id: []const u8) ?*NoteEntry {
        for (m.note_order.items) |*entry| {
            if (std.mem.eql(u8, entry.id, id)) return entry;
        }
        return null;
    }

    // ------------------------------------------------------------- misc

    pub fn skipCurrent(m: *Machine) core.ReadError!void {
        m.parser.skipElement() catch return error.Malformed;
    }

    /// Consumes the current subtree, returning the `val` attribute of the
    /// first `w:<element_local>` child found.
    fn scanSubtreeAttribute(
        m: *Machine,
        element_local: []const u8,
        attribute_local: []const u8,
    ) core.ReadError!?[]const u8 {
        const target = m.parser.depth;
        var found: ?[]const u8 = null;
        while (m.parser.depth >= target) {
            const event = try m.next();
            switch (event) {
                .done => return found,
                .element_start => |child| {
                    if (found == null and child.name.is(w_ns, element_local)) {
                        if (stringAttribute(child.attributes, attribute_local)) |value| {
                            found = try m.arena.dupe(u8, value);
                        }
                    }
                },
                else => {},
            }
        }
        return found;
    }

    pub fn finishReports(m: *Machine) core.ReadError!void {
        const reports = m.ctx.reports;
        if (m.count_comments > 0) try addCounted(reports, droppedReport(
            "docx.comments-dropped",
            "COMMENTS DROPPED",
            "This document contains comments, and comments have no place " ++
                "in the shared document tree.",
            "The comments are absent from the output.",
        ), m.count_comments);
        if (m.count_deletions > 0) try addCounted(reports, droppedReport(
            "docx.tracked-deletions-dropped",
            "TRACKED DELETIONS DROPPED",
            "This document contains tracked-change deletions. Insertions " ++
                "were accepted; deletions were rejected.",
            "The deleted text is absent from the output.",
        ), m.count_deletions);
        if (m.count_page_breaks > 0) try addCounted(reports, degradedNote(
            "docx.page-breaks-dropped",
            "PAGE BREAKS DROPPED",
            "This document contains explicit page breaks, and the output " ++
                "format has no pages.",
            "The page breaks are absent from the output.",
        ), m.count_page_breaks);
        if (m.count_bookmarks > 0) try addCounted(reports, degradedNote(
            "docx.bookmarks-dropped",
            "BOOKMARKS DROPPED",
            "This document contains bookmarks and cross-reference anchors.",
            "The bookmarks are absent; text that referenced them keeps " ++
                "its display form.",
        ), m.count_bookmarks);
        if (m.count_section_properties > 0) try addCounted(reports, degradedNote(
            "docx.section-properties-dropped",
            "SECTION PROPERTIES DROPPED",
            "This document declares page size, margins, columns, or " ++
                "other section properties.",
            "Layout properties are absent from the output.",
        ), m.count_section_properties);
        if (m.count_text_boxes > 0) try addCounted(reports, droppedReport(
            "docx.text-boxes-dropped",
            "TEXT BOXES DROPPED",
            "This document contains text boxes or shapes with text.",
            "The text-box content is absent from the output.",
        ), m.count_text_boxes);
        if (m.count_objects > 0) try addCounted(reports, droppedReport(
            "docx.embedded-objects-dropped",
            "EMBEDDED OBJECTS DROPPED",
            "This document embeds OLE objects — charts, spreadsheets, or " ++
                "other applications' content.",
            "The embedded objects are absent from the output.",
        ), m.count_objects);
        if (m.count_heading_clamped > 0) try addCounted(reports, degradedNote(
            "docx.heading-level-clamped",
            "HEADING LEVEL CLAMPED",
            "This document uses heading styles deeper than level six.",
            "Headings beyond level six were clamped to level six.",
        ), m.count_heading_clamped);
    }

    pub fn emitPluginData(m: *Machine) core.ReadError!void {
        if (m.style_ids_seen.count() == 0) return;
        var ids: std.ArrayList([]const u8) = .empty;
        defer ids.deinit(m.arena);
        var it = m.style_ids_seen.keyIterator();
        while (it.next()) |key| try ids.append(m.arena, key.*);
        std.mem.sort([]const u8, ids.items, {}, stringLessThan);

        const data = encodePluginData(m.arena, ids.items) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.Malformed,
        };
        m.ctx.own_plugin_data = .{
            .version = 1,
            .data = data,
        };
    }

    fn encodePluginData(
        arena: std.mem.Allocator,
        ids: []const []const u8,
    ) core.json.WriteError![]const u8 {
        var stream = core.json.WriteStream.init(arena);
        defer stream.deinit();
        try stream.beginObject();
        try stream.field("paragraph_style_ids");
        try stream.beginArray();
        for (ids) |id| try stream.string(id);
        try stream.endArray();
        try stream.endObject();
        return stream.toOwnedSlice();
    }
};

// The facet and media logic lives in `facets.zig` (ZDS 0013); the report
// constructors beside the reader in `reports.zig`, so the mapping and the
// diagnostics catalog stay one import apart.
const facets_mod = @import("facets.zig");
const reports_mod = @import("reports.zig");
const archiveReport = reports_mod.archiveReport;
const missingPartReport = reports_mod.missingPartReport;
const doctypeReport = reports_mod.doctypeReport;
const xmlDepthReport = reports_mod.xmlDepthReport;
const malformedXmlReport = reports_mod.malformedXmlReport;
const unhandledReport = reports_mod.unhandledReport;
const mergedCellNote = reports_mod.mergedCellNote;
const droppedReport = reports_mod.droppedReport;
const degradedNote = reports_mod.degradedNote;
const addCounted = reports_mod.addCounted;
