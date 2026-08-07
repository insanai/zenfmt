//! PDF content-stream text machine (ZDS: pdf-reader).
//!
//! Tokenizes page content, tracks the text and transformation matrices
//! far enough to know where each shown string lands, and assembles
//! device-space lines. Form XObjects execute on an explicit frame stack;
//! inline images are skipped by scanning for `EI`; every other operator
//! clears the operand stack and moves on. When the current font carries
//! width metrics (`/Widths` or CID `/W`), the machine accumulates the pen
//! position and decides join-versus-space from the measured gap between
//! shows; width-less fonts fall back to the TJ kerning heuristic and the
//! producer's own space characters.

const std = @import("std");
const assert = std.debug.assert;
const core = @import("zenfmt_core");
const objects = @import("objects.zig");
const xref = @import("xref.zig");
const fonts = @import("fonts.zig");
const graphics = @import("graphics.zig");
const images_mod = @import("images.zig");

pub const Error = xref.Error;

/// Form XObjects may nest this deep; beyond it they are skipped.
const max_form_depth = 8;
const max_operands = 16;
const max_graphics_stack = 32;
/// Vertical tolerance, as a fraction of the font size, within which two
/// shows belong to one line.
const same_line_tolerance = 0.4;
/// TJ adjustment (thousandths of text space) that reads as a word gap;
/// used only when the font carries no width metrics.
const tj_space_threshold = -180;
/// With width metrics: a pen gap beyond this fraction of the font size is
/// a word break; anything tighter joins without a space.
const join_gap_ratio = 0.15;

pub const Line = struct {
    text: []const u8,
    y: f64,
    size: f64,
    /// Every run on the line used a bold-named font.
    bold: bool,
    page: u32,
    /// Device x where the line starts.
    x: f64,
    /// Where each visually separate run begins: the table layer splits
    /// cell text on these.
    fragments: []const Fragment,
};

/// One visually separate run within a line: its device x and the byte
/// offset of its text within `Line.text`.
pub const Fragment = struct {
    x: f64,
    offset: u32,
};

/// A unique extracted image, registered once however often it is drawn.
pub const UniqueImage = struct {
    source: []const u8,
    bytes: []const u8,
    mime: []const u8,
};

/// One drawing of a unique image, anchored into the line flow.
pub const PlacedImage = struct {
    unique: u32,
    /// The image sits before `lines.items[insert_at]`.
    insert_at: u32,
};

/// The table lattice a page's painted rules support.
pub const PageGrid = struct {
    page: u32,
    grid: graphics.Grid,
};

const identity = [6]f64{ 1, 0, 0, 1, 0, 0 };

fn mul(a: [6]f64, b: [6]f64) [6]f64 {
    return .{
        a[0] * b[0] + a[1] * b[2],
        a[0] * b[1] + a[1] * b[3],
        a[2] * b[0] + a[3] * b[2],
        a[2] * b[1] + a[3] * b[3],
        a[4] * b[0] + a[5] * b[2] + b[4],
        a[4] * b[1] + a[5] * b[3] + b[5],
    };
}

const Frame = struct {
    lexer: objects.Lexer,
    resources: objects.Dict,
};

