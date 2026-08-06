//! The legacy Excel reader (`.xls`, BIFF8): the Workbook stream's globals
//! substream (shared strings, cell formats, sheet directory), then one
//! table per worksheet, mirroring the XLSX conventions — sheet name as a
//! heading, first row as the table head, dates and percentages formatted
//! from their number formats, cached formula values used as-is.

const std = @import("std");
const assert = std.debug.assert;
const core = @import("zenfmt_core");
const cfb = @import("zenfmt_cfb");

pub const reader = core.Reader(.{
    .id = "ai.insan.zenfmt.xls",
    .format = "xls",
    .extensions = &.{"xls"},
    .input = .seekable,
    .read = read,
});

const rec_bof: u16 = 0x0809;
const rec_eof: u16 = 0x000A;
const rec_filepass: u16 = 0x002F;
const rec_continue: u16 = 0x003C;
const rec_datemode: u16 = 0x0022;
const rec_boundsheet: u16 = 0x0085;
const rec_sst: u16 = 0x00FC;
const rec_format: u16 = 0x041E;
const rec_xf: u16 = 0x00E0;
const rec_labelsst: u16 = 0x00FD;
const rec_label: u16 = 0x0204;
const rec_number: u16 = 0x0203;
const rec_rk: u16 = 0x027E;
const rec_mulrk: u16 = 0x00BD;
const rec_boolerr: u16 = 0x0205;
const rec_formula: u16 = 0x0006;
const rec_string: u16 = 0x0207;

const biff8_version: u16 = 0x0600;

const NumberKind = enum { general, date, percent };

fn read(ctx: *core.ReadContext) core.ReadError!void {
    const arena = ctx.gpa;
    var file = cfb.Cfb.open(arena, ctx.input.bytes, ctx.limits) catch |err| {
        try ctx.reports.add(notCompoundReport());
        return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.LimitExceeded => error.LimitExceeded,
            else => error.Malformed,
        };
    };
    const entry = file.find("Workbook") orelse file.find("Book") orelse {
        try ctx.reports.add(notWorkbookReport());
        return error.Malformed;
    };
    const stream = file.readStream(arena, entry, ctx.limits) catch |err| {
        try ctx.reports.add(notWorkbookReport());
        return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.LimitExceeded => error.LimitExceeded,
            else => error.Malformed,
        };
    };

    var globals = Globals{ .arena = arena };
    try globals.parse(ctx, stream);
    var formula_noted = false;
    for (globals.sheets.items) |sheet| {
        try readSheet(ctx, arena, stream, sheet, &globals, &formula_noted);
    }
}

const Sheet = struct {
    name: []const u8,
    offset: u32,
};

