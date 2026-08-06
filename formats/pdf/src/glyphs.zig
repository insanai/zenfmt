//! Simple-font encodings (ZDS: pdf-reader).
//!
//! WinAnsiEncoding (CP-1252), MacRomanEncoding, StandardEncoding, and a
//! compact Adobe-Glyph-List subset for `/Differences` arrays. The AGL
//! subset covers the Latin repertoire real office exports use; an unknown
//! glyph name maps to nothing and the reader counts it as unmappable
//! rather than guessing.

const std = @import("std");

/// CP-1252 upper half; the lower half is ASCII.
const win_ansi_high = [128]u16{
    0x20ac, 0x81,   0x201a, 0x0192, 0x201e, 0x2026, 0x2020, 0x2021,
    0x02c6, 0x2030, 0x0160, 0x2039, 0x0152, 0x8d,   0x017d, 0x8f,
    0x90,   0x2018, 0x2019, 0x201c, 0x201d, 0x2022, 0x2013, 0x2014,
    0x02dc, 0x2122, 0x0161, 0x203a, 0x0153, 0x9d,   0x017e, 0x0178,
    0xa0,   0xa1,   0xa2,   0xa3,   0xa4,   0xa5,   0xa6,   0xa7,
    0xa8,   0xa9,   0xaa,   0xab,   0xac,   0xad,   0xae,   0xaf,
    0xb0,   0xb1,   0xb2,   0xb3,   0xb4,   0xb5,   0xb6,   0xb7,
    0xb8,   0xb9,   0xba,   0xbb,   0xbc,   0xbd,   0xbe,   0xbf,
    0xc0,   0xc1,   0xc2,   0xc3,   0xc4,   0xc5,   0xc6,   0xc7,
    0xc8,   0xc9,   0xca,   0xcb,   0xcc,   0xcd,   0xce,   0xcf,
    0xd0,   0xd1,   0xd2,   0xd3,   0xd4,   0xd5,   0xd6,   0xd7,
    0xd8,   0xd9,   0xda,   0xdb,   0xdc,   0xdd,   0xde,   0xdf,
    0xe0,   0xe1,   0xe2,   0xe3,   0xe4,   0xe5,   0xe6,   0xe7,
    0xe8,   0xe9,   0xea,   0xeb,   0xec,   0xed,   0xee,   0xef,
    0xf0,   0xf1,   0xf2,   0xf3,   0xf4,   0xf5,   0xf6,   0xf7,
    0xf8,   0xf9,   0xfa,   0xfb,   0xfc,   0xfd,   0xfe,   0xff,
};

/// MacRomanEncoding upper half.
const mac_roman_high = [128]u16{
    0xc4,   0xc5,   0xc7,   0xc9,   0xd1,   0xd6,   0xdc,   0xe1,
    0xe0,   0xe2,   0xe4,   0xe3,   0xe5,   0xe7,   0xe9,   0xe8,
    0xea,   0xeb,   0xed,   0xec,   0xee,   0xef,   0xf1,   0xf3,
    0xf2,   0xf4,   0xf6,   0xf5,   0xfa,   0xf9,   0xfb,   0xfc,
    0x2020, 0xb0,   0xa2,   0xa3,   0xa7,   0x2022, 0xb6,   0xdf,
    0xae,   0xa9,   0x2122, 0xb4,   0xa8,   0x2260, 0xc6,   0xd8,
    0x221e, 0xb1,   0x2264, 0x2265, 0xa5,   0xb5,   0x2202, 0x2211,
    0x220f, 0x03c0, 0x222b, 0xaa,   0xba,   0x03a9, 0xe6,   0xf8,
    0xbf,   0xa1,   0xac,   0x221a, 0x0192, 0x2248, 0x2206, 0xab,
    0xbb,   0x2026, 0xa0,   0xc0,   0xc3,   0xd5,   0x0152, 0x0153,
    0x2013, 0x2014, 0x201c, 0x201d, 0x2018, 0x2019, 0xf7,   0x25ca,
    0xff,   0x0178, 0x2044, 0x20ac, 0x2039, 0x203a, 0xfb01, 0xfb02,
    0x2021, 0xb7,   0x201a, 0x201e, 0x2030, 0xc2,   0xca,   0xc1,
    0xcb,   0xc8,   0xcd,   0xce,   0xcf,   0xcc,   0xd3,   0xd4,
    0xf8ff, 0xd2,   0xda,   0xdb,   0xd9,   0x0131, 0x02c6, 0x02dc,
    0xaf,   0x02d8, 0x02d9, 0x02da, 0xb8,   0x02dd, 0x02db, 0x02c7,
};

