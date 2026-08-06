//! PDF font text decoding (ZDS: pdf-reader).
//!
//! Per-font code→Unicode mapping, in fidelity order: an embedded
//! `/ToUnicode` CMap when present (`bfchar` and `bfrange`, including array
//! destinations), else the base encoding named by `/Encoding` with
//! `/Differences` applied through the glyph-name subset. Type0 fonts show
//! two-byte codes; a Type0 font with neither ToUnicode nor an Identity
//! mapping counts its characters as unmappable rather than guessing.

const std = @import("std");
const assert = std.debug.assert;
const core = @import("zenfmt_core");
const objects = @import("objects.zig");
const xref = @import("xref.zig");
const glyphs = @import("glyphs.zig");

pub const Error = xref.Error;

/// Entries one ToUnicode CMap may define; bounds hostile range floods.
const max_cmap_entries = 1 << 16;

pub const Font = struct {
    /// Codes are two bytes wide (Type0 composite fonts).
    two_byte: bool = false,
    base: glyphs.Base = .standard,
    /// `/Differences` overrides, code → code point (0 = none).
    diffs: [256]u21 = @splat(0),
    has_diffs: bool = false,
    /// ToUnicode map: code → UTF-8 bytes.
    to_unicode: std.AutoHashMapUnmanaged(u32, []const u8) = .empty,
    has_to_unicode: bool = false,
    /// The font name has a bold face marker (`/F1,Bold`, `-BoldItalic`).
    bold: bool = false,
    /// Characters that failed to map, counted for one report.
    unmappable: u32 = 0,

    /// Width metrics, in thousandths of text space. `has_widths` gates the
    /// pen-position spacing model; without it the reader falls back to the
    /// TJ kerning heuristic.
    has_widths: bool = false,
    first_char: u32 = 0,
    simple_widths: []const f64 = &.{},
    /// `/MissingWidth` (simple) or `/DW` (CID); 500 is the classic default
    /// for simple fonts, 1000 for CID fonts.
    default_width: f64 = 500,
    cid_ranges: []const CidRange = &.{},

    pub const CidRange = struct { first: u32, last: u32, width: f64 };

    /// One glyph's width in thousandths.
    pub fn glyphWidth(font: *const Font, code: u32) f64 {
        if (!font.two_byte) {
            if (code >= font.first_char) {
                const index = code - font.first_char;
                if (index < font.simple_widths.len) return font.simple_widths[index];
            }
            return font.default_width;
        }
        for (font.cid_ranges) |range| {
            if (code >= range.first and code <= range.last) return range.width;
        }
        return font.default_width;
    }

    /// Total advance of one show string, in text-space units: per glyph,
    /// width/1000 × size + character spacing, plus word spacing on the
    /// single-byte space code.
    pub fn advanceOf(font: *const Font, bytes: []const u8, size: f64, tc: f64, tw: f64) f64 {
        const step: usize = if (font.two_byte) 2 else 1;
        var total: f64 = 0;
        var i: usize = 0;
        while (i + step <= bytes.len) : (i += step) {
            const code: u32 = if (font.two_byte)
                (@as(u32, bytes[i]) << 8) | bytes[i + 1]
            else
                bytes[i];
            total += font.glyphWidth(code) / 1000.0 * size + tc;
            if (!font.two_byte and code == ' ') total += tw;
        }
        return total;
    }

    /// Decodes one show-string into UTF-8.
    pub fn decode(
        font: *Font,
        arena: std.mem.Allocator,
        bytes: []const u8,
        out: *std.ArrayList(u8),
    ) Error!void {
        const step: usize = if (font.two_byte) 2 else 1;
        var i: usize = 0;
        while (i + step <= bytes.len) : (i += step) {
            const code: u32 = if (font.two_byte)
                (@as(u32, bytes[i]) << 8) | bytes[i + 1]
            else
                bytes[i];
            if (font.has_to_unicode) {
                if (font.to_unicode.get(code)) |utf8| {
                    try out.appendSlice(arena, utf8);
                    continue;
                }
            }
            if (!font.two_byte) {
                const byte: u8 = @truncate(code);
                const cp: u21 = if (font.has_diffs and font.diffs[byte] != 0)
                    font.diffs[byte]
                else
                    glyphs.baseChar(font.base, byte);
                if (cp != 0) {
                    try appendCodePoint(arena, out, cp);
                    continue;
                }
            }
            font.unmappable += 1;
        }
    }
};