const Globals = struct {
    arena: std.mem.Allocator,
    sheets: std.ArrayList(Sheet) = .empty,
    shared: std.ArrayList([]const u8) = .empty,
    xf_kinds: std.ArrayList(NumberKind) = .empty,
    custom_kinds: std.AutoHashMapUnmanaged(u16, NumberKind) = .empty,
    date1904: bool = false,

    /// The globals substream runs from the first BOF to its matching EOF.
    fn parse(g: *Globals, ctx: *core.ReadContext, stream: []const u8) core.ReadError!void {
        var iter = RecordIter{ .bytes = stream };
        var first = true;
        while (iter.next()) |record| {
            switch (record.id) {
                rec_bof => {
                    if (record.data.len < 4) return malformed(ctx);
                    if (first and readInt(u16, record.data[0..2]) != biff8_version) {
                        try ctx.reports.add(unsupportedBiffReport());
                        return error.Malformed;
                    }
                    first = false;
                },
                rec_eof => break,
                rec_filepass => {
                    try ctx.reports.add(encryptionReport());
                    return error.Malformed;
                },
                rec_datemode => {
                    if (record.data.len >= 2) g.date1904 = readInt(u16, record.data[0..2]) == 1;
                },
                rec_boundsheet => try g.boundsheet(ctx, record.data),
                rec_format => {
                    if (record.data.len < 2) continue;
                    const ifmt = readInt(u16, record.data[0..2]);
                    var cursor = StringCursor{ .iter = &iter, .data = record.data, .pos = 2 };
                    const text = cursor.readString(g.arena, .sixteen_bit) catch continue;
                    try g.custom_kinds.put(g.arena, ifmt, kindFromFormat(text));
                },
                rec_xf => {
                    if (record.data.len < 4) continue;
                    const ifmt = readInt(u16, record.data[2..4]);
                    try g.xf_kinds.append(g.arena, g.kindOf(ifmt));
                },
                rec_sst => try g.sharedStrings(&iter, record.data),
                else => {},
            }
        }
    }

    fn boundsheet(g: *Globals, ctx: *core.ReadContext, data: []const u8) core.ReadError!void {
        _ = ctx;
        if (data.len < 8) return;
        const sheet_type = data[5];
        if (sheet_type != 0) return; // dialogs, macros, charts
        const cch = data[6];
        const high = data[7] & 0x01 != 0;
        var name: std.ArrayList(u8) = .empty;
        if (high) {
            const end = @min(data.len, 8 + @as(usize, cch) * 2);
            try cfb.utf16LeToUtf8(g.arena, &name, data[8..end]);
        } else {
            const end = @min(data.len, 8 + @as(usize, cch));
            for (data[8..end]) |byte| try appendCodepoint(g.arena, &name, cfb.cp1252ToUnicode(byte));
        }
        try g.sheets.append(g.arena, .{
            .name = name.items,
            .offset = readInt(u32, data[0..4]),
        });
    }

    fn sharedStrings(g: *Globals, iter: *RecordIter, data: []const u8) core.ReadError!void {
        if (data.len < 8) return;
        const unique = readInt(u32, data[4..8]);
        var cursor = StringCursor{ .iter = iter, .data = data, .pos = 8 };
        for (0..@min(unique, 1 << 22)) |_| {
            const text = cursor.readString(g.arena, .sixteen_bit) catch break;
            try g.shared.append(g.arena, text);
        }
    }

    fn kindOf(g: *const Globals, ifmt: u16) NumberKind {
        if (g.custom_kinds.get(ifmt)) |kind| return kind;
        return switch (ifmt) {
            14...22, 45...47 => .date,
            9, 10 => .percent,
            else => .general,
        };
    }

    fn cellKind(g: *const Globals, ixfe: u16) NumberKind {
        if (ixfe >= g.xf_kinds.items.len) return .general;
        return g.xf_kinds.items[ixfe];
    }
};

/// A date format shows year/month/day/hour codes; a percent format shows
/// a literal `%`. Anything else formats as the raw number.
fn kindFromFormat(format: []const u8) NumberKind {
    if (std.mem.indexOfScalar(u8, format, '%') != null) return .percent;
    for (format) |byte| switch (byte) {
        'y', 'Y', 'd', 'D', 'h', 'H', 'm', 'M', 's', 'S' => return .date,
        else => {},
    };
    return .general;
}

// ------------------------------------------------------------ worksheets

const Cell = struct {
    row: u32,
    col: u32,
    text: []const u8,
};

const PendingFormula = struct {
    row: u32,
    col: u32,
    kind: NumberKind,
};