pub const Machine = struct {
    arena: std.mem.Allocator,
    file: *xref.File,
    limits: core.Limits,

    lines: std.ArrayList(Line) = .empty,
    /// Page heights in points, indexed by page number, recorded from each
    /// page's (inherited) MediaBox so layout facets can flip the bottom-up
    /// y axis to the top-left origin (ZDS 0013).
    page_heights: std.ArrayList(f64) = .empty,
    /// Fonts cached by their dictionary's object number; direct dicts get
    /// per-page instances.
    font_cache: std.AutoHashMapUnmanaged(u32, *fonts.Font) = .empty,
    default_font: fonts.Font = .{ .base = .win_ansi },
    unmappable: u32 = 0,
    /// Images met but NOT extracted (unsupported filter or color space).
    images: u32 = 0,

    // Extracted images and drawn-table evidence.
    unique_images: std.ArrayList(UniqueImage) = .empty,
    image_by_ref: std.AutoHashMapUnmanaged(u32, u32) = .empty,
    placed_images: std.ArrayList(PlacedImage) = .empty,
    paths: graphics.PathTracker = .{ .arena = undefined },
    grids: std.ArrayList(PageGrid) = .empty,

    // Text and graphics state.
    ctm: [6]f64 = identity,
    gs_stack: [max_graphics_stack][6]f64 = undefined,
    gs_depth: u32 = 0,
    tm: [6]f64 = identity,
    tlm: [6]f64 = identity,
    font: ?*fonts.Font = null,
    font_size: f64 = 0,
    leading: f64 = 0,
    /// Character spacing (Tc), word spacing (Tw), horizontal scale (Tz/100).
    char_spacing: f64 = 0,
    word_spacing: f64 = 0,
    horizontal_scale: f64 = 1,

    // The line being assembled.
    buf: std.ArrayList(u8) = .empty,
    frags: std.ArrayList(Fragment) = .empty,
    /// The next show starts a new fragment (a heuristic space was added).
    pending_fragment: bool = false,
    line_y: f64 = 0,
    line_size: f64 = 0,
    line_bold: bool = true,
    line_open: bool = false,
    line_page: u32 = 0,
    line_x: f64 = 0,
    /// Device-space pen position after the previous show, valid only when
    /// that show's font carried width metrics. Drives the join-or-space
    /// decision for the next show on the same baseline.
    pen_x: f64 = 0,
    pen_valid: bool = false,
    /// Where the previous show started; a forward jump past it splits a
    /// fragment even without width metrics (Tm-positioned table cells).
    last_show_x: f64 = 0,

    pub fn runPage(
        m: *Machine,
        content: []const u8,
        resources: objects.Dict,
        page: u32,
    ) Error!void {
        m.ctm = identity;
        m.gs_depth = 0;
        m.tm = identity;
        m.tlm = identity;
        m.font = null;
        m.font_size = 0;
        m.leading = 0;
        m.char_spacing = 0;
        m.word_spacing = 0;
        m.horizontal_scale = 1;
        m.pen_valid = false;
        try m.flushLine();
        m.line_page = page;
        m.paths.arena = m.arena;
        m.paths.reset();

        var frames: [max_form_depth]Frame = undefined;
        var depth: u32 = 0;
        frames[0] = .{ .lexer = objects.Lexer.init(m.arena, content), .resources = resources };
        var operands: [max_operands]objects.Object = undefined;
        var operand_count: u32 = 0;

        while (true) {
            const frame = &frames[depth];
            const token = frame.lexer.next() catch {
                if (depth == 0) break;
                depth -= 1;
                continue;
            };
            switch (token) {
                .eof => {
                    if (depth == 0) break;
                    depth -= 1;
                },
                .integer => |v| pushOperand(&operands, &operand_count, .{ .integer = v }),
                .real => |v| pushOperand(&operands, &operand_count, .{ .real = v }),
                .string => |v| pushOperand(&operands, &operand_count, .{ .string = v }),
                .name => |v| pushOperand(&operands, &operand_count, .{ .name = v }),
                .array_open, .dict_open => {
                    // Rewind and let the object parser collect the container.
                    frame.lexer.pos -= if (token == .dict_open) @as(usize, 2) else 1;
                    var parser: objects.Parser = .{
                        .lexer = &frame.lexer,
                        .arena = m.arena,
                        .max_depth = m.limits.max_depth,
                    };
                    const value = parser.parseObject() catch {
                        operand_count = 0;
                        continue;
                    };
                    pushOperand(&operands, &operand_count, value);
                },
                .array_close, .dict_close => operand_count = 0,
                .keyword => |word| {
                    const push_form = try m.operator(
                        word,
                        operands[0..operand_count],
                        frame,
                    );
                    operand_count = 0;
                    if (push_form) |form| {
                        if (depth + 1 < max_form_depth) {
                            depth += 1;
                            frames[depth] = form;
                        }
                    }
                },
            }
        }
        try m.flushLine();
        if (try graphics.detectGrid(
            m.arena,
            m.paths.horizontal.items,
            m.paths.vertical.items,
        )) |grid| {
            try m.grids.append(m.arena, .{ .page = page, .grid = grid });
        }
    }

    fn pushOperand(operands: []objects.Object, count: *u32, value: objects.Object) void {
        if (count.* >= max_operands) {
            // Malformed producers stack junk; keep the newest window.
            std.mem.copyForwards(
                objects.Object,
                operands[0 .. max_operands - 1],
                operands[1..max_operands],
            );
            count.* = max_operands - 1;
        }
        operands[count.*] = value;
        count.* += 1;
    }

    /// Executes one operator; returns a frame to push for form XObjects.
    fn operator(
        m: *Machine,
        word: []const u8,
        operands: []const objects.Object,
        frame: *Frame,
    ) Error!?Frame {
        const n = operands.len;
        if (eql(word, "q")) {
            if (m.gs_depth < max_graphics_stack) {
                m.gs_stack[m.gs_depth] = m.ctm;
                m.gs_depth += 1;
            }
        } else if (eql(word, "Q")) {
            if (m.gs_depth > 0) {
                m.gs_depth -= 1;
                m.ctm = m.gs_stack[m.gs_depth];
            }
        } else if (eql(word, "cm")) {
            if (numbers(operands, 6)) |v| m.ctm = mul(v, m.ctm);
        } else if (eql(word, "BT")) {
            m.tm = identity;
            m.tlm = identity;
            m.pen_valid = false;
        } else if (eql(word, "ET")) {
            // Lines continue across text objects; nothing to do.
        } else if (eql(word, "Tf")) {
            if (n == 2 and operands[0] == .name) {
                m.font_size = operands[1].asNumber() orelse m.font_size;
                m.font = try m.lookupFont(frame.resources, operands[0].name);
            }
        } else if (eql(word, "Td")) {
            if (numbers(operands, 2)) |v| m.textMove(v[0], v[1]);
        } else if (eql(word, "TD")) {
            if (numbers(operands, 2)) |v| {
                m.leading = -v[1];
                m.textMove(v[0], v[1]);
            }
        } else if (eql(word, "Tm")) {
            if (numbers(operands, 6)) |v| {
                m.tlm = v;
                m.tm = v;
            }
        } else if (eql(word, "T*")) {
            m.textMove(0, -m.leading);
        } else if (eql(word, "TL")) {
            if (numbers(operands, 1)) |v| m.leading = v[0];
        } else if (eql(word, "Tc")) {
            if (numbers(operands, 1)) |v| m.char_spacing = v[0];
        } else if (eql(word, "Tw")) {
            if (numbers(operands, 1)) |v| m.word_spacing = v[0];
        } else if (eql(word, "Tz")) {
            if (numbers(operands, 1)) |v| m.horizontal_scale = v[0] / 100.0;
        } else if (eql(word, "Tj")) {
            if (n == 1 and operands[0] == .string) try m.show(operands[0].string);
        } else if (eql(word, "'")) {
            m.textMove(0, -m.leading);
            if (n == 1 and operands[0] == .string) try m.show(operands[0].string);
        } else if (eql(word, "\"")) {
            if (numbers(operands[0..@min(n, 2)], 2)) |v| {
                m.word_spacing = v[0];
                m.char_spacing = v[1];
            }
            m.textMove(0, -m.leading);
            if (n == 3 and operands[2] == .string) try m.show(operands[2].string);
        } else if (eql(word, "TJ")) {
            if (n == 1 and operands[0] == .array) try m.showAdjusted(operands[0].array);
        } else if (eql(word, "Do")) {
            if (n == 1 and operands[0] == .name) return m.doXObject(frame, operands[0].name);
        } else if (eql(word, "BI")) {
            m.images += 1;
            skipInlineImage(&frame.lexer);
        } else if (eql(word, "m")) {
            if (numbers(operands, 2)) |v| {
                const p = m.devicePoint(v[0], v[1]);
                m.paths.moveTo(p[0], p[1]);
            }
        } else if (eql(word, "l")) {
            if (numbers(operands, 2)) |v| {
                const p = m.devicePoint(v[0], v[1]);
                m.paths.lineTo(p[0], p[1]);
            }
        } else if (eql(word, "re")) {
            if (numbers(operands, 4)) |v| {
                const a = m.devicePoint(v[0], v[1]);
                const b = m.devicePoint(v[0] + v[2], v[1] + v[3]);
                m.paths.rect(
                    @min(a[0], b[0]),
                    @min(a[1], b[1]),
                    @abs(b[0] - a[0]),
                    @abs(b[1] - a[1]),
                );
            }
        } else if (eql(word, "S") or eql(word, "s") or eql(word, "f") or
            eql(word, "F") or eql(word, "f*") or eql(word, "B") or
            eql(word, "B*") or eql(word, "b") or eql(word, "b*"))
        {
            try m.paths.paint(false);
        } else if (eql(word, "n")) {
            try m.paths.paint(true);
        }
        return null;
    }

    fn devicePoint(m: *Machine, x: f64, y: f64) [2]f64 {
        return .{
            m.ctm[0] * x + m.ctm[2] * y + m.ctm[4],
            m.ctm[1] * x + m.ctm[3] * y + m.ctm[5],
        };
    }

    fn eql(a: []const u8, b: []const u8) bool {
        return std.mem.eql(u8, a, b);
    }

    fn numbers(operands: []const objects.Object, comptime want: usize) ?[want]f64 {
        if (operands.len < want) return null;
        var out: [want]f64 = undefined;
        for (operands[operands.len - want ..], 0..) |operand, i| {
            out[i] = operand.asNumber() orelse return null;
        }
        return out;
    }

    fn textMove(m: *Machine, tx: f64, ty: f64) void {
        m.tlm = mul(.{ 1, 0, 0, 1, tx, ty }, m.tlm);
        m.tm = m.tlm;
        // Without width metrics the pen is unknown, so a forward jump on
        // the same baseline is the only spacing signal available. With a
        // valid pen, `show` measures the real gap instead.
        if (!m.pen_valid and m.line_open and ty == 0 and tx > 0) {
            if (m.buf.items.len > 0 and m.buf.items[m.buf.items.len - 1] != ' ') {
                m.buf.append(m.arena, ' ') catch {};
                m.pending_fragment = true;
            }
        }
    }

    fn lookupFont(m: *Machine, resources: objects.Dict, name: []const u8) Error!?*fonts.Font {
        const font_dicts = (try m.file.dictGet(resources, "Font")) orelse return null;
        const dict = font_dicts.asDict() orelse return null;
        const entry = dict.get(name) orelse return null;
        if (entry == .ref) {
            if (m.font_cache.get(entry.ref.num)) |cached| return cached;
        }
        const resolved = try m.file.resolve(entry);
        const font_dict = resolved.asDict() orelse return null;
        const font = try m.arena.create(fonts.Font);
        font.* = try fonts.load(m.file, m.arena, font_dict);
        if (entry == .ref) try m.font_cache.put(m.arena, entry.ref.num, font);
        return font;
    }

    fn doXObject(m: *Machine, frame: *Frame, name: []const u8) Error!?Frame {
        const xobjects = (try m.file.dictGet(frame.resources, "XObject")) orelse return null;
        const dict = xobjects.asDict() orelse return null;
        const entry = dict.get(name) orelse return null;
        const resolved = try m.file.resolve(entry);
        if (resolved != .stream) return null;
        const subtype = resolved.stream.dict.get("Subtype") orelse return null;
        if (subtype.isName("Image")) {
            try m.placeImage(entry, resolved.stream);
            return null;
        }
        if (!subtype.isName("Form")) return null;
        const data = try m.file.decodeStream(resolved.stream);
        const resources = blk: {
            if (try m.file.dictGet(resolved.stream.dict, "Resources")) |own| {
                if (own.asDict()) |own_dict| break :blk own_dict;
            }
            break :blk frame.resources;
        };
        return .{ .lexer = objects.Lexer.init(m.arena, data), .resources = resources };
    }

    /// Extracts an image XObject once per reference and anchors this
    /// drawing into the line flow. Unsupported encodings count as omitted.
    fn placeImage(m: *Machine, entry: objects.Object, stream: objects.Stream) Error!void {
        const cached: ?u32 = if (entry == .ref) m.image_by_ref.get(entry.ref.num) else null;
        const unique = cached orelse blk: {
            const extracted = images_mod.extract(m.file, stream) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => {
                    m.images += 1;
                    return;
                },
            } orelse {
                m.images += 1;
                return;
            };
            const index: u32 = @intCast(m.unique_images.items.len);
            const source = try std.fmt.allocPrint(m.arena, "pdf-image-{d}", .{index + 1});
            try m.unique_images.append(m.arena, .{
                .source = source,
                .bytes = extracted.bytes,
                .mime = extracted.mime,
            });
            if (entry == .ref) try m.image_by_ref.put(m.arena, entry.ref.num, index);
            break :blk index;
        };
        // The image lands between the lines already flushed and whatever
        // follows; an open line flushes first so the anchor is exact.
        try m.flushLine();
        try m.placed_images.append(m.arena, .{
            .unique = unique,
            .insert_at = @intCast(m.lines.items.len),
        });
    }

    fn show(m: *Machine, bytes: []const u8) Error!void {
        const device = mul(m.tm, m.ctm);
        const x = device[4];
        const y = device[5];
        const size = m.font_size * @max(@abs(device[3]), 0.01);
        const font = m.font orelse &m.default_font;

        if (m.line_open and @abs(y - m.line_y) > same_line_tolerance * @max(size, m.line_size)) {
            try m.flushLine();
        }
        var fragment_start = m.pending_fragment;
        m.pending_fragment = false;
        if (!m.line_open) {
            m.line_open = true;
            m.line_y = y;
            m.line_size = size;
            m.line_bold = true;
            m.line_x = x;
            fragment_start = true;
        } else if (m.pen_valid and font.has_widths) {
            // The pen knows where the previous show ended: a gap wider
            // than a sliver of the font size is a word break; anything
            // tighter joins directly (the `Dumm` + `y` case).
            const gap = x - m.pen_x;
            if (gap > join_gap_ratio * @max(size, m.line_size)) {
                if (m.buf.items.len > 0 and m.buf.items[m.buf.items.len - 1] != ' ') {
                    try m.buf.append(m.arena, ' ');
                }
                fragment_start = true;
            }
        } else {
            // Width-less font: the pen is only an estimate (default
            // glyph widths), so demand a full font-size jump before
            // splitting — a positioned table cell, not prose flow or a
            // kern-split word, whose gaps stay near zero.
            const jump = x - m.pen_x;
            if (jump > 1.0 * @max(size, m.line_size)) {
                if (m.buf.items.len > 0 and m.buf.items[m.buf.items.len - 1] != ' ') {
                    try m.buf.append(m.arena, ' ');
                }
                fragment_start = true;
            }
        }
        const before = m.buf.items.len;
        m.last_show_x = x;
        if (fragment_start) {
            try m.frags.append(m.arena, .{ .x = x, .offset = @intCast(before) });
        }
        try font.decode(m.arena, bytes, &m.buf);
        if (m.buf.items.len > before) {
            m.line_size = @max(m.line_size, size);
            if (!font.bold) m.line_bold = false;
        }
        m.unmappable += font.unmappable;
        font.unmappable = 0;

        // Advance the pen by the string's measured width.
        const advance = font.advanceOf(
            bytes,
            m.font_size,
            m.char_spacing,
            m.word_spacing,
        ) * m.horizontal_scale;
        m.tm = mul(.{ 1, 0, 0, 1, advance, 0 }, m.tm);
        m.pen_x = mul(m.tm, m.ctm)[4];
        m.pen_valid = font.has_widths;
    }

    fn showAdjusted(m: *Machine, items: []const objects.Object) Error!void {
        const font = m.font orelse &m.default_font;
        for (items) |item| switch (item) {
            .string => |bytes| try m.show(bytes),
            .integer, .real => {
                const adjust = item.asNumber() orelse continue;
                if (font.has_widths) {
                    // Metric path: the adjustment moves where the next
                    // glyph starts, while the pen stays at the end of the
                    // drawn text — the next show's gap check sees the
                    // difference and decides about the space.
                    const tx = -adjust / 1000.0 * m.font_size * m.horizontal_scale;
                    m.tm = mul(.{ 1, 0, 0, 1, tx, 0 }, m.tm);
                } else if (adjust <= tj_space_threshold and m.line_open) {
                    // Fallback for width-less fonts.
                    if (m.buf.items.len > 0 and m.buf.items[m.buf.items.len - 1] != ' ') {
                        try m.buf.append(m.arena, ' ');
                        m.pending_fragment = true;
                    }
                }
            },
            else => {},
        };
    }

    pub fn flushLine(m: *Machine) Error!void {
        if (!m.line_open) return;
        m.line_open = false;
        m.pen_valid = false;
        m.pending_fragment = false;
        const trim_start = std.mem.indexOfNone(u8, m.buf.items, " \t\r\n") orelse m.buf.items.len;
        const trimmed = std.mem.trim(u8, m.buf.items, " \t\r\n");
        if (trimmed.len > 0) {
            // Fragment offsets shift with the leading trim and clamp to
            // the kept text.
            var fragments: std.ArrayList(Fragment) = .empty;
            for (m.frags.items) |fragment| {
                const shifted = fragment.offset -| @as(u32, @intCast(trim_start));
                if (shifted >= trimmed.len) continue;
                if (fragments.items.len > 0 and
                    fragments.items[fragments.items.len - 1].offset == shifted) continue;
                try fragments.append(m.arena, .{ .x = fragment.x, .offset = shifted });
            }
            try m.lines.append(m.arena, .{
                .text = try m.arena.dupe(u8, trimmed),
                .y = m.line_y,
                .size = m.line_size,
                .bold = m.line_bold,
                .page = m.line_page,
                .x = m.line_x,
                .fragments = fragments.items,
            });
        }
        m.buf.clearRetainingCapacity();
        m.frags.clearRetainingCapacity();
    }
};

