//! The PPTX reader (ZDS 0002, The other formats): each slide becomes a
//! heading from the title placeholder followed by the body content —
//! paragraphs, bullet lists synthesized from `a:pPr` levels, tables from
//! `a:tbl`, hyperlinks resolved through the slide relationships, and image
//! references from `p:pic`. Speaker notes append as a `container` with
//! class `notes`. Positioning, animation, charts, and SmartArt are
//! dropped — a presentation loses its geometry in this projection, and
//! the reports say so loudly.

const std = @import("std");
const assert = std.debug.assert;
const core = @import("zenfmt_core");
const xml = @import("zenfmt_xml");
const ooxml = @import("zenfmt_ooxml");
const reports_mod = @import("reports.zig");

pub const reader = core.Reader(.{
    .id = "ai.insan.zenfmt.pptx",
    .format = "pptx",
    .extensions = &.{ "pptx", "pptm", "ppsx", "ppsm" },
    .input = .seekable,
    .read = read,
});

const p_ns = "http://schemas.openxmlformats.org/presentationml/2006/main";
const a_ns = "http://schemas.openxmlformats.org/drawingml/2006/main";
const r_ns = "http://schemas.openxmlformats.org/officeDocument/2006/relationships";
const notes_type = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/notesSlide";

pub fn read(ctx: *core.ReadContext) core.ReadError!void {
    const arena = ctx.gpa;
    var archive = ooxml.zip.Archive.openSource(arena, ooxml.zipSource(ctx), ctx.limits) catch |err| {
        try ctx.reports.add(reports_mod.archiveReport());
        return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.LimitExceeded => error.LimitExceeded,
            else => error.Malformed,
        };
    };

    const presentation = extract(&archive, arena, "ppt/presentation.xml", ctx) orelse {
        try ctx.reports.add(reports_mod.notPresentationReport());
        return error.Malformed;
    };
    const rels = blk: {
        const bytes = extract(&archive, arena, "ppt/_rels/presentation.xml.rels", ctx) orelse
            break :blk ooxml.Relationships.empty;
        break :blk ooxml.parseRelationships(arena, bytes, ctx.limits) catch ooxml.Relationships.empty;
    };

    try ctx.reports.add(reports_mod.projectionNote());

    // Slides in `sldIdLst` order.
    var parser = xml.Parser.init(arena, presentation, ctx.limits.max_xml_depth);
    defer parser.deinit();
    var slide_index: u32 = 0;
    while (true) {
        const event = parser.next() catch {
            try ctx.reports.add(reports_mod.notPresentationReport());
            return error.Malformed;
        };
        switch (event) {
            .done => break,
            .element_start => |element| {
                if (!element.name.is(p_ns, "sldId")) continue;
                var rel_id: []const u8 = "";
                for (element.attributes) |attribute| {
                    if (std.mem.eql(u8, attribute.name.uri, r_ns) and
                        std.mem.eql(u8, attribute.name.local, "id"))
                    {
                        rel_id = try arena.dupe(u8, attribute.value);
                    }
                }
                const relationship = rels.byId(rel_id) orelse continue;
                const part = try ooxml.resolveTarget(arena, "ppt", relationship.target);
                try readSlide(ctx, &archive, arena, part, slide_index);
                slide_index += 1;
            },
            else => {},
        }
    }
}

fn extract(
    archive: *ooxml.zip.Archive,
    arena: std.mem.Allocator,
    name: []const u8,
    ctx: *core.ReadContext,
) ?[]const u8 {
    const entry = archive.find(name) orelse return null;
    return archive.extract(arena, entry, ctx.limits) catch null;
}

fn loadRels(
    archive: *ooxml.zip.Archive,
    arena: std.mem.Allocator,
    part: []const u8,
    ctx: *core.ReadContext,
) core.ReadError!ooxml.Relationships {
    const dir = std.fs.path.dirname(part) orelse return ooxml.Relationships.empty;
    const base = std.fs.path.basename(part);
    const rels_part = try std.fmt.allocPrint(arena, "{s}/_rels/{s}.rels", .{ dir, base });
    const bytes = extract(archive, arena, rels_part, ctx) orelse
        return ooxml.Relationships.empty;
    return ooxml.parseRelationships(arena, bytes, ctx.limits) catch ooxml.Relationships.empty;
}