fn readSheet(
    ctx: *core.ReadContext,
    arena: std.mem.Allocator,
    stream: []const u8,
    sheet: Sheet,
    globals: *const Globals,
    formula_noted: *bool,
) core.ReadError!void {
    if (sheet.offset >= stream.len) return;
    var cells: std.ArrayList(Cell) = .empty;
    defer cells.deinit(arena);

    var iter = RecordIter{ .bytes = stream, .pos = sheet.offset };
    var pending_formula: ?PendingFormula = null;
    var depth: u32 = 0;
    while (iter.next()) |record| {
        switch (record.id) {
            rec_bof => depth += 1,
            rec_eof => {
                if (depth <= 1) break;
                depth -= 1;
            },
            rec_string => {
                const pending = pending_formula orelse continue;
                pending_formula = null;
                var cursor = StringCursor{ .iter = &iter, .data = record.data, .pos = 0 };
                const text = cursor.readString(arena, .sixteen_bit) catch continue;
                try cells.append(arena, .{ .row = pending.row, .col = pending.col, .text = text });
            },
            rec_labelsst, rec_label, rec_number, rec_rk, rec_mulrk, rec_boolerr, rec_formula => {
                pending_formula = null;
                try sheetCell(ctx, arena, &iter, record, globals, &cells, &pending_formula, formula_noted);
            },
            else => {},
        }
    }
    try emitSheet(ctx, arena, sheet.name, cells.items);
}

fn sheetCell(
    ctx: *core.ReadContext,
    arena: std.mem.Allocator,
    iter: *RecordIter,
    record: Record,
    globals: *const Globals,
    cells: *std.ArrayList(Cell),
    pending_formula: *?PendingFormula,
    formula_noted: *bool,
) core.ReadError!void {
    const data = record.data;
    if (data.len < 6) return;
    const row = readInt(u16, data[0..2]);
    const col = readInt(u16, data[2..4]);
    switch (record.id) {
        rec_labelsst => {
            if (data.len < 10) return;
            const isst = readInt(u32, data[6..10]);
            if (isst >= globals.shared.items.len) return;
            try cells.append(arena, .{ .row = row, .col = col, .text = globals.shared.items[isst] });
        },
        rec_label => {
            var cursor = StringCursor{ .iter = iter, .data = data, .pos = 6 };
            const text = cursor.readString(arena, .sixteen_bit) catch return;
            try cells.append(arena, .{ .row = row, .col = col, .text = text });
        },
        rec_number => {
            if (data.len < 14) return;
            const kind = globals.cellKind(readInt(u16, data[4..6]));
            const value: f64 = @bitCast(readInt(u64, data[6..14]));
            const text = try numberText(arena, value, kind, globals.date1904);
            try cells.append(arena, .{ .row = row, .col = col, .text = text });
        },
        rec_rk => {
            if (data.len < 10) return;
            const kind = globals.cellKind(readInt(u16, data[4..6]));
            const value = rkValue(readInt(u32, data[6..10]));
            const text = try numberText(arena, value, kind, globals.date1904);
            try cells.append(arena, .{ .row = row, .col = col, .text = text });
        },
        rec_mulrk => {
            if (data.len < 12) return;
            const first_col = col;
            const pairs = (data.len - 6) / 6;
            for (0..pairs) |i| {
                const kind = globals.cellKind(readInt(u16, data[4 + i * 6 ..][0..2]));
                const value = rkValue(readInt(u32, data[6 + i * 6 ..][0..4]));
                const text = try numberText(arena, value, kind, globals.date1904);
                try cells.append(arena, .{
                    .row = row,
                    .col = first_col + @as(u32, @intCast(i)),
                    .text = text,
                });
            }
        },
        rec_boolerr => {
            if (data.len < 8) return;
            const text = if (data[7] != 0)
                errorText(data[6])
            else if (data[6] != 0)
                "TRUE"
            else
                "FALSE";
            try cells.append(arena, .{ .row = row, .col = col, .text = text });
        },
        rec_formula => {
            if (data.len < 14) return;
            const kind = globals.cellKind(readInt(u16, data[4..6]));
            if (readInt(u16, data[12..14]) == 0xFFFF) {
                switch (data[6]) {
                    0 => pending_formula.* = .{ .row = row, .col = col, .kind = kind },
                    1 => try cells.append(arena, .{
                        .row = row,
                        .col = col,
                        .text = if (data[8] != 0) "TRUE" else "FALSE",
                    }),
                    2 => try cells.append(arena, .{
                        .row = row,
                        .col = col,
                        .text = errorText(data[8]),
                    }),
                    else => {
                        if (!formula_noted.*) {
                            formula_noted.* = true;
                            try ctx.reports.add(formulaNote());
                        }
                    },
                }
            } else {
                const value: f64 = @bitCast(readInt(u64, data[6..14]));
                const text = try numberText(arena, value, kind, globals.date1904);
                try cells.append(arena, .{ .row = row, .col = col, .text = text });
            }
        },
        else => unreachable,
    }
}