/// After `BI`: the image dictionary and binary data run to `EI`. The data
/// may contain any bytes, so `EI` must be whitespace-delimited.
fn skipInlineImage(lexer: *objects.Lexer) void {
    const bytes = lexer.bytes;
    var i = lexer.pos;
    while (i + 2 <= bytes.len) : (i += 1) {
        if (bytes[i] == 'E' and bytes[i + 1] == 'I') {
            const before_ok = i == 0 or objects.isWhite(bytes[i - 1]);
            const after_ok = i + 2 >= bytes.len or objects.isWhite(bytes[i + 2]);
            if (before_ok and after_ok) {
                lexer.pos = i + 2;
                return;
            }
        }
    }
    lexer.pos = bytes.len;
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

fn runContent(arena: std.mem.Allocator, content: []const u8) !std.ArrayList(Line) {
    var file = xref.File{ .arena = arena, .bytes = "", .limits = .{} };
    var machine = Machine{ .arena = arena, .file = &file, .limits = .{} };
    try machine.runPage(content, .{}, 0);
    return machine.lines;
}

/// Resources with one Type1 font `/F1` whose glyphs are all 500/1000 wide
/// from code 32 upward — a fixed-pitch stand-in with real `/Widths` data.
fn monoResources(arena: std.mem.Allocator) !objects.Dict {
    const widths = try arena.alloc(objects.Object, 96);
    for (widths) |*entry| entry.* = .{ .integer = 500 };
    const font_entries = try arena.dupe(objects.DictEntry, &.{
        .{ .key = "Type", .value = .{ .name = "Font" } },
        .{ .key = "Subtype", .value = .{ .name = "Type1" } },
        .{ .key = "FirstChar", .value = .{ .integer = 32 } },
        .{ .key = "Widths", .value = .{ .array = widths } },
    });
    const fonts_entries = try arena.dupe(objects.DictEntry, &.{
        .{ .key = "F1", .value = .{ .dict = .{ .entries = font_entries } } },
    });
    const resource_entries = try arena.dupe(objects.DictEntry, &.{
        .{ .key = "Font", .value = .{ .dict = .{ .entries = fonts_entries } } },
    });
    return .{ .entries = resource_entries };
}

fn runContentWithFonts(arena: std.mem.Allocator, content: []const u8) !std.ArrayList(Line) {
    var file = xref.File{ .arena = arena, .bytes = "", .limits = .{} };
    var machine = Machine{ .arena = arena, .file = &file, .limits = .{} };
    try machine.runPage(content, try monoResources(arena), 0);
    return machine.lines;
}

test "width metrics join split shows without spurious spaces" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // "Dumm" is 4 × 500/1000 × 10 = 20 wide; the Td lands the next show
    // exactly at the pen, so the word joins seamlessly.
    const lines = try runContentWithFonts(arena, "BT /F1 10 Tf 100 700 Td (Dumm) Tj 20 0 Td (y) Tj ET");
    try testing.expectEqual(@as(usize, 1), lines.items.len);
    try testing.expectEqualStrings("Dummy", lines.items[0].text);
}