/// StandardEncoding upper half (sparse; 0 = unmapped).
const standard_high = [128]u16{
    0,      0,      0,      0,      0,      0,      0,      0,
    0,      0,      0,      0,      0,      0,      0,      0,
    0,      0,      0,      0,      0,      0,      0,      0,
    0,      0,      0,      0,      0,      0,      0,      0,
    0,      0xa1,   0xa2,   0xa3,   0x2044, 0xa5,   0x0192, 0xa7,
    0xa4,   0x27,   0x201c, 0xab,   0x2039, 0x203a, 0xfb01, 0xfb02,
    0,      0x2013, 0x2020, 0x2021, 0xb7,   0,      0xb6,   0x2022,
    0x201a, 0x201e, 0x201d, 0xbb,   0x2026, 0x2030, 0,      0xbf,
    0,      0x60,   0xb4,   0x02c6, 0x02dc, 0xaf,   0x02d8, 0x02d9,
    0xa8,   0,      0x02da, 0xb8,   0,      0x02dd, 0x02db, 0x02c7,
    0x2014, 0,      0,      0,      0,      0,      0,      0,
    0,      0,      0,      0,      0,      0,      0,      0,
    0,      0xc6,   0,      0xaa,   0,      0,      0,      0,
    0x0141, 0xd8,   0x0152, 0xba,   0,      0,      0,      0,
    0,      0xe6,   0,      0,      0,      0x0131, 0,      0,
    0x0142, 0xf8,   0x0153, 0xdf,   0,      0,      0,      0,
};

pub const Base = enum { standard, win_ansi, mac_roman };

/// Maps one code through a base encoding; 0 means unmapped.
pub fn baseChar(base: Base, code: u8) u21 {
    if (code < 0x80) {
        // StandardEncoding curls the ASCII quotes.
        if (base == .standard) {
            if (code == 0x27) return 0x2019;
            if (code == 0x60) return 0x2018;
        }
        return code;
    }
    const value = switch (base) {
        .standard => standard_high[code - 0x80],
        .win_ansi => win_ansi_high[code - 0x80],
        .mac_roman => mac_roman_high[code - 0x80],
    };
    return value;
}

const NamedGlyph = struct { name: []const u8, cp: u21 };