/// RK: bit 0 divides by 100, bit 1 marks a 30-bit integer; otherwise the
/// high 30 bits are the top of an IEEE double.
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

fn numberText(
    arena: std.mem.Allocator,
    value: f64,
    kind: NumberKind,
    date1904: bool,
) core.ReadError![]const u8 {
    switch (kind) {
        .date => {
            const text: ?[]const u8 = formatSerialDate(arena, value, date1904) catch null;
            if (text) |formatted| return formatted;
        },
        .percent => return std.fmt.allocPrint(arena, "{d}%", .{value * 100}),
        .general => {},
    }
    return std.fmt.allocPrint(arena, "{d}", .{value});
}

/// Hinnant's civil-from-days, as in the XLSX reader; the 1904 mode shifts
/// the epoch by 1462 days.
fn formatSerialDate(arena: std.mem.Allocator, serial: f64, date1904: bool) ![]const u8 {
    const adjusted = if (date1904) serial + 1462 else serial;
    if (adjusted < 1 or adjusted > 2958465) return error.OutOfRange;
    const days = @as(i64, @intFromFloat(adjusted)) - 25569;
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

// ------------------------------------------------------------- emission

const max_columns = 1024;

fn emitSheet(
    ctx: *core.ReadContext,
    arena: std.mem.Allocator,
    name: []const u8,
    cells: []Cell,
) core.ReadError!void {
    if (cells.len == 0) return;
    std.mem.sort(Cell, cells, {}, struct {
        fn lessThan(_: void, a: Cell, b: Cell) bool {
            if (a.row != b.row) return a.row < b.row;
            return a.col < b.col;
        }
    }.lessThan);
    var columns: u32 = 0;
    for (cells) |cell| columns = @max(columns, @min(cell.col, max_columns - 1) + 1);

    const heading = try ctx.out.beginHeading(2);
    try ctx.out.text(name);
    ctx.out.endBlock(heading);

    var alignments: std.ArrayList(core.payload.Alignment) = .empty;
    defer alignments.deinit(arena);
    try alignments.appendNTimes(arena, .default, columns);
    const table = try ctx.out.beginTable(alignments.items);

    var head_token: ?core.builder.BlockToken = try ctx.out.beginBlock(.table_head);
    var body_token: ?core.builder.BlockToken = null;
    var index: usize = 0;
    var first_row = true;
    while (index < cells.len) {
        const row = cells[index].row;
        if (!first_row and head_token != null) {
            ctx.out.endBlock(head_token.?);
            head_token = null;
            body_token = try ctx.out.beginTableBody(.{ .row_head_columns = 0, .head_rows = 0 });
        }
        const row_token = try ctx.out.beginBlock(.table_row);
        var emitted: u32 = 0;
        while (index < cells.len and cells[index].row == row) : (index += 1) {
            const cell = cells[index];
            if (cell.col >= max_columns) continue;
            while (emitted < cell.col) : (emitted += 1) try emitCellText(ctx, "");
            if (emitted == cell.col) {
                try emitCellText(ctx, cell.text);
                emitted += 1;
            }
        }
        while (emitted < columns) : (emitted += 1) try emitCellText(ctx, "");
        ctx.out.endBlock(row_token);
        first_row = false;
    }
    if (head_token) |token| ctx.out.endBlock(token);
    if (body_token) |token| ctx.out.endBlock(token);
    ctx.out.endBlock(table);
}

fn emitCellText(ctx: *core.ReadContext, text: []const u8) core.ReadError!void {
    const cell = try ctx.out.beginTableCell(.plain);
    const plain = try ctx.out.beginPlain();
    if (text.len > 0) try ctx.out.text(text);
    ctx.out.endBlock(plain);
    ctx.out.endBlock(cell);
}

// -------------------------------------------------------- record stream

const Record = struct {
    id: u16,
    data: []const u8,
};

const RecordIter = struct {
    bytes: []const u8,
    pos: usize = 0,

    fn next(it: *RecordIter) ?Record {
        if (it.pos + 4 > it.bytes.len) return null;
        const id = readInt(u16, it.bytes[it.pos..][0..2]);
        const len = readInt(u16, it.bytes[it.pos + 2 ..][0..2]);
        it.pos += 4;
        if (it.pos + len > it.bytes.len) return null;
        const data = it.bytes[it.pos..][0..len];
        it.pos += len;
        return .{ .id = id, .data = data };
    }

    fn peekContinue(it: *RecordIter) ?[]const u8 {
        const saved = it.pos;
        const record = it.next() orelse {
            it.pos = saved;
            return null;
        };
        if (record.id != rec_continue) {
            it.pos = saved;
            return null;
        }
        return record.data;
    }
};

const StringWidth = enum { sixteen_bit };

/// Reads XLUnicodeRichExtendedString values, following CONTINUE records.
/// Char data may split at a record edge, where a fresh flags byte
/// restates the encoding; fixed fields never split in files Excel wrote.
const StringCursor = struct {
    iter: *RecordIter,
    data: []const u8,
    pos: usize,

    fn ensure(sc: *StringCursor, need: usize) !void {
        var guard: u32 = 0;
        while (sc.pos + need > sc.data.len) {
            guard += 1;
            if (guard > 64) return error.Malformed;
            if (sc.pos != sc.data.len) return error.Malformed;
            const next_data = sc.iter.peekContinue() orelse return error.Malformed;
            sc.data = next_data;
            sc.pos = 0;
        }
    }

    fn takeInt(sc: *StringCursor, comptime T: type) !T {
        try sc.ensure(@sizeOf(T));
        const value = readInt(T, sc.data[sc.pos..][0..@sizeOf(T)]);
        sc.pos += @sizeOf(T);
        return value;
    }

    fn readString(sc: *StringCursor, arena: std.mem.Allocator, width: StringWidth) ![]const u8 {
        const cch: usize = switch (width) {
            .sixteen_bit => try sc.takeInt(u16),
        };
        var flags = try sc.takeInt(u8);
        const rich = flags & 0x08 != 0;
        const ext = flags & 0x04 != 0;
        const runs: usize = if (rich) try sc.takeInt(u16) else 0;
        const ext_bytes: usize = if (ext) try sc.takeInt(u32) else 0;

        var out: std.ArrayList(u8) = .empty;
        var remaining = cch;
        var guard: u32 = 0;
        while (remaining > 0) {
            guard += 1;
            if (guard > 4096) return error.Malformed;
            if (sc.pos == sc.data.len) {
                // A split: the continuation restates the width flag.
                sc.data = sc.iter.peekContinue() orelse return error.Malformed;
                sc.pos = 0;
                flags = try sc.takeInt(u8);
            }
            const high = flags & 0x01 != 0;
            const unit: usize = if (high) 2 else 1;
            const available = (sc.data.len - sc.pos) / unit;
            const take = @min(remaining, available);
            if (take == 0) return error.Malformed;
            const chunk = sc.data[sc.pos..][0 .. take * unit];
            if (high) {
                try cfb.utf16LeToUtf8(arena, &out, chunk);
            } else {
                for (chunk) |byte| try appendCodepoint(arena, &out, cfb.cp1252ToUnicode(byte));
            }
            sc.pos += take * unit;
            remaining -= take;
        }
        try sc.skip(runs * 4 + ext_bytes);
        return out.items;
    }

    fn skip(sc: *StringCursor, count: usize) !void {
        var remaining = count;
        var guard: u32 = 0;
        while (remaining > 0) {
            guard += 1;
            if (guard > 4096) return error.Malformed;
            if (sc.pos == sc.data.len) {
                sc.data = sc.iter.peekContinue() orelse return error.Malformed;
                sc.pos = 0;
            }
            const take = @min(remaining, sc.data.len - sc.pos);
            sc.pos += take;
            remaining -= take;
        }
    }
};

fn appendCodepoint(
    arena: std.mem.Allocator,
    out: *std.ArrayList(u8),
    code: u21,
) error{OutOfMemory}!void {
    var encoded: [4]u8 = undefined;
    const length = std.unicode.utf8Encode(code, &encoded) catch return;
    try out.appendSlice(arena, encoded[0..length]);
}

fn malformed(ctx: *core.ReadContext) core.ReadError {
    ctx.reports.add(notWorkbookReport()) catch |err| return err;
    return error.Malformed;
}

fn readInt(comptime T: type, bytes: *const [@sizeOf(T)]u8) T {
    return std.mem.readInt(T, bytes, .little);
}

// ------------------------------------------------------------- reports

fn notCompoundReport() core.Report {
    return .{
        .severity = .err,
        .code = "xls.not-a-compound-file",
        .title = "NOT A READABLE EXCEL FILE",
        .problem = "This file is not a compound (OLE) file zenfmt can " ++
            "read, or it trips a container safety limit.",
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
        .code = "xls.missing-workbook",
        .title = "THE WORKBOOK STREAM IS MISSING",
        .problem = "The compound file opens but has no readable Workbook " ++
            "stream, so it is not an Excel workbook.",
        .consequence = "The conversion stopped and no output file was created.",
        .directions = &.{.{
            .title = "Re-export the file",
            .explanation = "Re-save the workbook from Excel or LibreOffice " ++
                "and convert the fresh copy, or export it as .xlsx.",
        }},
    };
}

fn encryptionReport() core.Report {
    return .{
        .severity = .err,
        .code = "xls.encryption-refused",
        .title = "THE WORKBOOK IS ENCRYPTED",
        .problem = "The workbook carries a FILEPASS record, and zenfmt " ++
            "never attempts decryption.",
        .consequence = "The conversion stopped and no output file was created.",
        .directions = &.{.{
            .title = "Decrypt it first",
            .explanation = "Open the workbook in Excel with its password, " ++
                "save an unencrypted copy, and convert that.",
        }},
    };
}

fn unsupportedBiffReport() core.Report {
    return .{
        .severity = .err,
        .code = "xls.unsupported-biff",
        .title = "ONLY BIFF8 WORKBOOKS ARE READ",
        .problem = "This workbook uses a BIFF version older than Excel " ++
            "97 (BIFF8), which this reader does not decode.",
        .consequence = "The conversion stopped and no output file was created.",
        .directions = &.{.{
            .title = "Re-save in a newer format",
            .explanation = "Open the workbook in Excel or LibreOffice and " ++
                "save it as .xls (Excel 97) or .xlsx, then convert that.",
        }},
    };
}

fn formulaNote() core.Report {
    return .{
        .severity = .note,
        .code = "xls.formula-without-cached-value",
        .title = "FORMULAS WITHOUT CACHED VALUES",
        .problem = "Some cells hold formulas with no cached result, and " ++
            "zenfmt does not evaluate formulas.",
        .consequence = "Those cells are empty in the output.",
        .loss = .degraded,
        .directions = &.{.{
            .title = "Recalculate and re-save",
            .explanation = "Open the workbook, let it recalculate, save, " ++
                "and convert again; the cached values will then be present.",
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
    var header: [4]u8 = undefined;
    std.mem.writeInt(u16, header[0..2], id, .little);
    std.mem.writeInt(u16, header[2..4], @intCast(payload.len), .little);
    try out.appendSlice(arena, &header);
    try out.appendSlice(arena, payload);
}

fn cellHeader(row: u16, col: u16, ixfe: u16) [6]u8 {
    var data: [6]u8 = undefined;
    std.mem.writeInt(u16, data[0..2], row, .little);
    std.mem.writeInt(u16, data[2..4], col, .little);
    std.mem.writeInt(u16, data[4..6], ixfe, .little);
    return data;
}

fn buildWorkbook(arena: std.mem.Allocator, encrypted: bool, biff5: bool) ![]const u8 {
    var globals: std.ArrayList(u8) = .empty;
    var bof: [16]u8 = @splat(0);
    std.mem.writeInt(u16, bof[0..2], if (biff5) 0x0500 else biff8_version, .little);
    std.mem.writeInt(u16, bof[2..4], 0x0005, .little);
    try appendRecord(arena, &globals, rec_bof, &bof);
    if (encrypted) try appendRecord(arena, &globals, rec_filepass, &.{ 0x01, 0x00 });

    // Two XFs: general, then the builtin date format.
    var xf: [20]u8 = @splat(0);
    try appendRecord(arena, &globals, rec_xf, &xf);
    std.mem.writeInt(u16, xf[2..4], 14, .little);
    try appendRecord(arena, &globals, rec_xf, &xf);

    // SST: "Name" compressed and "Café" in UTF-16.
    var sst: std.ArrayList(u8) = .empty;
    try sst.appendSlice(arena, &.{ 2, 0, 0, 0, 2, 0, 0, 0 });
    try sst.appendSlice(arena, &([_]u8{ 4, 0, 0x00 } ++ "Name".*));
    try sst.appendSlice(arena, &[_]u8{ 4, 0, 0x01 });
    try sst.appendSlice(arena, "C\x00a\x00f\x00\xe9\x00");
    try appendRecord(arena, &globals, rec_sst, sst.items);

    // The BOUNDSHEET offset lands after globals; compute it below.
    var boundsheet: [12]u8 = @splat(0);
    boundsheet[6] = 4; // cch
    @memcpy(boundsheet[8..12], "Data");
    const boundsheet_at = globals.items.len + 4;
    try appendRecord(arena, &globals, rec_boundsheet, &boundsheet);
    try appendRecord(arena, &globals, rec_eof, &.{});

    var sheet: std.ArrayList(u8) = .empty;
    var sheet_bof: [16]u8 = @splat(0);
    std.mem.writeInt(u16, sheet_bof[0..2], biff8_version, .little);
    std.mem.writeInt(u16, sheet_bof[2..4], 0x0010, .little);
    try appendRecord(arena, &sheet, rec_bof, &sheet_bof);
    // Row 0: the two shared strings.
    var labelsst = cellHeader(0, 0, 0) ++ [_]u8{ 0, 0, 0, 0 };
    try appendRecord(arena, &sheet, rec_labelsst, &labelsst);
    std.mem.writeInt(u16, labelsst[2..4], 1, .little);
    std.mem.writeInt(u32, labelsst[6..10], 1, .little);
    try appendRecord(arena, &sheet, rec_labelsst, &labelsst);
    // Row 1: a NUMBER and an integer RK.
    var number = cellHeader(1, 0, 0) ++ [_]u8{0} ** 8;
    std.mem.writeInt(u64, number[6..14], @bitCast(@as(f64, 42.5)), .little);
    try appendRecord(arena, &sheet, rec_number, &number);
    var rk = cellHeader(1, 1, 0) ++ [_]u8{0} ** 4;
    std.mem.writeInt(u32, rk[6..10], (7 << 2) | 0x02, .little);
    try appendRecord(arena, &sheet, rec_rk, &rk);
    // Row 2: a cached numeric formula and a cached string formula.
    var formula = cellHeader(2, 0, 0) ++ [_]u8{0} ** 16;
    std.mem.writeInt(u64, formula[6..14], @bitCast(@as(f64, 3.0)), .little);
    try appendRecord(arena, &sheet, rec_formula, &formula);
    var string_formula = cellHeader(2, 1, 0) ++ [_]u8{0} ** 16;
    string_formula[6] = 0;
    string_formula[12] = 0xFF;
    string_formula[13] = 0xFF;
    try appendRecord(arena, &sheet, rec_formula, &string_formula);
    try appendRecord(arena, &sheet, rec_string, &([_]u8{ 6, 0, 0x00 } ++ "cached".*));
    // Row 3: a date-styled serial and a boolean.
    var date = cellHeader(3, 0, 1) ++ [_]u8{0} ** 8;
    std.mem.writeInt(u64, date[6..14], @bitCast(@as(f64, 45306.0)), .little);
    try appendRecord(arena, &sheet, rec_number, &date);
    const boolerr = cellHeader(3, 1, 0) ++ [_]u8{ 1, 0 };
    try appendRecord(arena, &sheet, rec_boolerr, &boolerr);
    try appendRecord(arena, &sheet, rec_eof, &.{});

    var stream: std.ArrayList(u8) = .empty;
    try stream.appendSlice(arena, globals.items);
    try stream.appendSlice(arena, sheet.items);
    std.mem.writeInt(u32, stream.items[boundsheet_at..][0..4], @intCast(globals.items.len), .little);
    return cfb.buildFile(arena, &.{.{ .name = "Workbook", .data = stream.items }});
}

fn convertXls(arena: std.mem.Allocator, bytes: []const u8, reports: *core.Reports) !core.ast.Document {
    const store = try arena.create(core.ast.Store);
    store.* = .{};
    var b = core.builder.Builder.init(arena, store, .{});
    var ctx: core.ReadContext = .{
        .gpa = arena,
        .out = .{ .builder = &b },
        .input = .{ .bytes = bytes },
        .input_name = "test.xls",
        .reports = reports,
        .manifest_in = null,
        .limits = .{},
    };
    try read(&ctx);
    const doc = try b.finish();
    try core.ast.validate(&doc, .{});
    return doc;
}

test "a BIFF8 sheet becomes a heading and a typed table" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const reports = try arena.create(core.Reports);
    reports.* = core.Reports.init(arena, .{});

    const bytes = try buildWorkbook(arena, false, false);
    const doc = try convertXls(arena, bytes, reports);

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
    try testing.expectEqual(@as(u32, 4), rows);

    const text = doc.store.text.items;
    try testing.expect(std.mem.indexOf(u8, text, "Data") != null);
    try testing.expect(std.mem.indexOf(u8, text, "Café") != null);
    try testing.expect(std.mem.indexOf(u8, text, "42.5") != null);
    try testing.expect(std.mem.indexOf(u8, text, "7") != null);
    try testing.expect(std.mem.indexOf(u8, text, "3") != null);
    try testing.expect(std.mem.indexOf(u8, text, "cached") != null);
    try testing.expect(std.mem.indexOf(u8, text, "2024-01-15") != null);
    try testing.expect(std.mem.indexOf(u8, text, "TRUE") != null);
}

test "FILEPASS and pre-BIFF8 workbooks are refusals with their own codes" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    {
        const reports = try arena.create(core.Reports);
        reports.* = core.Reports.init(arena, .{});
        const bytes = try buildWorkbook(arena, true, false);
        try testing.expectError(error.Malformed, convertXls(arena, bytes, reports));
        try testing.expectEqualStrings(
            "xls.encryption-refused",
            reports.entries.items[0].report.code,
        );
    }
    {
        const reports = try arena.create(core.Reports);
        reports.* = core.Reports.init(arena, .{});
        const bytes = try buildWorkbook(arena, false, true);
        try testing.expectError(error.Malformed, convertXls(arena, bytes, reports));
        try testing.expectEqualStrings(
            "xls.unsupported-biff",
            reports.entries.items[0].report.code,
        );
    }
}
