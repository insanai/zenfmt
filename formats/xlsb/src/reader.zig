//! The XLSB reader ([MS-XLSB]): the binary sibling of XLSX — the same
//! OPC package, but the parts are binary record streams instead of XML.
//! Records frame as a 1-2 byte type and a 1-4 byte length varint. The
//! projection mirrors the XLSX reader exactly: sheet name as a heading,
//! one table per sheet, first row as the head, dates and percentages
//! formatted, cached formula values used as-is.

const std = @import("std");
const assert = std.debug.assert;
const core = @import("zenfmt_core");
const xml = @import("zenfmt_xml");
const ooxml = @import("zenfmt_ooxml");

pub const reader = core.Reader(.{
    .id = "ai.insan.zenfmt.xlsb",
    .format = "xlsb",
    .extensions = &.{"xlsb"},
    .input = .seekable,
    .read = read,
});

const brt_row_hdr: u16 = 0;
const brt_cell_blank: u16 = 1;
const brt_cell_rk: u16 = 2;
const brt_cell_error: u16 = 3;
const brt_cell_bool: u16 = 4;
const brt_cell_real: u16 = 5;
const brt_cell_st: u16 = 6;
const brt_cell_isst: u16 = 7;
const brt_fmla_string: u16 = 8;
const brt_fmla_num: u16 = 9;
const brt_fmla_bool: u16 = 10;
const brt_fmla_error: u16 = 11;
const brt_sst_item: u16 = 19;
const brt_fmt: u16 = 44;
const brt_xf: u16 = 47;
const brt_bundle_sh: u16 = 156;
const brt_begin_sst: u16 = 159;
const brt_begin_cell_xfs: u16 = 617;
const brt_end_cell_xfs: u16 = 618;

const NumberKind = enum { general, date, percent };

fn read(ctx: *core.ReadContext) core.ReadError!void {
    const arena = ctx.gpa;
    var archive = ooxml.zip.Archive.openSource(arena, ooxml.zipSource(ctx), ctx.limits) catch |err| {
        try ctx.reports.add(archiveReport());
        return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.LimitExceeded => error.LimitExceeded,
            else => error.Malformed,
        };
    };

    const shared = blk: {
        const bytes = extract(&archive, arena, "xl/sharedStrings.bin", ctx) orelse
            break :blk &[_][]const u8{};
        break :blk parseSharedStrings(arena, bytes) catch &[_][]const u8{};
    };
    const styles = blk: {
        const bytes = extract(&archive, arena, "xl/styles.bin", ctx) orelse
            break :blk &[_]NumberKind{};
        break :blk parseCellFormats(arena, bytes) catch &[_]NumberKind{};
    };
    const rels = blk: {
        const bytes = extract(&archive, arena, "xl/_rels/workbook.bin.rels", ctx) orelse
            break :blk ooxml.Relationships.empty;
        break :blk ooxml.parseRelationships(arena, bytes, ctx.limits) catch ooxml.Relationships.empty;
    };
    const workbook = extract(&archive, arena, "xl/workbook.bin", ctx) orelse {
        try ctx.reports.add(notWorkbookReport());
        return error.Malformed;
    };

    var sheets_seen: u32 = 0;
    var sheets_converted: u32 = 0;
    var iter = RecordIter{ .bytes = workbook };
    while (iter.next()) |record| {
        if (record.id != brt_bundle_sh) continue;
        sheets_seen += 1;
        const sheet = parseBundleSh(arena, record.data) orelse continue;
        const relationship = rels.byId(sheet.rel_id) orelse continue;
        const part = try ooxml.resolveTarget(arena, "xl", relationship.target);
        const sheet_bytes = extract(&archive, arena, part, ctx) orelse continue;
        try readSheet(ctx, arena, sheet.name, sheet_bytes, shared, styles);
        sheets_converted += 1;
    }
    // A workbook with sheets must never convert to silence: a sheet that
    // cannot be loaded is reported, and losing all of them is a refusal.
    if (sheets_seen > 0 and sheets_converted == 0) {
        try ctx.reports.add(sheetsUnreadableReport());
        return error.Malformed;
    }
    if (sheets_converted < sheets_seen) {
        try ctx.reports.add(sheetsSkippedReport(sheets_seen - sheets_converted));
    }
}