fn readSlide(
    ctx: *core.ReadContext,
    archive: *ooxml.zip.Archive,
    arena: std.mem.Allocator,
    part: []const u8,
    slide_index: u32,
) core.ReadError!void {
    const bytes = extract(archive, arena, part, ctx) orelse return;
    const dir = std.fs.path.dirname(part) orelse "ppt/slides";
    const slide_rels = try loadRels(archive, arena, part, ctx);
    try emitShapes(ctx, arena, archive, bytes, .slide, &slide_rels, dir, slide_index);

    // Speaker notes hang off the slide's own relationships.
    const notes = slide_rels.byType(notes_type) orelse return;
    const resolved = try ooxml.resolveTarget(arena, dir, notes.target);
    const notes_part = normalizePath(arena, resolved) catch resolved;
    const notes_bytes = extract(archive, arena, notes_part, ctx) orelse return;
    const notes_dir = std.fs.path.dirname(notes_part) orelse "ppt/notesSlides";
    const notes_rels = try loadRels(archive, arena, notes_part, ctx);

    try ctx.out.attrs(.{ .classes = &.{"notes"} });
    const container = try ctx.out.beginBlock(.container);
    try emitShapes(ctx, arena, archive, notes_bytes, .notes, &notes_rels, notes_dir, slide_index);
    ctx.out.endBlock(container);
}

/// `ppt/slides/../notesSlides/x.xml` becomes `ppt/notesSlides/x.xml`.
pub fn normalizePath(arena: std.mem.Allocator, path: []const u8) ![]const u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    defer parts.deinit(arena);
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |part| {
        if (std.mem.eql(u8, part, "..")) {
            if (parts.items.len > 0) parts.items.len -= 1;
        } else if (part.len > 0 and !std.mem.eql(u8, part, ".")) {
            try parts.append(arena, part);
        }
    }
    return std.mem.join(arena, "/", parts.items);
}

const ShapeContext = enum { slide, notes };

fn emitShapes(
    ctx: *core.ReadContext,
    arena: std.mem.Allocator,
    archive: *ooxml.zip.Archive,
    bytes: []const u8,
    shape_context: ShapeContext,
    rels: *const ooxml.Relationships,
    part_dir: []const u8,
    slide_index: u32,
) core.ReadError!void {
    var machine: Machine = .{
        .ctx = ctx,
        .arena = arena,
        .archive = archive,
        .rels = rels,
        .part_dir = part_dir,
        .shape_context = shape_context,
        .slide_index = slide_index,
    };
    var parser = xml.Parser.init(arena, bytes, ctx.limits.max_xml_depth);
    defer parser.deinit();
    machine.parser = &parser;
    try machine.run();
    try machine.unwind();
}

// -------------------------------------------------------------- machine

const RunProps = struct {
    strong: bool = false,
    emphasis: bool = false,
    /// Resolved external URL; empty means no hyperlink.
    link: []const u8 = "",

    fn eql(a: RunProps, b: RunProps) bool {
        return a.strong == b.strong and a.emphasis == b.emphasis and
            std.mem.eql(u8, a.link, b.link);
    }
};

const FrameKind = enum {
    transparent,
    shape,
    body,
    paragraph,
    run,
    text_run,
    table,
    table_row,
    table_cell,
};

const Frame = struct {
    kind: FrameKind,
    block_token: ?core.builder.BlockToken = null,
    /// For shapes: whether a title placeholder was seen.
    is_title: bool = false,
    /// For shapes: the `a:xfrm` geometry, attached to the shape's first
    /// emitted block as a layout facet (ZDS 0013).
    layout: ?core.facets.LayoutData = null,
    layout_attached: bool = false,
    /// For bodies: where this context's lists begin.
    list_base: u32 = 0,
    /// Table frames index into `tables`.
    table_index: u32 = 0,
};

const TableState = struct {
    first_row_header: bool = false,
    row_index: u32 = 0,
    head_token: ?core.builder.BlockToken = null,
    body_token: ?core.builder.BlockToken = null,
    spans_noted: bool = false,
};