fn appendCodePoint(arena: std.mem.Allocator, out: *std.ArrayList(u8), cp: u21) Error!void {
    var buffer: [4]u8 = undefined;
    const len = std.unicode.utf8Encode(cp, &buffer) catch return;
    try out.appendSlice(arena, buffer[0..len]);
}

/// Builds a Font from a `/Font` resource dictionary.
pub fn load(file: *xref.File, arena: std.mem.Allocator, dict: objects.Dict) Error!Font {
    var font: Font = .{};

    if (try file.dictGet(dict, "Subtype")) |subtype| {
        if (subtype.isName("Type0")) font.two_byte = true;
    }
    if (try file.dictGet(dict, "BaseFont")) |base_font| {
        if (base_font == .name) {
            font.bold = std.ascii.indexOfIgnoreCase(base_font.name, "bold") != null;
            // Symbolic bases have no meaningful Latin mapping.
            if (std.mem.indexOf(u8, base_font.name, "Symbol") != null or
                std.mem.indexOf(u8, base_font.name, "Dingbats") != null)
            {
                font.base = .standard;
            }
        }
    }
    if (try file.dictGet(dict, "ToUnicode")) |to_unicode| {
        if (to_unicode == .stream) {
            const data = try file.decodeStream(to_unicode.stream);
            try parseCMap(arena, data, &font);
        }
    }
    try loadWidths(file, arena, dict, &font);
    if (try file.dictGet(dict, "Encoding")) |encoding| switch (encoding) {
        .name => |name| font.base = baseFromName(name),
        .dict => |enc_dict| {
            if (try file.dictGet(enc_dict, "BaseEncoding")) |base_name| {
                if (base_name == .name) font.base = baseFromName(base_name.name);
            }
            if (try file.dictGet(enc_dict, "Differences")) |diffs| {
                if (diffs == .array) applyDifferences(&font, diffs.array);
            }
        },
        else => {},
    };
    return font;
}

/// Simple fonts: `/FirstChar` + `/Widths` (+ `/MissingWidth`). Type0:
/// `/DescendantFonts` → `/DW` default and the `/W` ranges-and-lists array.
fn loadWidths(
    file: *xref.File,
    arena: std.mem.Allocator,
    dict: objects.Dict,
    font: *Font,
) Error!void {
    if (!font.two_byte) {
        if (try file.dictGet(dict, "FontDescriptor")) |fd| {
            if (fd.asDict()) |fd_dict| {
                if (try file.dictGet(fd_dict, "MissingWidth")) |mw| {
                    if (mw.asNumber()) |value| font.default_width = value;
                }
            }
        }
        const widths_obj = (try file.dictGet(dict, "Widths")) orelse return;
        if (widths_obj != .array) return;
        if (try file.dictGet(dict, "FirstChar")) |fc| {
            if (fc.asInt()) |value| {
                if (value >= 0 and value < 256) font.first_char = @intCast(value);
            }
        }
        const widths = try arena.alloc(f64, @min(widths_obj.array.len, 256));
        for (widths, widths_obj.array[0..widths.len]) |*out, entry| {
            const resolved = file.resolve(entry) catch @as(objects.Object, .null);
            out.* = resolved.asNumber() orelse font.default_width;
        }
        font.simple_widths = widths;
        font.has_widths = widths.len > 0;
        return;
    }
    const descendants = (try file.dictGet(dict, "DescendantFonts")) orelse return;
    if (descendants != .array or descendants.array.len == 0) return;
    const descendant = try file.resolve(descendants.array[0]);
    const dd = descendant.asDict() orelse return;
    font.default_width = 1000;
    if (try file.dictGet(dd, "DW")) |dw| {
        if (dw.asNumber()) |value| {
            font.default_width = value;
            font.has_widths = true;
        }
    }
    if (try file.dictGet(dd, "W")) |w| {
        if (w == .array) {
            font.cid_ranges = try parseCidWidths(file, arena, w.array);
            font.has_widths = true;
        }
    }
}