const SheetRef = struct {
    rel_id: []const u8,
    name: []const u8,
};

/// `BrtBundleSh` per the spec example is `hsState`, `iTabID`, and the
/// strings from offset 8. Files in the wild (Apache POI's test corpus
/// among them) carry one extra 4-byte field before the strings. Both
/// shapes appear; accept whichever parse consumes the record exactly.
fn parseBundleSh(arena: std.mem.Allocator, data: []const u8) ?SheetRef {
    for ([_]usize{ 8, 12 }) |preamble| {
        if (preamble > data.len) continue;
        var cursor = Cursor{ .data = data, .pos = preamble };
        const maybe_rel = cursor.nullableString(arena) catch continue;
        const rel_id = maybe_rel orelse continue;
        const name = cursor.wideString(arena) catch continue;
        if (rel_id.len == 0) continue;
        if (cursor.pos != data.len) continue;
        return .{ .rel_id = rel_id, .name = name };
    }
    return null;
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

// ------------------------------------------------------- workbook parts

fn parseSharedStrings(arena: std.mem.Allocator, bytes: []const u8) ![]const []const u8 {
    var strings: std.ArrayList([]const u8) = .empty;
    var iter = RecordIter{ .bytes = bytes };
    while (iter.next()) |record| {
        if (record.id != brt_sst_item) continue;
        var cursor = Cursor{ .data = record.data };
        _ = try cursor.takeInt(u8); // rich/phonetic flags; text comes first
        const text = try cursor.wideString(arena);
        try strings.append(arena, text);
    }
    return strings.items;
}

/// Per cell-format index inside the cellXFs section, whether the number
/// format is a date or a percentage.
fn parseCellFormats(arena: std.mem.Allocator, bytes: []const u8) ![]const NumberKind {
    var kinds: std.ArrayList(NumberKind) = .empty;
    var custom: std.AutoHashMapUnmanaged(u16, NumberKind) = .empty;
    defer custom.deinit(arena);
    var in_cell_xfs = false;
    var iter = RecordIter{ .bytes = bytes };
    while (iter.next()) |record| {
        switch (record.id) {
            brt_fmt => {
                var cursor = Cursor{ .data = record.data };
                const ifmt = cursor.takeInt(u16) catch continue;
                const format = cursor.wideString(arena) catch continue;
                try custom.put(arena, ifmt, kindFromFormat(format));
            },
            brt_begin_cell_xfs => in_cell_xfs = true,
            brt_end_cell_xfs => in_cell_xfs = false,
            brt_xf => {
                if (!in_cell_xfs or record.data.len < 4) continue;
                const ifmt = readInt(u16, record.data[2..4]);
                const kind = custom.get(ifmt) orelse builtinNumberKind(ifmt);
                try kinds.append(arena, kind);
            },
            else => {},
        }
    }
    return kinds.items;
}

fn builtinNumberKind(id: u16) NumberKind {
    return switch (id) {
        14...22, 45...47 => .date,
        9, 10 => .percent,
        else => .general,
    };
}

fn kindFromFormat(format: []const u8) NumberKind {
    if (std.mem.indexOfScalar(u8, format, '%') != null) return .percent;
    for (format) |byte| switch (byte) {
        'y', 'Y', 'd', 'D', 'h', 'H', 'm', 'M', 's', 'S' => return .date,
        else => {},
    };
    return .general;
}

// -------------------------------------------------------------- sheets

const max_columns = 1024;

fn readSheet(
    ctx: *core.ReadContext,
    arena: std.mem.Allocator,
    name: []const u8,
    bytes: []const u8,
    shared: []const []const u8,
    styles: []const NumberKind,
) core.ReadError!void {
    // First pass: the column count.
    var columns: u32 = 0;
    {
        var iter = RecordIter{ .bytes = bytes };
        while (iter.next()) |record| {
            if (!isCellRecord(record.id) or record.data.len < 4) continue;
            const col = readInt(u32, record.data[0..4]);
            columns = @max(columns, @min(col, max_columns - 1) + 1);
        }
    }
    if (columns == 0) return;

    const heading = try ctx.out.beginHeading(2);
    try ctx.out.text(name);
    ctx.out.endBlock(heading);

    var alignments: std.ArrayList(core.payload.Alignment) = .empty;
    defer alignments.deinit(arena);
    try alignments.appendNTimes(arena, .default, columns);
    const table = try ctx.out.beginTable(alignments.items);

    var head_token: ?core.builder.BlockToken = null;
    var body_token: ?core.builder.BlockToken = null;
    var row_token: ?core.builder.BlockToken = null;
    var row_index: u32 = 0;
    var current_row: u32 = 0;
    var emitted: u32 = 0;

    var iter = RecordIter{ .bytes = bytes };
    while (iter.next()) |record| {
        if (record.id == brt_row_hdr) {
            try closeRow(ctx, &row_token, &emitted, columns);
            if (row_index == 0) {
                head_token = try ctx.out.beginBlock(.table_head);
            } else if (row_index == 1) {
                if (head_token) |token| {
                    ctx.out.endBlock(token);
                    head_token = null;
                }
                body_token = try ctx.out.beginTableBody(.{ .row_head_columns = 0, .head_rows = 0 });
            }
            row_token = try ctx.out.beginBlock(.table_row);
            // The header names its own row; the counter is the fallback
            // for truncated records.
            current_row = if (record.data.len >= 4)
                readInt(u32, record.data[0..4])
            else
                row_index;
            row_index += 1;
            emitted = 0;
            continue;
        }
        if (!isCellRecord(record.id) or row_token == null) continue;
        if (record.data.len < 8) continue;
        const col = readInt(u32, record.data[0..4]);
        if (col >= max_columns) continue;
        const style = readInt(u32, record.data[4..8]) & 0xFFFFFF;
        const kind = if (style < styles.len) styles[style] else .general;
        const text = cellText(arena, record, shared, kind) catch |err|
            switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => "",
            };
        while (emitted < col and emitted < max_columns) : (emitted += 1) {
            try emitCellText(ctx, "");
        }
        if (emitted == col) {
            // Facet coordinates are the record's own (ZDS 0013); BIFF12
            // formula source is not decoded.
            const grid: ?core.facets.GridData = if (text.len > 0)
                .{
                    .sheet = name,
                    .row = current_row,
                    .col = col,
                    .value_type = gridValueType(record.id, kind),
                    .cached = text,
                }
            else
                null;
            try emitCell(ctx, text, grid);
            emitted += 1;
        }
    }
    try closeRow(ctx, &row_token, &emitted, columns);
    if (head_token) |token| ctx.out.endBlock(token);
    if (body_token) |token| ctx.out.endBlock(token);
    ctx.out.endBlock(table);
}

