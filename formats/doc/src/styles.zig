//! DOC paragraph style resolution: the STSH stylesheet names the styles,
//! the PlcfBtePapx maps file positions to PAPX formatting pages, and the
//! page's grpprl leads with the paragraph's style index. Only heading
//! styles are projected; anything malformed degrades to "no styles" and
//! the reader keeps its plain-paragraph behavior with a note.

const std = @import("std");
const assert = std.debug.assert;

/// fcStshf/lcbStshf: pair 1 of the FIB fc/lcb table.
const fc_stshf_offset = 154 + 1 * 8;
/// fcPlcfBtePapx/lcbPlcfBtePapx: pair 13.
const fc_bte_papx_offset = 154 + 13 * 8;

const fkp_page_len = 512;
/// A PAPX FKP holds at most 29 paragraphs: (cpara+1)*4 + cpara*13 <= 511.
const max_fkp_paragraphs = 29;
const max_styles = 4096;
/// Style names longer than this are noise, not names.
const max_style_name_len = 64;

pub const Resolver = struct {
    /// Heading level per style index; 0 marks a non-heading style.
    levels: []const u8,
    /// Style name per style index; empty when unnamed or non-ASCII. Same
    /// length as `levels`.
    names: []const []const u8,
    /// PlcfBtePapx boundaries (n+1 file positions) and n page numbers.
    fcs: []const u32,
    pages: []const u32,
    word: []const u8,

    pub const empty: Resolver = .{
        .levels = &.{},
        .names = &.{},
        .fcs = &.{},
        .pages = &.{},
        .word = &.{},
    };

    pub fn active(r: *const Resolver) bool {
        return r.levels.len > 0 and r.fcs.len > 1;
    }

    /// The heading level of the paragraph containing `fc`, or 0. Any
    /// character position inside the paragraph works: FKP intervals are
    /// paragraph boundaries.
    pub fn headingLevel(r: *const Resolver, fc: u64) u8 {
        if (!r.active()) return 0;
        const istd = r.istdForFc(fc) orelse return 0;
        if (istd >= r.levels.len) return 0;
        return r.levels[istd];
    }

    /// The stylesheet name of the paragraph's style, when the paragraph
    /// names a non-default style with a readable name. Index 0 is the
    /// default style and stays unnamed on purpose: attaching "Normal" to
    /// every paragraph would be facet noise, not information.
    pub fn styleName(r: *const Resolver, fc: u64) ?[]const u8 {
        if (!r.active()) return null;
        assert(r.names.len == r.levels.len);
        const istd = r.istdForFc(fc) orelse return null;
        if (istd == 0 or istd >= r.names.len) return null;
        const name = r.names[istd];
        return if (name.len > 0) name else null;
    }

    fn istdForFc(r: *const Resolver, fc: u64) ?u16 {
        assert(r.fcs.len == r.pages.len + 1);
        if (fc < r.fcs[0] or fc >= r.fcs[r.fcs.len - 1]) return null;
        // Binary search the page interval, then the paragraph interval.
        var lo: usize = 0;
        var hi: usize = r.pages.len;
        while (lo + 1 < hi) {
            const mid = lo + (hi - lo) / 2;
            if (fc < r.fcs[mid]) hi = mid else lo = mid;
        }
        const pn = r.pages[lo] & 0x3FFFFF;
        const offset = @as(u64, pn) * fkp_page_len;
        if (offset + fkp_page_len > r.word.len) return null;
        const page = r.word[@intCast(offset)..][0..fkp_page_len];

        const cpara = page[fkp_page_len - 1];
        if (cpara == 0 or cpara > max_fkp_paragraphs) return null;
        var index: ?usize = null;
        for (0..cpara) |i| {
            const start = readInt(u32, page[i * 4 ..][0..4]);
            const end = readInt(u32, page[(i + 1) * 4 ..][0..4]);
            if (fc >= start and fc < end) {
                index = i;
                break;
            }
        }
        const i = index orelse return null;
        const b_offset = page[(cpara + 1) * 4 + i * 13];
        // No PAPX: the paragraph uses the default style.
        if (b_offset == 0) return 0;
        const papx = @as(usize, b_offset) * 2;
        if (papx + 1 >= fkp_page_len) return null;
        // PapxInFkp: a zero cb byte defers to a second length byte; the
        // grpprl leads with the istd either way.
        const istd_at = if (page[papx] == 0) papx + 2 else papx + 1;
        if (istd_at + 2 > fkp_page_len) return null;
        return readInt(u16, page[istd_at..][0..2]);
    }
};