/// `/W [ c [w1 w2 ...]  cfirst clast w  ... ]`, both forms interleaved.
fn parseCidWidths(
    file: *xref.File,
    arena: std.mem.Allocator,
    items: []const objects.Object,
) Error![]const Font.CidRange {
    var ranges: std.ArrayList(Font.CidRange) = .empty;
    var i: usize = 0;
    while (i < items.len and ranges.items.len < max_cmap_entries) {
        const first = (try file.resolve(items[i])).asInt() orelse break;
        i += 1;
        if (i >= items.len or first < 0) break;
        const second = try file.resolve(items[i]);
        i += 1;
        if (second == .array) {
            for (second.array, 0..) |entry, j| {
                if (ranges.items.len >= max_cmap_entries) break;
                const width = (file.resolve(entry) catch @as(objects.Object, .null)).asNumber() orelse
                    continue;
                const code: u32 = @intCast(@min(first + @as(i64, @intCast(j)), 1 << 20));
                try ranges.append(arena, .{ .first = code, .last = code, .width = width });
            }
            continue;
        }
        const last = second.asInt() orelse break;
        if (i >= items.len or last < first) break;
        const width = (try file.resolve(items[i])).asNumber() orelse break;
        i += 1;
        try ranges.append(arena, .{
            .first = @intCast(first),
            .last = @intCast(last),
            .width = width,
        });
    }
    return ranges.toOwnedSlice(arena);
}

fn baseFromName(name: []const u8) glyphs.Base {
    if (std.mem.eql(u8, name, "WinAnsiEncoding")) return .win_ansi;
    if (std.mem.eql(u8, name, "MacRomanEncoding")) return .mac_roman;
    return .standard;
}

/// `/Differences [ code /name /name code /name ... ]`.
fn applyDifferences(font: *Font, entries: []const objects.Object) void {
    var code: u32 = 0;
    for (entries) |entry| switch (entry) {
        .integer => |value| {
            if (value >= 0 and value < 256) code = @intCast(value);
        },
        .name => |name| {
            if (code < 256) {
                if (glyphs.glyphToUnicode(name)) |cp| {
                    font.diffs[code] = cp;
                    font.has_diffs = true;
                }
                code += 1;
            }
        },
        else => {},
    };
}

const CMapMode = enum { scan, bfchar, bfrange };

/// Parses the `bfchar`/`bfrange` sections of a ToUnicode CMap. The CMap is
/// PostScript-flavored, but the mapping operators use plain object syntax.
fn parseCMap(arena: std.mem.Allocator, data: []const u8, font: *Font) Error!void {
    var lexer = objects.Lexer.init(arena, data);
    var mode: CMapMode = .scan;
    var pending: [3]objects.Object = undefined;
    var pending_len: usize = 0;
    while (true) {
        const token = lexer.next() catch break;
        switch (token) {
            .eof => break,
            .keyword => |word| {
                if (std.mem.eql(u8, word, "beginbfchar")) {
                    mode = .bfchar;
                    pending_len = 0;
                } else if (std.mem.eql(u8, word, "beginbfrange")) {
                    mode = .bfrange;
                    pending_len = 0;
                } else if (std.mem.eql(u8, word, "endbfchar") or
                    std.mem.eql(u8, word, "endbfrange"))
                {
                    mode = .scan;
                }
            },
            .string => |value| try cmapOperand(arena, font, &mode, &pending, &pending_len, .{ .string = value }),
            .array_open => {
                // Only bfrange uses arrays: collect destination strings.
                if (mode != .bfrange or pending_len != 2) continue;
                try bfrangeArray(arena, &lexer, font, pending);
                pending_len = 0;
            },
            else => {},
        }
    }
}