fn closeRow(
    ctx: *core.ReadContext,
    row_token: *?core.builder.BlockToken,
    emitted: *u32,
    columns: u32,
) core.ReadError!void {
    const token = row_token.* orelse return;
    while (emitted.* < columns) : (emitted.* += 1) try emitCellText(ctx, "");
    ctx.out.endBlock(token);
    row_token.* = null;
}

fn isCellRecord(id: u16) bool {
    return switch (id) {
        brt_cell_blank,
        brt_cell_rk,
        brt_cell_error,
        brt_cell_bool,
        brt_cell_real,
        brt_cell_st,
        brt_cell_isst,
        brt_fmla_string,
        brt_fmla_num,
        brt_fmla_bool,
        brt_fmla_error,
        => true,
        else => false,
    };
}

fn cellText(
    arena: std.mem.Allocator,
    record: Record,
    shared: []const []const u8,
    kind: NumberKind,
) ![]const u8 {
    var cursor = Cursor{ .data = record.data, .pos = 8 };
    switch (record.id) {
        brt_cell_blank => return "",
        brt_cell_rk => {
            const rk = try cursor.takeInt(u32);
            return numberText(arena, rkValue(rk), kind);
        },
        brt_cell_error, brt_fmla_error => return errorText(try cursor.takeInt(u8)),
        brt_cell_bool, brt_fmla_bool => {
            return if ((try cursor.takeInt(u8)) != 0) "TRUE" else "FALSE";
        },
        brt_cell_real, brt_fmla_num => {
            const bits = try cursor.takeInt(u64);
            return numberText(arena, @bitCast(bits), kind);
        },
        brt_cell_st, brt_fmla_string => return cursor.wideString(arena),
        brt_cell_isst => {
            const isst = try cursor.takeInt(u32);
            if (isst >= shared.len) return "";
            return shared[isst];
        },
        else => return "",
    }
}