/// Builds a resolver from the FIB's stylesheet and PAPX bin table. Any
/// inconsistency yields the inactive resolver, never a crash.
pub fn parse(
    arena: std.mem.Allocator,
    word: []const u8,
    table: []const u8,
) error{OutOfMemory}!Resolver {
    if (word.len < fc_bte_papx_offset + 8) return .empty;
    const stsh = try parseStsh(arena, word, table) orelse return .empty;
    const levels = stsh.levels;

    const fc_bte = readInt(u32, word[fc_bte_papx_offset..][0..4]);
    const lcb_bte = readInt(u32, word[fc_bte_papx_offset + 4 ..][0..4]);
    if (lcb_bte < 4 + 8 or @as(u64, fc_bte) + lcb_bte > table.len) return .empty;
    const plc = table[fc_bte..][0..lcb_bte];
    const count = (lcb_bte - 4) / 8;
    const fcs = try arena.alloc(u32, count + 1);
    const pages = try arena.alloc(u32, count);
    for (fcs, 0..) |*fc, i| fc.* = readInt(u32, plc[i * 4 ..][0..4]);
    for (pages, 0..) |*page, i| {
        page.* = readInt(u32, plc[(count + 1 + @as(u32, @intCast(i))) * 4 ..][0..4]);
    }
    for (fcs[0 .. fcs.len - 1], fcs[1..]) |a, b| {
        if (b < a) return .empty;
    }
    return .{
        .levels = levels,
        .names = stsh.names,
        .fcs = fcs,
        .pages = pages,
        .word = word,
    };
}

const Stsh = struct {
    levels: []const u8,
    names: []const []const u8,
};

/// The STSH: an LPStshi header, then one LPStd per style index. A style
/// is a heading when its built-in identifier is 1..9 or its name reads
/// "heading N"; every readable ASCII name is also kept for the style
/// facet.
fn parseStsh(
    arena: std.mem.Allocator,
    word: []const u8,
    table: []const u8,
) error{OutOfMemory}!?Stsh {
    const fc = readInt(u32, word[fc_stshf_offset..][0..4]);
    const lcb = readInt(u32, word[fc_stshf_offset + 4 ..][0..4]);
    if (lcb < 6 or @as(u64, fc) + lcb > table.len) return null;
    const stsh = table[fc..][0..lcb];
    const cb_stshi = readInt(u16, stsh[0..2]);
    if (cb_stshi < 4 or 2 + @as(usize, cb_stshi) > stsh.len) return null;
    const cstd = readInt(u16, stsh[2..4]);
    const cb_std_base = readInt(u16, stsh[4..6]);
    if (cstd == 0 or cstd > max_styles or cb_std_base < 4) return null;

    const levels = try arena.alloc(u8, cstd);
    @memset(levels, 0);
    const names = try arena.alloc([]const u8, cstd);
    @memset(names, "");
    var pos: usize = 2 + cb_stshi;
    for (levels, names) |*level, *name| {
        pos += pos % 2; // LPStd elements are 2-byte aligned.
        if (pos + 2 > stsh.len) break;
        const cb_std = readInt(u16, stsh[pos..][0..2]);
        pos += 2;
        if (cb_std == 0) continue;
        if (pos + cb_std > stsh.len) break;
        const std_bytes = stsh[pos..][0..cb_std];
        pos += cb_std;
        level.* = headingLevelOfStd(std_bytes, cb_std_base);
        name.* = try styleNameOfStd(arena, std_bytes, cb_std_base);
    }
    return .{ .levels = levels, .names = names };
}