/// Adobe Glyph List subset: everything the Latin office repertoire needs.
const agl = [_]NamedGlyph{
    .{ .name = "space", .cp = ' ' },             .{ .name = "exclam", .cp = '!' },
    .{ .name = "quotedbl", .cp = '"' },          .{ .name = "numbersign", .cp = '#' },
    .{ .name = "dollar", .cp = '$' },            .{ .name = "percent", .cp = '%' },
    .{ .name = "ampersand", .cp = '&' },         .{ .name = "quotesingle", .cp = '\'' },
    .{ .name = "parenleft", .cp = '(' },         .{ .name = "parenright", .cp = ')' },
    .{ .name = "asterisk", .cp = '*' },          .{ .name = "plus", .cp = '+' },
    .{ .name = "comma", .cp = ',' },             .{ .name = "hyphen", .cp = '-' },
    .{ .name = "period", .cp = '.' },            .{ .name = "slash", .cp = '/' },
    .{ .name = "zero", .cp = '0' },              .{ .name = "one", .cp = '1' },
    .{ .name = "two", .cp = '2' },               .{ .name = "three", .cp = '3' },
    .{ .name = "four", .cp = '4' },              .{ .name = "five", .cp = '5' },
    .{ .name = "six", .cp = '6' },               .{ .name = "seven", .cp = '7' },
    .{ .name = "eight", .cp = '8' },             .{ .name = "nine", .cp = '9' },
    .{ .name = "colon", .cp = ':' },             .{ .name = "semicolon", .cp = ';' },
    .{ .name = "less", .cp = '<' },              .{ .name = "equal", .cp = '=' },
    .{ .name = "greater", .cp = '>' },           .{ .name = "question", .cp = '?' },
    .{ .name = "at", .cp = '@' },                .{ .name = "bracketleft", .cp = '[' },
    .{ .name = "backslash", .cp = '\\' },        .{ .name = "bracketright", .cp = ']' },
    .{ .name = "asciicircum", .cp = '^' },       .{ .name = "underscore", .cp = '_' },
    .{ .name = "grave", .cp = '`' },             .{ .name = "braceleft", .cp = '{' },
    .{ .name = "bar", .cp = '|' },               .{ .name = "braceright", .cp = '}' },
    .{ .name = "asciitilde", .cp = '~' },        .{ .name = "quoteleft", .cp = 0x2018 },
    .{ .name = "quoteright", .cp = 0x2019 },     .{ .name = "quotedblleft", .cp = 0x201c },
    .{ .name = "quotedblright", .cp = 0x201d },  .{ .name = "quotesinglbase", .cp = 0x201a },
    .{ .name = "quotedblbase", .cp = 0x201e },   .{ .name = "endash", .cp = 0x2013 },
    .{ .name = "emdash", .cp = 0x2014 },         .{ .name = "bullet", .cp = 0x2022 },
    .{ .name = "dagger", .cp = 0x2020 },         .{ .name = "daggerdbl", .cp = 0x2021 },
    .{ .name = "ellipsis", .cp = 0x2026 },       .{ .name = "fi", .cp = 0xfb01 },
    .{ .name = "fl", .cp = 0xfb02 },             .{ .name = "florin", .cp = 0x0192 },
    .{ .name = "fraction", .cp = 0x2044 },       .{ .name = "guillemotleft", .cp = 0xab },
    .{ .name = "guillemotright", .cp = 0xbb },   .{ .name = "guilsinglleft", .cp = 0x2039 },
    .{ .name = "guilsinglright", .cp = 0x203a }, .{ .name = "periodcentered", .cp = 0xb7 },
    .{ .name = "perthousand", .cp = 0x2030 },    .{ .name = "section", .cp = 0xa7 },
    .{ .name = "paragraph", .cp = 0xb6 },        .{ .name = "sterling", .cp = 0xa3 },
    .{ .name = "yen", .cp = 0xa5 },              .{ .name = "cent", .cp = 0xa2 },
    .{ .name = "currency", .cp = 0xa4 },         .{ .name = "degree", .cp = 0xb0 },
    .{ .name = "divide", .cp = 0xf7 },           .{ .name = "multiply", .cp = 0xd7 },
    .{ .name = "plusminus", .cp = 0xb1 },        .{ .name = "registered", .cp = 0xae },
    .{ .name = "copyright", .cp = 0xa9 },        .{ .name = "trademark", .cp = 0x2122 },
    .{ .name = "logicalnot", .cp = 0xac },       .{ .name = "mu", .cp = 0xb5 },
    .{ .name = "Euro", .cp = 0x20ac },           .{ .name = "minus", .cp = 0x2212 },
    .{ .name = "exclamdown", .cp = 0xa1 },       .{ .name = "questiondown", .cp = 0xbf },
    .{ .name = "brokenbar", .cp = 0xa6 },        .{ .name = "ordfeminine", .cp = 0xaa },
    .{ .name = "ordmasculine", .cp = 0xba },     .{ .name = "onequarter", .cp = 0xbc },
    .{ .name = "onehalf", .cp = 0xbd },          .{ .name = "threequarters", .cp = 0xbe },
    .{ .name = "onesuperior", .cp = 0xb9 },      .{ .name = "twosuperior", .cp = 0xb2 },
    .{ .name = "threesuperior", .cp = 0xb3 },    .{ .name = "macron", .cp = 0xaf },
    .{ .name = "acute", .cp = 0xb4 },            .{ .name = "dieresis", .cp = 0xa8 },
    .{ .name = "cedilla", .cp = 0xb8 },          .{ .name = "circumflex", .cp = 0x02c6 },
    .{ .name = "tilde", .cp = 0x02dc },          .{ .name = "breve", .cp = 0x02d8 },
    .{ .name = "dotaccent", .cp = 0x02d9 },      .{ .name = "ring", .cp = 0x02da },
    .{ .name = "hungarumlaut", .cp = 0x02dd },   .{ .name = "ogonek", .cp = 0x02db },
    .{ .name = "caron", .cp = 0x02c7 },          .{ .name = "germandbls", .cp = 0xdf },
    .{ .name = "dotlessi", .cp = 0x0131 },       .{ .name = "AE", .cp = 0xc6 },
    .{ .name = "ae", .cp = 0xe6 },               .{ .name = "OE", .cp = 0x0152 },
    .{ .name = "oe", .cp = 0x0153 },             .{ .name = "Oslash", .cp = 0xd8 },
    .{ .name = "oslash", .cp = 0xf8 },           .{ .name = "Lslash", .cp = 0x0141 },
    .{ .name = "lslash", .cp = 0x0142 },         .{ .name = "Thorn", .cp = 0xde },
    .{ .name = "thorn", .cp = 0xfe },            .{ .name = "Eth", .cp = 0xd0 },
    .{ .name = "eth", .cp = 0xf0 },              .{ .name = "Scaron", .cp = 0x0160 },
    .{ .name = "scaron", .cp = 0x0161 },         .{ .name = "Zcaron", .cp = 0x017d },
    .{ .name = "zcaron", .cp = 0x017e },         .{ .name = "Ydieresis", .cp = 0x0178 },
    .{ .name = "nbspace", .cp = 0xa0 },          .{ .name = "sfthyphen", .cp = 0xad },
};