fn emitCellText(ctx: *core.ReadContext, text: []const u8) core.ReadError!void {
    try emitCell(ctx, text, null);
}

fn emitCell(
    ctx: *core.ReadContext,
    text: []const u8,
    grid: ?core.facets.GridData,
) core.ReadError!void {
    const cell = try ctx.out.beginTableCell(.plain);
    if (grid) |data| try ctx.out.attachGrid(cell, data);
    const plain = try ctx.out.beginPlain();
    if (text.len > 0) try ctx.out.text(text);
    ctx.out.endBlock(plain);
    ctx.out.endBlock(cell);
}

/// The facet's value type (ZDS 0013) from the BIFF12 record family and
/// the number-format kind.
fn gridValueType(record_id: u16, kind: NumberKind) core.facets.ValueType {
    return switch (record_id) {
        brt_cell_rk, brt_cell_real, brt_fmla_num => switch (kind) {
            .date => .date,
            .percent, .general => .number,
        },
        brt_cell_error, brt_fmla_error => .error_value,
        brt_cell_bool, brt_fmla_bool => .boolean,
        else => .text,
    };
}

/// RkNumber: bit 0 divides by 100, bit 1 marks a 30-bit integer.
fn rkValue(rk: u32) f64 {
    const div100 = rk & 0x01 != 0;
    const is_int = rk & 0x02 != 0;
    var value: f64 = undefined;
    if (is_int) {
        const signed: i32 = @bitCast(rk);
        value = @floatFromInt(signed >> 2);
    } else {
        value = @bitCast(@as(u64, rk & 0xFFFFFFFC) << 32);
    }
    return if (div100) value / 100 else value;
}

fn numberText(arena: std.mem.Allocator, value: f64, kind: NumberKind) ![]const u8 {
    switch (kind) {
        .date => {
            const text: ?[]const u8 = formatSerialDate(arena, value) catch null;
            if (text) |formatted| return formatted;
        },
        .percent => return std.fmt.allocPrint(arena, "{d}%", .{value * 100}),
        .general => {},
    }
    return std.fmt.allocPrint(arena, "{d}", .{value});
}

/// Hinnant's civil-from-days, as in the XLSX reader.
fn formatSerialDate(arena: std.mem.Allocator, serial: f64) ![]const u8 {
    if (serial < 1 or serial > 2958465) return error.OutOfRange;
    const days = @as(i64, @intFromFloat(serial)) - 25569;
    const z = days + 719468;
    const era = @divFloor(z, 146097);
    const day_of_era: u64 = @intCast(z - era * 146097);
    const year_of_era = (day_of_era - day_of_era / 1460 + day_of_era / 36524 - day_of_era / 146096) / 365;
    const year = @as(i64, @intCast(year_of_era)) + era * 400;
    const day_of_year = day_of_era - (365 * year_of_era + year_of_era / 4 - year_of_era / 100);
    const month_prime = (5 * day_of_year + 2) / 153;
    const day = day_of_year - (153 * month_prime + 2) / 5 + 1;
    const month = if (month_prime < 10) month_prime + 3 else month_prime - 9;
    const civil_year: u32 = @intCast(if (month <= 2) year + 1 else year);
    return std.fmt.allocPrint(arena, "{d:0>4}-{d:0>2}-{d:0>2}", .{ civil_year, month, day });
}

fn errorText(code: u8) []const u8 {
    return switch (code) {
        0x00 => "#NULL!",
        0x07 => "#DIV/0!",
        0x0F => "#VALUE!",
        0x17 => "#REF!",
        0x1D => "#NAME?",
        0x24 => "#NUM!",
        0x2A => "#N/A",
        else => "#ERR",
    };
}

// -------------------------------------------------------- record stream

const Record = struct {
    id: u16,
    data: []const u8,
};