/// The style's Xst name as ASCII, or "" when absent, oversized, or not
/// printable ASCII. Non-ASCII names are skipped rather than mangled: the
/// facet carries names, not guesses.
fn styleNameOfStd(
    arena: std.mem.Allocator,
    std_bytes: []const u8,
    cb_std_base: u16,
) error{OutOfMemory}![]const u8 {
    if (std_bytes.len < @as(usize, cb_std_base) + 2) return "";
    const cch = readInt(u16, std_bytes[cb_std_base..][0..2]);
    if (cch == 0 or cch > max_style_name_len) return "";
    const name_at = @as(usize, cb_std_base) + 2;
    if (std_bytes.len < name_at + @as(usize, cch) * 2) return "";
    const name = try arena.alloc(u8, cch);
    for (name, 0..) |*byte, i| {
        const unit = readInt(u16, std_bytes[name_at + i * 2 ..][0..2]);
        if (unit < 0x20 or unit > 0x7E) return "";
        byte.* = @intCast(unit);
    }
    assert(name.len == cch);
    return name;
}

fn headingLevelOfStd(std_bytes: []const u8, cb_std_base: u16) u8 {
    if (std_bytes.len < 2) return 0;
    const sti = readInt(u16, std_bytes[0..2]) & 0x0FFF;
    if (sti >= 1 and sti <= 9) return @intCast(sti);
    // Fall back to the name, stored as a UTF-16LE Xst after the base.
    if (std_bytes.len < @as(usize, cb_std_base) + 2) return 0;
    const cch = readInt(u16, std_bytes[cb_std_base..][0..2]);
    const heading_len = "heading N".len;
    if (cch != heading_len) return 0;
    const name_at = @as(usize, cb_std_base) + 2;
    if (std_bytes.len < name_at + @as(usize, cch) * 2) return 0;
    const prefix = "heading ";
    for (prefix, 0..) |expected, i| {
        const unit = readInt(u16, std_bytes[name_at + i * 2 ..][0..2]);
        if (unit > 0x7F or std.ascii.toLower(@intCast(unit)) != expected) return 0;
    }
    const digit = readInt(u16, std_bytes[name_at + (heading_len - 1) * 2 ..][0..2]);
    if (digit < '1' or digit > '9') return 0;
    return @intCast(digit - '0');
}

fn readInt(comptime T: type, bytes: *const [@sizeOf(T)]u8) T {
    return std.mem.readInt(T, bytes, .little);
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

test "malformed inputs degrade to the inactive resolver" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const short = try parse(arena, &[_]u8{0} ** 64, &.{});
    try testing.expect(!short.active());

    var word: [512]u8 = @splat(0);
    // fcStshf points past the table stream: inactive, not a crash.
    std.mem.writeInt(u32, word[fc_stshf_offset..][0..4], 9999, .little);
    std.mem.writeInt(u32, word[fc_stshf_offset + 4 ..][0..4], 64, .little);
    const oob = try parse(arena, &word, &[_]u8{0} ** 32);
    try testing.expect(!oob.active());
}

test "heading detection by identifier and by name" {
    // sti 3 in the base part.
    var by_sti: [10]u8 = @splat(0);
    std.mem.writeInt(u16, by_sti[0..2], 3, .little);
    try testing.expectEqual(@as(u8, 3), headingLevelOfStd(&by_sti, 10));

    // sti out of range, name "Heading 2".
    var by_name: [10 + 2 + 18]u8 = @splat(0);
    std.mem.writeInt(u16, by_name[0..2], 0x0FFE, .little);
    std.mem.writeInt(u16, by_name[10..12], 9, .little);
    for ("Heading 2", 0..) |byte, i| {
        std.mem.writeInt(u16, by_name[12 + i * 2 ..][0..2], byte, .little);
    }
    try testing.expectEqual(@as(u8, 2), headingLevelOfStd(&by_name, 10));

    // A non-heading name resolves to zero.
    var plain: [10 + 2 + 18]u8 = @splat(0);
    std.mem.writeInt(u16, plain[0..2], 0x0FFE, .little);
    std.mem.writeInt(u16, plain[10..12], 9, .little);
    for ("Blockquot", 0..) |byte, i| {
        std.mem.writeInt(u16, plain[12 + i * 2 ..][0..2], byte, .little);
    }
    try testing.expectEqual(@as(u8, 0), headingLevelOfStd(&plain, 10));
}