test "width metrics insert exactly one space across a word gap" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // "Hello" ends at 100 + 25; the next show starts at 130, a 5pt gap —
    // half the font size, clearly a word break.
    const lines = try runContentWithFonts(arena, "BT /F1 10 Tf 100 700 Td (Hello) Tj 30 0 Td (world) Tj ET");
    try testing.expectEqual(@as(usize, 1), lines.items.len);
    try testing.expectEqualStrings("Hello world", lines.items[0].text);
}

test "TJ adjustments move the pen instead of forcing spaces" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // -100/1000 × 10 = 1pt of kerning: too tight for a word break with
    // metrics, so the split word stays joined; a -700 adjustment (7pt)
    // reads as a space.
    const lines = try runContentWithFonts(arena, "BT /F1 10 Tf 100 700 Td [(ker) -100 (ning) -700 (gap)] TJ ET");
    try testing.expectEqual(@as(usize, 1), lines.items.len);
    try testing.expectEqualStrings("kerning gap", lines.items[0].text);
}

test "Td line breaks split shows into lines" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const lines = try runContent(arena, "BT /F1 12 Tf 72 720 Td (First line) Tj 0 -14 Td (Second line) Tj ET");
    try testing.expectEqual(@as(usize, 2), lines.items.len);
    try testing.expectEqualStrings("First line", lines.items[0].text);
    try testing.expectEqualStrings("Second line", lines.items[1].text);
    try testing.expect(lines.items[0].y > lines.items[1].y);
}

test "TJ kerning gaps become spaces" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const lines = try runContent(arena, "BT /F1 12 Tf 72 720 Td [(Hello) -250 (world) -20 (!)] TJ ET");
    try testing.expectEqual(@as(usize, 1), lines.items.len);
    try testing.expectEqualStrings("Hello world!", lines.items[0].text);
}

test "inline images are skipped without derailing the lexer" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const lines = try runContent(arena, "BT /F1 10 Tf 10 10 Td (before) Tj ET " ++
        "BI /W 2 /H 2 ID \x00\x11)Tj junk EI " ++
        "BT /F1 10 Tf 10 30 Td (after) Tj ET");
    try testing.expectEqual(@as(usize, 2), lines.items.len);
    try testing.expectEqualStrings("before", lines.items[0].text);
    try testing.expectEqualStrings("after", lines.items[1].text);
}