/// [MS-XLSB] framing: the type is one byte, or two when the first byte's
/// high bit is set (7 bits each, low first); the length is a varint of
/// up to four 7-bit bytes.
const RecordIter = struct {
    bytes: []const u8,
    pos: usize = 0,

    fn next(it: *RecordIter) ?Record {
        if (it.pos >= it.bytes.len) return null;
        var id: u16 = it.bytes[it.pos] & 0x7F;
        var advance: usize = 1;
        if (it.bytes[it.pos] & 0x80 != 0) {
            if (it.pos + 1 >= it.bytes.len) return null;
            id |= @as(u16, it.bytes[it.pos + 1] & 0x7F) << 7;
            advance = 2;
        }
        it.pos += advance;

        var len: u32 = 0;
        var shift: u5 = 0;
        var more = true;
        var count: u32 = 0;
        while (more) {
            if (it.pos >= it.bytes.len or count >= 4) return null;
            const byte = it.bytes[it.pos];
            it.pos += 1;
            len |= @as(u32, byte & 0x7F) << shift;
            more = byte & 0x80 != 0;
            shift +|= 7;
            count += 1;
        }
        const take = @min(len, it.bytes.len - it.pos);
        const data = it.bytes[it.pos..][0..take];
        it.pos += take;
        return .{ .id = id, .data = data };
    }
};

const Cursor = struct {
    data: []const u8,
    pos: usize = 0,

    fn takeInt(cursor: *Cursor, comptime T: type) !T {
        if (cursor.pos + @sizeOf(T) > cursor.data.len) return error.Malformed;
        const value = readInt(T, cursor.data[cursor.pos..][0..@sizeOf(T)]);
        cursor.pos += @sizeOf(T);
        return value;
    }

    /// XLWideString: cch and then UTF-16LE code units.
    fn wideString(cursor: *Cursor, arena: std.mem.Allocator) ![]const u8 {
        const cch = try cursor.takeInt(u32);
        if (cch > (cursor.data.len - cursor.pos) / 2) return error.Malformed;
        var out: std.ArrayList(u8) = .empty;
        try cfbUtf16(arena, &out, cursor.data[cursor.pos..][0 .. cch * 2]);
        cursor.pos += cch * 2;
        return out.items;
    }

    /// XLNullableWideString: 0xFFFFFFFF means absent.
    fn nullableString(cursor: *Cursor, arena: std.mem.Allocator) !?[]const u8 {
        const cch = try cursor.takeInt(u32);
        if (cch == 0xFFFFFFFF) return null;
        if (cch > (cursor.data.len - cursor.pos) / 2) return error.Malformed;
        var out: std.ArrayList(u8) = .empty;
        try cfbUtf16(arena, &out, cursor.data[cursor.pos..][0 .. cch * 2]);
        cursor.pos += cch * 2;
        return out.items;
    }
};

/// UTF-16LE to UTF-8, with unpaired surrogates as U+FFFD.
fn cfbUtf16(
    arena: std.mem.Allocator,
    out: *std.ArrayList(u8),
    bytes: []const u8,
) error{OutOfMemory}!void {
    var i: usize = 0;
    while (i + 1 < bytes.len) {
        var code: u21 = readInt(u16, bytes[i..][0..2]);
        i += 2;
        if (code >= 0xD800 and code <= 0xDBFF and i + 1 < bytes.len) {
            const low = readInt(u16, bytes[i..][0..2]);
            if (low >= 0xDC00 and low <= 0xDFFF) {
                code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00);
                i += 2;
            } else {
                code = 0xFFFD;
            }
        } else if (code >= 0xD800 and code <= 0xDFFF) {
            code = 0xFFFD;
        }
        var encoded: [4]u8 = undefined;
        const length = std.unicode.utf8Encode(code, &encoded) catch blk: {
            encoded[0] = 0xEF;
            encoded[1] = 0xBF;
            encoded[2] = 0xBD;
            break :blk 3;
        };
        try out.appendSlice(arena, encoded[0..length]);
    }
}

fn readInt(comptime T: type, bytes: *const [@sizeOf(T)]u8) T {
    return std.mem.readInt(T, bytes, .little);
}

// ------------------------------------------------------------- reports

fn archiveReport() core.Report {
    return .{
        .severity = .err,
        .code = "xlsb.not-an-archive",
        .title = "NOT A READABLE XLSB ARCHIVE",
        .problem = "This file is not a ZIP archive zenfmt can read, or it " ++
            "trips an archive safety limit.",
        .consequence = "The conversion stopped and no output file was created.",
        .directions = &.{.{
            .title = "Check the file",
            .explanation = "Open the file in Excel or LibreOffice to " ++
                "verify it is intact, and check the detected format.",
        }},
    };
}