fn cmapOperand(
    arena: std.mem.Allocator,
    font: *Font,
    mode: *CMapMode,
    pending: *[3]objects.Object,
    pending_len: *usize,
    value: objects.Object,
) Error!void {
    switch (mode.*) {
        .scan => {},
        .bfchar => {
            pending[pending_len.*] = value;
            pending_len.* += 1;
            if (pending_len.* == 2) {
                pending_len.* = 0;
                const src = stringCode(pending[0]) orelse return;
                try putMapping(arena, font, src, pending[1]);
            }
        },
        .bfrange => {
            pending[pending_len.*] = value;
            pending_len.* += 1;
            if (pending_len.* == 3) {
                pending_len.* = 0;
                const lo = stringCode(pending[0]) orelse return;
                const hi = stringCode(pending[1]) orelse return;
                if (hi < lo or hi - lo >= max_cmap_entries) return;
                var code = lo;
                var dst_cp = stringToCodePoint(pending[2]) orelse return;
                while (code <= hi) : (code += 1) {
                    var buffer: [4]u8 = undefined;
                    const len = std.unicode.utf8Encode(dst_cp, &buffer) catch return;
                    try putUtf8(arena, font, code, buffer[0..len]);
                    if (dst_cp < 0x10ffff) dst_cp += 1;
                    if (code == hi) break;
                }
            }
        },
    }
}

/// `<lo> <hi> [ <dst> <dst> ... ]` — one destination string per code.
fn bfrangeArray(
    arena: std.mem.Allocator,
    lexer: *objects.Lexer,
    font: *Font,
    pending: [3]objects.Object,
) Error!void {
    const lo = stringCode(pending[0]) orelse return;
    const hi = stringCode(pending[1]) orelse return;
    if (hi < lo or hi - lo >= max_cmap_entries) return;
    var code = lo;
    var guard: u32 = 0;
    while (guard < max_cmap_entries) : (guard += 1) {
        const token = lexer.next() catch return;
        switch (token) {
            .array_close, .eof => return,
            .string => |dst| {
                if (code <= hi) try putMapping(arena, font, code, .{ .string = dst });
                if (code < hi) code += 1;
            },
            else => {},
        }
    }
}

fn putMapping(
    arena: std.mem.Allocator,
    font: *Font,
    code: u32,
    dst: objects.Object,
) Error!void {
    if (dst != .string) return;
    // Destination strings are UTF-16BE, possibly several code units.
    var utf8: std.ArrayList(u8) = .empty;
    const units = dst.string;
    var i: usize = 0;
    while (i + 2 <= units.len) {
        const unit = (@as(u21, units[i]) << 8) | units[i + 1];
        i += 2;
        var cp: u21 = unit;
        if (unit >= 0xd800 and unit <= 0xdbff and i + 2 <= units.len) {
            const low = (@as(u21, units[i]) << 8) | units[i + 1];
            if (low >= 0xdc00 and low <= 0xdfff) {
                i += 2;
                cp = 0x10000 + ((@as(u21, unit - 0xd800) << 10) | (low - 0xdc00));
            }
        }
        var buffer: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(cp, &buffer) catch continue;
        try utf8.appendSlice(arena, buffer[0..len]);
    }
    if (utf8.items.len > 0) try putUtf8(arena, font, code, utf8.items);
}

fn putUtf8(arena: std.mem.Allocator, font: *Font, code: u32, utf8: []const u8) Error!void {
    if (font.to_unicode.count() >= max_cmap_entries) return;
    const copy = try arena.dupe(u8, utf8);
    try font.to_unicode.put(arena, code, copy);
    font.has_to_unicode = true;
}