const ListLevel = struct {
    ordered: bool,
    list_token: core.builder.BlockToken,
    item_token: ?core.builder.BlockToken,
};

const BulletKind = enum { inherit, none, char, autonum };

const Machine = struct {
    ctx: *core.ReadContext,
    arena: std.mem.Allocator,
    archive: *ooxml.zip.Archive,
    rels: *const ooxml.Relationships,
    part_dir: []const u8,
    shape_context: ShapeContext,
    /// Zero-based slide index; the surface index of layout facets.
    slide_index: u32 = 0,
    parser: *xml.Parser = undefined,
    pending: ?xml.Event = null,
    finished: bool = false,
    media_limit_noted: bool = false,

    frames: [128]Frame = undefined,
    depth: u32 = 0,
    tables: [8]TableState = undefined,
    table_depth: u32 = 0,
    lists: [16]ListLevel = undefined,
    list_depth: u32 = 0,

    // Paragraph-scoped state; DrawingML paragraphs never nest.
    in_paragraph: bool = false,
    para_open: ?core.builder.BlockToken = null,
    para_heading: bool = false,
    /// 1-based list level; 0 means a plain paragraph.
    para_level: u8 = 0,
    para_ordered: bool = false,

    props: RunProps = .{},
    open_props: RunProps = .{},
    style_tokens: [3]core.builder.InlineToken = undefined,
    style_count: u8 = 0,

    /// A malformed slide stops emitting instead of failing the whole
    /// conversion; `unwind` restores token balance afterwards.
    fn next(m: *Machine) core.ReadError!xml.Event {
        if (m.pending) |event| {
            m.pending = null;
            return event;
        }
        if (m.finished) return .done;
        const event = m.parser.next() catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                m.finished = true;
                return .done;
            },
        };
        if (event == .done) m.finished = true;
        return event;
    }

    fn run(m: *Machine) core.ReadError!void {
        while (true) {
            const event = try m.next();
            switch (event) {
                .done => return,
                .text => |bytes| try m.onText(bytes),
                .element_start => |element| try m.onElementStart(element),
                .element_end => try m.popFrame(),
            }
        }
    }

    /// Closes everything a truncated or malformed part left open.
    fn unwind(m: *Machine) core.ReadError!void {
        while (m.depth > 0) try m.popFrame();
        try m.closeLists(0);
    }

    fn top(m: *Machine) ?*Frame {
        if (m.depth == 0) return null;
        return &m.frames[m.depth - 1];
    }

    fn push(m: *Machine, frame: Frame) core.ReadError!void {
        if (m.depth >= m.frames.len) return error.DepthLimitExceeded;
        m.frames[m.depth] = frame;
        m.depth += 1;
    }

    fn skipCurrent(m: *Machine) core.ReadError!void {
        const target = m.parser.depth;
        while (m.parser.depth >= target) {
            const event = try m.next();
            if (event == .done) return;
        }
    }

    fn onText(m: *Machine, bytes: []const u8) core.ReadError!void {
        const frame = m.top() orelse return;
        if (frame.kind != .text_run) return;
        if (!m.in_paragraph) return;
        try m.materialize();
        try m.ensureStyles();
        try m.ctx.out.text(bytes);
    }

    fn onElementStart(m: *Machine, element: xml.ElementStart) core.ReadError!void {
        const name = element.name;
        if (name.is(p_ns, "sp") or name.is(p_ns, "graphicFrame")) {
            if (element.self_closing) return;
            return m.push(.{ .kind = .shape });
        }
        if (name.is(p_ns, "ph")) {
            for (element.attributes) |attribute| {
                if (std.mem.eql(u8, attribute.name.local, "type") and
                    (std.mem.eql(u8, attribute.value, "title") or
                        std.mem.eql(u8, attribute.value, "ctrTitle")))
                {
                    m.markShapeTitle();
                }
            }
            if (!element.self_closing) try m.push(.{ .kind = .transparent });
            return;
        }
        if (name.is(p_ns, "txBody") or name.is(a_ns, "txBody")) {
            if (element.self_closing) return;
            return m.push(.{ .kind = .body, .list_base = m.list_depth });
        }
        if (name.is(a_ns, "p")) return m.onParagraphStart(element);
        if (name.is(a_ns, "r")) return m.onRunStart(element);
        if (name.is(a_ns, "t")) {
            if (element.self_closing) return;
            return m.push(.{ .kind = .text_run });
        }
        if (name.is(a_ns, "br")) {
            if (m.para_open != null) try m.ctx.out.hardBreak();
            if (!element.self_closing) try m.push(.{ .kind = .transparent });
            return;
        }
        if (name.is(a_ns, "xfrm") or name.is(p_ns, "xfrm")) {
            try m.onTransform(element);
            return;
        }
        if (name.is(a_ns, "tbl")) return m.onTableStart(element);
        if (name.is(a_ns, "tr")) return m.onRowStart(element);
        if (name.is(a_ns, "tc")) return m.onCellStart(element);
        if (name.is(p_ns, "pic")) return m.onPic(element);
        if (element.self_closing) return;
        try m.push(.{ .kind = .transparent });
    }

    fn popFrame(m: *Machine) core.ReadError!void {
        if (m.depth == 0) return;
        const frame = &m.frames[m.depth - 1];
        switch (frame.kind) {
            .transparent, .shape, .run, .text_run => {},
            .paragraph => {
                try m.closeStyles();
                m.props = .{};
                if (m.para_open) |token| m.ctx.out.endBlock(token);
                m.para_open = null;
                m.in_paragraph = false;
            },
            .body => try m.closeLists(frame.list_base),
            .table => {
                const table = &m.tables[frame.table_index];
                if (table.head_token) |token| m.ctx.out.endBlock(token);
                if (table.body_token) |token| m.ctx.out.endBlock(token);
                if (frame.block_token) |token| m.ctx.out.endBlock(token);
                m.table_depth -= 1;
            },
            .table_row, .table_cell => {
                if (frame.block_token) |token| m.ctx.out.endBlock(token);
            },
        }
        m.depth -= 1;
    }

    fn markShapeTitle(m: *Machine) void {
        var i = m.depth;
        while (i > 0) {
            i -= 1;
            if (m.frames[i].kind == .shape) {
                m.frames[i].is_title = true;
                return;
            }
        }
    }

    fn currentShapeIsTitle(m: *Machine) bool {
        var i = m.depth;
        while (i > 0) {
            i -= 1;
            if (m.frames[i].kind == .shape) return m.frames[i].is_title;
        }
        return false;
    }

    // ------------------------------------------------------------ layout

    /// `a:xfrm` inside a shape or graphic frame: `a:off` and `a:ext` are
    /// already EMU with a top-left origin, exactly the facet's unit
    /// (ZDS 0013, One coordinate system). Stored on the enclosing shape
    /// frame and attached to its first emitted block.
    fn onTransform(m: *Machine, element: xml.ElementStart) core.ReadError!void {
        const shape = m.enclosingShape() orelse {
            if (!element.self_closing) try m.skipCurrent();
            return;
        };
        if (m.shape_context != .slide or element.self_closing) {
            if (!element.self_closing) try m.skipCurrent();
            return;
        }
        var layout: core.facets.LayoutData = .{
            .surface = .slide,
            .surface_index = m.slide_index,
        };
        const target = m.parser.depth;
        while (m.parser.depth >= target) {
            const event = try m.next();
            switch (event) {
                .done => break,
                .element_start => |child| {
                    if (child.name.is(a_ns, "off")) {
                        layout.x = emuAttribute(child, "x");
                        layout.y = emuAttribute(child, "y");
                    } else if (child.name.is(a_ns, "ext")) {
                        layout.width = @max(0, emuAttribute(child, "cx"));
                        layout.height = @max(0, emuAttribute(child, "cy"));
                    }
                    if (!child.self_closing) try m.skipCurrent();
                },
                else => {},
            }
        }
        if (shape.layout == null) shape.layout = layout;
    }

    fn enclosingShape(m: *Machine) ?*Frame {
        var i = m.depth;
        while (i > 0) {
            i -= 1;
            if (m.frames[i].kind == .shape) return &m.frames[i];
        }
        return null;
    }

    /// Attaches the enclosing shape's geometry to `token` once.
    fn attachShapeLayout(m: *Machine, token: core.builder.BlockToken) core.ReadError!void {
        const shape = m.enclosingShape() orelse return;
        if (shape.layout_attached) return;
        const layout = shape.layout orelse return;
        shape.layout_attached = true;
        try m.ctx.out.attachLayout(token, layout);
    }

    fn bodyListBase(m: *Machine) u32 {
        var i = m.depth;
        while (i > 0) {
            i -= 1;
            if (m.frames[i].kind == .body) return m.frames[i].list_base;
        }
        return 0;
    }

    // --------------------------------------------------------- paragraphs

    fn onParagraphStart(m: *Machine, element: xml.ElementStart) core.ReadError!void {
        if (element.self_closing) return;
        var level: u8 = 0;
        var bullet: BulletKind = .inherit;
        const first = try m.next();
        if (first == .element_start and first.element_start.name.is(a_ns, "pPr")) {
            const properties = first.element_start;
            for (properties.attributes) |attribute| {
                if (std.mem.eql(u8, attribute.name.local, "lvl")) {
                    level = std.fmt.parseInt(u8, attribute.value, 10) catch 0;
                }
            }
            if (!properties.self_closing) try m.parseBulletProperties(&bullet);
        } else {
            m.pending = first;
        }

        m.para_heading = m.shape_context == .slide and m.currentShapeIsTitle();
        const is_list = switch (bullet) {
            .none => false,
            .char, .autonum => true,
            .inherit => level > 0,
        };
        m.para_level = if (is_list and !m.para_heading) @min(level, 8) + 1 else 0;
        m.para_ordered = bullet == .autonum;
        m.para_open = null;
        m.in_paragraph = true;
        try m.push(.{ .kind = .paragraph });
    }

    fn parseBulletProperties(m: *Machine, bullet: *BulletKind) core.ReadError!void {
        const target = m.parser.depth;
        while (m.parser.depth >= target) {
            const event = try m.next();
            switch (event) {
                .done => return,
                .element_start => |child| {
                    if (child.name.is(a_ns, "buNone")) {
                        bullet.* = .none;
                    } else if (child.name.is(a_ns, "buChar")) {
                        bullet.* = .char;
                    } else if (child.name.is(a_ns, "buAutoNum")) {
                        bullet.* = .autonum;
                    }
                    if (!child.self_closing) try m.skipCurrent();
                },
                else => {},
            }
        }
    }

    /// Opens the paragraph's block lazily so empty paragraphs vanish.
    fn materialize(m: *Machine) core.ReadError!void {
        if (m.para_open != null) return;
        assert(m.in_paragraph);
        const base = m.bodyListBase();
        if (m.para_level > 0) {
            try m.enterListItem(base, m.para_level, m.para_ordered);
            m.para_open = try m.ctx.out.beginPlain();
        } else {
            try m.closeLists(base);
            m.para_open = if (m.para_heading)
                try m.ctx.out.beginHeading(2)
            else
                try m.ctx.out.beginParagraph();
        }
        try m.attachShapeLayout(m.para_open.?);
    }

    // -------------------------------------------------------------- runs

    fn onRunStart(m: *Machine, element: xml.ElementStart) core.ReadError!void {
        if (element.self_closing) return;
        m.props = .{};
        const first = try m.next();
        if (first == .element_start and first.element_start.name.is(a_ns, "rPr")) {
            const properties = first.element_start;
            for (properties.attributes) |attribute| {
                if (std.mem.eql(u8, attribute.name.local, "b")) {
                    m.props.strong = truthy(attribute.value);
                } else if (std.mem.eql(u8, attribute.name.local, "i")) {
                    m.props.emphasis = truthy(attribute.value);
                }
            }
            if (!properties.self_closing) try m.parseRunChildren();
        } else {
            m.pending = first;
        }
        try m.push(.{ .kind = .run });
    }

    fn parseRunChildren(m: *Machine) core.ReadError!void {
        const target = m.parser.depth;
        while (m.parser.depth >= target) {
            const event = try m.next();
            switch (event) {
                .done => return,
                .element_start => |child| {
                    if (child.name.is(a_ns, "hlinkClick")) {
                        for (child.attributes) |attribute| {
                            if (std.mem.eql(u8, attribute.name.uri, r_ns) and
                                std.mem.eql(u8, attribute.name.local, "id"))
                            {
                                m.props.link = try m.resolveLink(attribute.value);
                            }
                        }
                    }
                    if (!child.self_closing) try m.skipCurrent();
                },
                else => {},
            }
        }
    }

    /// Only external targets become links; a jump to another slide has no
    /// meaningful Markdown counterpart.
    fn resolveLink(m: *Machine, rel_id: []const u8) core.ReadError![]const u8 {
        const relationship = m.rels.byId(rel_id) orelse return "";
        const target = relationship.target;
        const external = std.mem.indexOf(u8, target, "://") != null or
            std.mem.startsWith(u8, target, "mailto:");
        if (!external) return "";
        return try m.arena.dupe(u8, target);
    }

    fn ensureStyles(m: *Machine) core.ReadError!void {
        if (m.props.eql(m.open_props)) return;
        try m.closeStyles();
        m.open_props = m.props;
        if (m.props.link.len > 0) {
            m.style_tokens[m.style_count] = try m.ctx.out.beginLink(m.props.link, "");
            m.style_count += 1;
        }
        if (m.props.strong) {
            m.style_tokens[m.style_count] = try m.ctx.out.beginInline(.strong);
            m.style_count += 1;
        }
        if (m.props.emphasis) {
            m.style_tokens[m.style_count] = try m.ctx.out.beginInline(.emphasis);
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

    // ------------------------------------------------------------- lists

    /// Mirrors the DOCX numbering machine: close on falling level or a
    /// changed kind, open intervening levels as empty items on a jump.
    fn enterListItem(m: *Machine, base: u32, level: u8, ordered: bool) core.ReadError!void {
        while (m.list_depth > base) {
            const relative = m.list_depth - base;
            const current = &m.lists[m.list_depth - 1];
            if (relative > level) {
                try m.closeOneList();
            } else if (relative == level and current.ordered != ordered) {
                try m.closeOneList();
                break;
            } else {
                break;
            }
        }
        while (m.list_depth - base < level) {
            const is_target = m.list_depth - base + 1 == level;
            const list_token = try m.ctx.out.beginList(.{
                .kind = if (ordered and is_target) .ordered else .unordered,
                .start = 1,
                .style = .decimal,
                .delimiter = .period,
            });
            assert(m.list_depth < m.lists.len);
            m.lists[m.list_depth] = .{
                .ordered = ordered and is_target,
                .list_token = list_token,
                .item_token = null,
            };
            m.list_depth += 1;
            if (m.list_depth - base < level) {
                m.lists[m.list_depth - 1].item_token = try m.ctx.out.beginBlock(.list_item);
            }
        }
        const current = &m.lists[m.list_depth - 1];
        if (current.item_token) |token| m.ctx.out.endBlock(token);
        current.item_token = try m.ctx.out.beginBlock(.list_item);
    }

    fn closeOneList(m: *Machine) core.ReadError!void {
        assert(m.list_depth > 0);
        const level = &m.lists[m.list_depth - 1];
        if (level.item_token) |token| m.ctx.out.endBlock(token);
        m.ctx.out.endBlock(level.list_token);
        m.list_depth -= 1;
    }

    fn closeLists(m: *Machine, base: u32) core.ReadError!void {
        while (m.list_depth > base) try m.closeOneList();
    }

    // ------------------------------------------------------------ tables

    fn onTableStart(m: *Machine, element: xml.ElementStart) core.ReadError!void {
        if (element.self_closing) return;
        var columns: u32 = 0;
        var first_row_header = false;
        while (true) {
            const event = try m.next();
            switch (event) {
                .done => return,
                .element_start => |child| {
                    if (child.name.is(a_ns, "tblPr")) {
                        for (child.attributes) |attribute| {
                            if (std.mem.eql(u8, attribute.name.local, "firstRow")) {
                                first_row_header = truthy(attribute.value);
                            }
                        }
                        if (!child.self_closing) try m.skipCurrent();
                    } else if (child.name.is(a_ns, "tblGrid")) {
                        if (!child.self_closing) try m.countColumns(&columns);
                    } else {
                        m.pending = event;
                        break;
                    }
                },
                .element_end => {
                    m.pending = event;
                    break;
                },
                .text => {},
            }
        }

        var alignments: std.ArrayList(core.payload.Alignment) = .empty;
        defer alignments.deinit(m.arena);
        try alignments.appendNTimes(m.arena, .default, @max(columns, 1));
        const token = try m.ctx.out.beginTable(alignments.items);
        try m.attachShapeLayout(token);

        assert(m.table_depth < m.tables.len);
        m.tables[m.table_depth] = .{ .first_row_header = first_row_header };
        try m.push(.{
            .kind = .table,
            .block_token = token,
            .table_index = m.table_depth,
        });
        m.table_depth += 1;
    }

    fn countColumns(m: *Machine, columns: *u32) core.ReadError!void {
        const target = m.parser.depth;
        while (m.parser.depth >= target) {
            const event = try m.next();
            switch (event) {
                .done => return,
                .element_start => |child| {
                    if (child.name.is(a_ns, "gridCol")) columns.* += 1;
                    if (!child.self_closing) try m.skipCurrent();
                },
                else => {},
            }
        }
    }

    fn onRowStart(m: *Machine, element: xml.ElementStart) core.ReadError!void {
        if (element.self_closing) return;
        const frame = m.top() orelse return m.push(.{ .kind = .transparent });
        if (frame.kind != .table) return m.push(.{ .kind = .transparent });
        const table = &m.tables[frame.table_index];

        if (table.first_row_header and table.row_index == 0) {
            table.head_token = try m.ctx.out.beginBlock(.table_head);
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
        table.row_index += 1;
        const token = try m.ctx.out.beginBlock(.table_row);
        try m.push(.{ .kind = .table_row, .block_token = token });
    }

    fn onCellStart(m: *Machine, element: xml.ElementStart) core.ReadError!void {
        if (element.self_closing) return;
        const frame = m.top() orelse return m.push(.{ .kind = .transparent });
        if (frame.kind != .table_row) return m.push(.{ .kind = .transparent });

        var col_span: u32 = 1;
        var row_span: u32 = 1;
        var continuation = false;
        for (element.attributes) |attribute| {
            const local = attribute.name.local;
            if (std.mem.eql(u8, local, "gridSpan")) {
                col_span = std.fmt.parseInt(u32, attribute.value, 10) catch 1;
            } else if (std.mem.eql(u8, local, "rowSpan")) {
                row_span = std.fmt.parseInt(u32, attribute.value, 10) catch 1;
            } else if (std.mem.eql(u8, local, "hMerge") or std.mem.eql(u8, local, "vMerge")) {
                if (truthy(attribute.value)) continuation = true;
            }
        }

        if (col_span > 1 or row_span > 1 or continuation) {
            const table = m.enclosingTable() orelse return;
            if (!table.spans_noted) {
                table.spans_noted = true;
                try m.ctx.reports.add(reports_mod.mergedCellNote());
            }
        }
        if (continuation) {
            // Fold the continuation into its originating cell: skip it.
            try m.skipCurrent();
            return;
        }

        const token = try m.ctx.out.beginTableCell(.{
            .alignment = .default,
            .row_span = row_span,
            .col_span = col_span,
        });
        try m.push(.{ .kind = .table_cell, .block_token = token });
    }

    fn enclosingTable(m: *Machine) ?*TableState {
        var i = m.depth;
        while (i > 0) {
            i -= 1;
            if (m.frames[i].kind == .table) return &m.tables[m.frames[i].table_index];
        }
        return null;
    }

    // ------------------------------------------------------------ images

    /// `p:pic` is a shape, not paragraph content: the image reference gets
    /// its own paragraph unless a malformed deck put it inside one.
    fn onPic(m: *Machine, element: xml.ElementStart) core.ReadError!void {
        if (element.self_closing) return;
        const target = m.parser.depth;
        var embed_id: ?[]const u8 = null;
        var description: []const u8 = "";
        var shape_name: []const u8 = "";
        while (m.parser.depth >= target) {
            const event = try m.next();
            switch (event) {
                .done => break,
                .element_start => |child| {
                    if (child.name.is(a_ns, "blip")) {
                        for (child.attributes) |attribute| {
                            if (std.mem.eql(u8, attribute.name.uri, r_ns) and
                                std.mem.eql(u8, attribute.name.local, "embed"))
                            {
                                embed_id = try m.arena.dupe(u8, attribute.value);
                            }
                        }
                    } else if (child.name.is(p_ns, "cNvPr")) {
                        for (child.attributes) |attribute| {
                            if (std.mem.eql(u8, attribute.name.local, "descr")) {
                                description = try m.arena.dupe(u8, attribute.value);
                            } else if (std.mem.eql(u8, attribute.name.local, "name")) {
                                shape_name = try m.arena.dupe(u8, attribute.value);
                            }
                        }
                    }
                },
                else => {},
            }
        }

        var source: []const u8 = "";
        if (embed_id) |id| {
            if (m.rels.byId(id)) |relationship| {
                const resolved = try ooxml.resolveTarget(m.arena, m.part_dir, relationship.target);
                source = normalizePath(m.arena, resolved) catch resolved;
            }
        }
        const alt = if (description.len > 0) description else shape_name;
        if (source.len == 0 and alt.len == 0) return;
        if (source.len > 0) try m.registerPicture(source);

        const wrapper = if (m.in_paragraph) blk: {
            try m.materialize();
            try m.ensureStyles();
            break :blk null;
        } else try m.ctx.out.beginParagraph();
        const token = try m.ctx.out.beginImage(source, "");
        if (alt.len > 0) try m.ctx.out.text(alt);
        m.ctx.out.endInline(token);
        if (wrapper) |block| m.ctx.out.endBlock(block);
    }

    /// Extracts the picture's archive entry and registers the bytes with
    /// the resource store; past the limits, remaining pictures degrade to
    /// path-only references with one note.
    fn registerPicture(m: *Machine, source: []const u8) core.ReadError!void {
        const entry = m.archive.find(source) orelse return;
        const bytes = m.archive.extract(m.arena, entry, m.ctx.limits) catch return;
        if (bytes.len == 0) return;
        _ = m.ctx.out.resource(source, bytes, pictureMime(source)) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.DepthLimitExceeded => return error.DepthLimitExceeded,
            error.LimitExceeded => {
                if (!m.media_limit_noted) {
                    m.media_limit_noted = true;
                    try m.ctx.reports.add(reports_mod.mediaLimitNote());
                }
            },
        };
    }
};

/// MIME by extension for embedded pictures; unknown kinds stay opaque.
fn pictureMime(source: []const u8) []const u8 {
    const dot = std.mem.lastIndexOfScalar(u8, source, '.') orelse return "application/octet-stream";
    const extension = source[dot + 1 ..];
    const table = [_]struct { extension: []const u8, mime: []const u8 }{
        .{ .extension = "png", .mime = "image/png" },
        .{ .extension = "jpg", .mime = "image/jpeg" },
        .{ .extension = "jpeg", .mime = "image/jpeg" },
        .{ .extension = "gif", .mime = "image/gif" },
        .{ .extension = "bmp", .mime = "image/bmp" },
        .{ .extension = "tif", .mime = "image/tiff" },
        .{ .extension = "tiff", .mime = "image/tiff" },
        .{ .extension = "emf", .mime = "image/emf" },
        .{ .extension = "wmf", .mime = "image/wmf" },
        .{ .extension = "svg", .mime = "image/svg+xml" },
        .{ .extension = "webp", .mime = "image/webp" },
    };
    for (table) |row| {
        if (std.ascii.eqlIgnoreCase(row.extension, extension)) return row.mime;
    }
    return "application/octet-stream";
}

/// One EMU attribute as a clamped i32; DrawingML spells them as decimal
/// integers, and hostile values saturate instead of overflowing.
fn emuAttribute(element: xml.ElementStart, name: []const u8) i32 {
    for (element.attributes) |attribute| {
        if (!std.mem.eql(u8, attribute.name.local, name)) continue;
        const value = std.fmt.parseInt(i64, attribute.value, 10) catch return 0;
        return std.math.cast(i32, value) orelse
            if (value > 0) std.math.maxInt(i32) else std.math.minInt(i32);
    }
    return 0;
}

fn truthy(value: []const u8) bool {
    return std.mem.eql(u8, value, "1") or std.mem.eql(u8, value, "true");
}