fn notWorkbookReport() core.Report {
    return .{
        .severity = .err,
        .code = "xlsb.missing-workbook",
        .title = "THE WORKBOOK PART IS MISSING",
        .problem = "The archive opens but does not contain a readable " ++
            "xl/workbook.bin, so it is not a binary workbook.",
        .consequence = "The conversion stopped and no output file was created.",
        .directions = &.{.{
            .title = "Re-export the file",
            .explanation = "Re-save the workbook from its native " ++
                "application and convert the fresh copy.",
        }},
    };
}

fn sheetsUnreadableReport() core.Report {
    return .{
        .severity = .err,
        .code = "xlsb.sheets-unreadable",
        .title = "NO SHEET COULD BE READ",
        .problem = "The workbook lists sheets, but none of their parts " ++
            "could be located or parsed.",
        .consequence = "The conversion stopped and no output file was created.",
        .directions = &.{.{
            .title = "Re-export the file",
            .explanation = "Re-save the workbook from Excel or LibreOffice " ++
                "and convert the fresh copy, or export it as .xlsx.",
        }},
    };
}

fn sheetsSkippedReport(count: u32) core.Report {
    return .{
        .severity = .warning,
        .code = "xlsb.sheet-skipped",
        .title = "SOME SHEETS COULD NOT BE READ",
        .problem = "One or more sheet parts named by the workbook could " ++
            "not be located or parsed.",
        .consequence = "Those sheets are absent from the output.",
        .loss = .dropped,
        .count = count,
        .directions = &.{.{
            .title = "Re-export the file",
            .explanation = "Re-save the workbook from Excel or LibreOffice " ++
                "and convert the fresh copy to recover the missing sheets.",
        }},
    };
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

fn appendRecord(
    arena: std.mem.Allocator,
    out: *std.ArrayList(u8),
    id: u16,
    payload: []const u8,
) !void {
    if (id < 0x80) {
        try out.append(arena, @intCast(id));
    } else {
        try out.append(arena, @as(u8, @intCast(id & 0x7F)) | 0x80);
        try out.append(arena, @intCast(id >> 7));
    }
    var len = payload.len;
    while (true) {
        const byte: u8 = @intCast(len & 0x7F);
        len >>= 7;
        if (len == 0) {
            try out.append(arena, byte);
            break;
        }
        try out.append(arena, byte | 0x80);
    }
    try out.appendSlice(arena, payload);
}

fn appendWide(arena: std.mem.Allocator, out: *std.ArrayList(u8), text: []const u8) !void {
    var cch: [4]u8 = undefined;
    std.mem.writeInt(u32, &cch, @intCast(text.len), .little);
    try out.appendSlice(arena, &cch);
    for (text) |byte| {
        try out.append(arena, byte);
        try out.append(arena, 0);
    }
}

fn cellPayload(arena: std.mem.Allocator, col: u32, style: u32) !std.ArrayList(u8) {
    var out: std.ArrayList(u8) = .empty;
    var header: [8]u8 = undefined;
    std.mem.writeInt(u32, header[0..4], col, .little);
    std.mem.writeInt(u32, header[4..8], style, .little);
    try out.appendSlice(arena, &header);
    return out;
}

const BundleShape = enum { spec, wide };

fn buildXlsb(arena: std.mem.Allocator, shape: BundleShape) ![]const u8 {
    var workbook: std.ArrayList(u8) = .empty;
    {
        var payload: std.ArrayList(u8) = .empty;
        try payload.appendSlice(arena, &[_]u8{0} ** 4); // hsState
        // The wide shape reproduces files in the wild (POI corpus): one
        // extra field before the strings, iTabID last.
        if (shape == .wide) try payload.appendSlice(arena, &[_]u8{0} ** 4);
        try payload.appendSlice(arena, &[_]u8{ 1, 0, 0, 0 }); // iTabID
        try appendWide(arena, &payload, "rId1");
        try appendWide(arena, &payload, "Sheet1");
        try appendRecord(arena, &workbook, brt_bundle_sh, payload.items);
    }

    var sst: std.ArrayList(u8) = .empty;
    try appendRecord(arena, &sst, brt_begin_sst, &[_]u8{ 1, 0, 0, 0, 1, 0, 0, 0 });
    {
        var payload: std.ArrayList(u8) = .empty;
        try payload.append(arena, 0);
        try appendWide(arena, &payload, "Alpha");
        try appendRecord(arena, &sst, brt_sst_item, payload.items);
    }

    var styles: std.ArrayList(u8) = .empty;
    try appendRecord(arena, &styles, brt_begin_cell_xfs, &.{});
    var xf: [16]u8 = @splat(0);
    try appendRecord(arena, &styles, brt_xf, &xf);
    std.mem.writeInt(u16, xf[2..4], 14, .little);
    try appendRecord(arena, &styles, brt_xf, &xf);
    try appendRecord(arena, &styles, brt_end_cell_xfs, &.{});

    var sheet: std.ArrayList(u8) = .empty;
    var row: [8]u8 = @splat(0);
    try appendRecord(arena, &sheet, brt_row_hdr, &row);
    {
        var cell = try cellPayload(arena, 0, 0);
        var isst: [4]u8 = undefined;
        std.mem.writeInt(u32, &isst, 0, .little);
        try cell.appendSlice(arena, &isst);
        try appendRecord(arena, &sheet, brt_cell_isst, cell.items);
    }
    {
        var cell = try cellPayload(arena, 1, 0);
        try appendWide(arena, &cell, "Inline");
        try appendRecord(arena, &sheet, brt_cell_st, cell.items);
    }
    std.mem.writeInt(u32, row[0..4], 1, .little);
    try appendRecord(arena, &sheet, brt_row_hdr, &row);
    {
        var cell = try cellPayload(arena, 0, 0);
        var rk: [4]u8 = undefined;
        std.mem.writeInt(u32, &rk, (7 << 2) | 0x02, .little);
        try cell.appendSlice(arena, &rk);
        try appendRecord(arena, &sheet, brt_cell_rk, cell.items);
    }
    {
        var cell = try cellPayload(arena, 1, 0);
        var real: [8]u8 = undefined;
        std.mem.writeInt(u64, &real, @bitCast(@as(f64, 2.5)), .little);
        try cell.appendSlice(arena, &real);
        try appendRecord(arena, &sheet, brt_cell_real, cell.items);
    }
    std.mem.writeInt(u32, row[0..4], 2, .little);
    try appendRecord(arena, &sheet, brt_row_hdr, &row);
    {
        var cell = try cellPayload(arena, 0, 1);
        var real: [8]u8 = undefined;
        std.mem.writeInt(u64, &real, @bitCast(@as(f64, 45306.0)), .little);
        try cell.appendSlice(arena, &real);
        try appendRecord(arena, &sheet, brt_cell_real, cell.items);
    }
    {
        var cell = try cellPayload(arena, 1, 0);
        try cell.append(arena, 1);
        try appendRecord(arena, &sheet, brt_cell_bool, cell.items);
    }

    const rels =
        \\<?xml version="1.0"?>
        \\<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        \\<Relationship Id="rId1"
        \\ Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet"
        \\ Target="worksheets/sheet1.bin"/>
        \\</Relationships>
    ;
    return ooxml.zip.buildStoredArchive(arena, &.{
        .{ .name = "xl/workbook.bin", .data = workbook.items },
        .{ .name = "xl/_rels/workbook.bin.rels", .data = rels },
        .{ .name = "xl/sharedStrings.bin", .data = sst.items },
        .{ .name = "xl/styles.bin", .data = styles.items },
        .{ .name = "xl/worksheets/sheet1.bin", .data = sheet.items },
    });
}

fn convertXlsb(arena: std.mem.Allocator, bytes: []const u8, reports: *core.Reports) !core.ast.Document {
    const store = try arena.create(core.ast.Store);
    store.* = .{};
    var b = core.builder.Builder.init(arena, store, .{});
    var ctx: core.ReadContext = .{
        .gpa = arena,
        .out = .{ .builder = &b },
        .input = .{ .bytes = bytes },
        .input_name = "test.xlsb",
        .reports = reports,
        .manifest_in = null,
        .limits = .{},
    };
    try read(&ctx);
    const doc = try b.finish();
    try core.ast.validate(&doc, .{});
    return doc;
}

test "a binary worksheet becomes a heading and a typed table" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const reports = try arena.create(core.Reports);
    reports.* = core.Reports.init(arena, .{});

    const bytes = try buildXlsb(arena, .spec);
    const doc = try convertXlsb(arena, bytes, reports);

    var headings: u32 = 0;
    var tables: u32 = 0;
    var heads: u32 = 0;
    var rows: u32 = 0;
    for (doc.store.blocks.items(.tag)) |tag| switch (tag) {
        .heading => headings += 1,
        .table => tables += 1,
        .table_head => heads += 1,
        .table_row => rows += 1,
        else => {},
    };
    try testing.expectEqual(@as(u32, 1), headings);
    try testing.expectEqual(@as(u32, 1), tables);
    try testing.expectEqual(@as(u32, 1), heads);
    try testing.expectEqual(@as(u32, 3), rows);

    const text = doc.store.text.items;
    try testing.expect(std.mem.indexOf(u8, text, "Sheet1") != null);
    try testing.expect(std.mem.indexOf(u8, text, "Alpha") != null);
    try testing.expect(std.mem.indexOf(u8, text, "Inline") != null);
    try testing.expect(std.mem.indexOf(u8, text, "7") != null);
    try testing.expect(std.mem.indexOf(u8, text, "2.5") != null);
    try testing.expect(std.mem.indexOf(u8, text, "2024-01-15") != null);
    try testing.expect(std.mem.indexOf(u8, text, "TRUE") != null);
}