/// Accented Latin glyph names follow `<base><accent>` composition:
/// Aacute, egrave, ocircumflex, ntilde, udieresis, aring, ccedilla.
const accents = [_]struct { suffix: []const u8, table: []const [2]u21 }{
    .{ .suffix = "acute", .table = &.{
        .{ 'A', 0xc1 }, .{ 'E', 0xc9 }, .{ 'I', 0xcd }, .{ 'O', 0xd3 },
        .{ 'U', 0xda }, .{ 'Y', 0xdd }, .{ 'a', 0xe1 }, .{ 'e', 0xe9 },
        .{ 'i', 0xed }, .{ 'o', 0xf3 }, .{ 'u', 0xfa }, .{ 'y', 0xfd },
    } },
    .{ .suffix = "grave", .table = &.{
        .{ 'A', 0xc0 }, .{ 'E', 0xc8 }, .{ 'I', 0xcc }, .{ 'O', 0xd2 },
        .{ 'U', 0xd9 }, .{ 'a', 0xe0 }, .{ 'e', 0xe8 }, .{ 'i', 0xec },
        .{ 'o', 0xf2 }, .{ 'u', 0xf9 },
    } },
    .{ .suffix = "circumflex", .table = &.{
        .{ 'A', 0xc2 }, .{ 'E', 0xca }, .{ 'I', 0xce }, .{ 'O', 0xd4 },
        .{ 'U', 0xdb }, .{ 'a', 0xe2 }, .{ 'e', 0xea }, .{ 'i', 0xee },
        .{ 'o', 0xf4 }, .{ 'u', 0xfb },
    } },
    .{ .suffix = "dieresis", .table = &.{
        .{ 'A', 0xc4 }, .{ 'E', 0xcb }, .{ 'I', 0xcf }, .{ 'O', 0xd6 },
        .{ 'U', 0xdc }, .{ 'a', 0xe4 }, .{ 'e', 0xeb }, .{ 'i', 0xef },
        .{ 'o', 0xf6 }, .{ 'u', 0xfc }, .{ 'y', 0xff },
    } },
    .{ .suffix = "tilde", .table = &.{
        .{ 'A', 0xc3 }, .{ 'N', 0xd1 }, .{ 'O', 0xd5 }, .{ 'a', 0xe3 },
        .{ 'n', 0xf1 }, .{ 'o', 0xf5 },
    } },
    .{ .suffix = "ring", .table = &.{
        .{ 'A', 0xc5 }, .{ 'a', 0xe5 },
    } },
    .{ .suffix = "cedilla", .table = &.{
        .{ 'C', 0xc7 }, .{ 'c', 0xe7 },
    } },
};

/// Resolves a glyph name to a code point; null when outside the subset.
pub fn glyphToUnicode(name: []const u8) ?u21 {
    if (name.len == 1) {
        const c = name[0];
        if (c >= 0x21 and c <= 0x7e) return c;
        return null;
    }
    for (&agl) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return entry.cp;
    }
    for (&accents) |group| {
        if (name.len == 1 + group.suffix.len and
            std.mem.eql(u8, name[1..], group.suffix))
        {
            for (group.table) |pair| {
                if (pair[0] == name[0]) return pair[1];
            }
        }
    }
    // `uniXXXX` and `uXXXX[XX]` are explicit code points.
    if (name.len == 7 and std.mem.startsWith(u8, name, "uni")) {
        const value = std.fmt.parseInt(u21, name[3..], 16) catch return null;
        return if (value <= 0x10ffff) value else null;
    }
    if (name.len >= 5 and name.len <= 7 and name[0] == 'u') {
        const value = std.fmt.parseInt(u21, name[1..], 16) catch return null;
        return if (value <= 0x10ffff) value else null;
    }
    return null;
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

test "base encodings map the interesting ranges" {
    try testing.expectEqual(@as(u21, 'A'), baseChar(.win_ansi, 'A'));
    try testing.expectEqual(@as(u21, 0x2014), baseChar(.win_ansi, 0x97));
    try testing.expectEqual(@as(u21, 0xe9), baseChar(.win_ansi, 0xe9));
    try testing.expectEqual(@as(u21, 0xe9), baseChar(.mac_roman, 0x8e));
    try testing.expectEqual(@as(u21, 0x2019), baseChar(.standard, 0x27));
}

test "glyph names resolve through the subset" {
    try testing.expectEqual(@as(?u21, 'a'), glyphToUnicode("a"));
    try testing.expectEqual(@as(?u21, '7'), glyphToUnicode("seven"));
    try testing.expectEqual(@as(?u21, 0xe9), glyphToUnicode("eacute"));
    try testing.expectEqual(@as(?u21, 0x20ac), glyphToUnicode("Euro"));
    try testing.expectEqual(@as(?u21, 0x2764), glyphToUnicode("uni2764"));
    try testing.expectEqual(@as(?u21, null), glyphToUnicode("a1"));
    try testing.expectEqual(@as(?u21, null), glyphToUnicode("smiley"));
}