fn stringCode(value: objects.Object) ?u32 {
    if (value != .string) return null;
    const s = value.string;
    if (s.len == 0 or s.len > 4) return null;
    var code: u32 = 0;
    for (s) |byte| code = (code << 8) | byte;
    return code;
}

fn stringToCodePoint(value: objects.Object) ?u21 {
    if (value != .string) return null;
    const s = value.string;
    if (s.len == 2) {
        const unit = (@as(u21, s[0]) << 8) | s[1];
        return unit;
    }
    if (s.len == 4) {
        const high = (@as(u32, s[0]) << 8) | s[1];
        const low = (@as(u32, s[2]) << 8) | s[3];
        if (high >= 0xd800 and high <= 0xdbff and low >= 0xdc00 and low <= 0xdfff) {
            return @intCast(0x10000 + (((high - 0xd800) << 10) | (low - 0xdc00)));
        }
        return null;
    }
    if (s.len == 1) return s[0];
    return null;
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

test "bfchar and bfrange mappings decode" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var font: Font = .{ .two_byte = true };
    const cmap =
        "/CIDInit /ProcSet findresource begin\n" ++
        "begincmap\n" ++
        "2 beginbfchar\n<0041> <0048>\n<0042> <0065006C>\nendbfchar\n" ++
        "1 beginbfrange\n<0050> <0052> <006C>\nendbfrange\n" ++
        "endcmap\n";
    try parseCMap(arena, cmap, &font);

    var out: std.ArrayList(u8) = .empty;
    try font.decode(arena, &.{ 0x00, 0x41, 0x00, 0x42, 0x00, 0x50, 0x00, 0x51, 0x00, 0x52 }, &out);
    try testing.expectEqualStrings("Hellmn", out.items);
}

test "cid W array parses both forms and DW defaults" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var file = xref.File{ .arena = arena, .bytes = "", .limits = .{} };
    // /W [ 1 [500 600] 10 12 750 ]
    const list = [_]objects.Object{ .{ .integer = 500 }, .{ .integer = 600 } };
    const w = [_]objects.Object{
        .{ .integer = 1 },
        .{ .array = &list },
        .{ .integer = 10 },
        .{ .integer = 12 },
        .{ .integer = 750 },
    };
    var font: Font = .{ .two_byte = true, .default_width = 1000 };
    font.cid_ranges = try parseCidWidths(&file, arena, &w);
    font.has_widths = true;
    try testing.expectEqual(@as(f64, 500), font.glyphWidth(1));
    try testing.expectEqual(@as(f64, 600), font.glyphWidth(2));
    try testing.expectEqual(@as(f64, 750), font.glyphWidth(11));
    try testing.expectEqual(@as(f64, 1000), font.glyphWidth(3));
}

test "simple widths and advance accumulate" {
    var font: Font = .{ .first_char = 65, .has_widths = true };
    font.simple_widths = &.{ 700, 300 }; // A=700, B=300
    try testing.expectEqual(@as(f64, 700), font.glyphWidth('A'));
    try testing.expectEqual(@as(f64, 500), font.glyphWidth('Z'));
    // "AB " at size 10 with tc=1, tw=2: 7 + 1 + 3 + 1 + 5 + 1 + 2 = 20.
    try testing.expectApproxEqAbs(
        @as(f64, 20),
        font.advanceOf("AB ", 10, 1, 2),
        1e-9,
    );
}

test "differences override the base encoding" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var font: Font = .{ .base = .win_ansi };
    applyDifferences(&font, &.{
        .{ .integer = 65 },
        .{ .name = "eacute" },
        .{ .name = "Euro" },
    });
    var out: std.ArrayList(u8) = .empty;
    try font.decode(arena, "AB Z", &out);
    try testing.expectEqualStrings("é€ Z", out.items);
}