test "grid facets carry record coordinates and value types" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const reports = try arena.create(core.Reports);
    reports.* = core.Reports.init(arena, .{});

    const bytes = try buildXlsb(arena, .spec);
    const doc = try convertXlsb(arena, bytes, reports);

    const store = doc.store;
    const rows = store.grid_facets.items;
    try testing.expect(rows.len >= 4);
    var saw_number = false;
    var saw_date = false;
    var saw_boolean = false;
    var saw_text = false;
    for (rows) |row| {
        try testing.expectEqualStrings("Sheet1", store.textSlice(row.sheet));
        try testing.expect(row.cached.len > 0);
        switch (row.value_type) {
            .number => saw_number = true,
            .date => saw_date = true,
            .boolean => saw_boolean = true,
            .text => saw_text = true,
            else => {},
        }
    }
    try testing.expect(saw_number);
    try testing.expect(saw_date);
    try testing.expect(saw_boolean);
    try testing.expect(saw_text);
}

test "the wild BrtBundleSh shape with an extra field still finds its sheets" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const reports = try arena.create(core.Reports);
    reports.* = core.Reports.init(arena, .{});

    const bytes = try buildXlsb(arena, .wide);
    const doc = try convertXlsb(arena, bytes, reports);

    var tables: u32 = 0;
    for (doc.store.blocks.items(.tag)) |tag| {
        if (tag == .table) tables += 1;
    }
    try testing.expectEqual(@as(u32, 1), tables);
    try testing.expect(std.mem.indexOf(u8, doc.store.text.items, "Alpha") != null);
    try testing.expectEqual(@as(usize, 0), reports.entries.items.len);
}

test "a workbook whose sheets cannot load refuses instead of silence" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const reports = try arena.create(core.Reports);
    reports.* = core.Reports.init(arena, .{});

    var workbook: std.ArrayList(u8) = .empty;
    var payload: std.ArrayList(u8) = .empty;
    try payload.appendSlice(arena, &[_]u8{0} ** 8);
    try appendWide(arena, &payload, "rId9");
    try appendWide(arena, &payload, "Ghost");
    try appendRecord(arena, &workbook, brt_bundle_sh, payload.items);
    const bytes = try ooxml.zip.buildStoredArchive(arena, &.{
        .{ .name = "xl/workbook.bin", .data = workbook.items },
    });
    try testing.expectError(error.Malformed, convertXlsb(arena, bytes, reports));
    try testing.expectEqualStrings(
        "xlsb.sheets-unreadable",
        reports.entries.items[0].report.code,
    );
}

test "a broken archive is a refusal with its own code" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const reports = try arena.create(core.Reports);
    reports.* = core.Reports.init(arena, .{});

    try testing.expectError(
        error.Malformed,
        convertXlsb(arena, "not a zip at all", reports),
    );
    try testing.expectEqualStrings(
        "xlsb.not-an-archive",
        reports.entries.items[0].report.code,
    );
}
