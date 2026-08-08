//! The XLSX reader (ZDS 0002, The other formats): each sheet becomes a
//! heading naming it, followed by a table. Cell text usually lives in
//! `sharedStrings.xml`; number formats are applied for dates and
//! percentages, since a raw serial date would be worse than useless.
//! Formulas are not evaluated: the cached value is used, with a note when
//! it is absent. Sparse sheets are materialized to keep rows rectangular.

const std = @import("std");
const assert = std.debug.assert;
const core = @import("zenfmt_core");
const xml = @import("zenfmt_xml");
const ooxml = @import("zenfmt_ooxml");

pub const reader = core.Reader(.{
    .id = "ai.insan.zenfmt.xlsx",
    .format = "xlsx",
    .extensions = &.{ "xlsx", "xlsm" },
    .input = .seekable,
    .read = read,
});

const main_ns = "http://schemas.openxmlformats.org/spreadsheetml/2006/main";
const r_ns = "http://schemas.openxmlformats.org/officeDocument/2006/relationships";

fn read(ctx: *core.ReadContext) core.ReadError!void {
    const arena = ctx.gpa;
    const source = ooxml.zipSource(ctx);
    var archive = ooxml.zip.Archive.openSource(arena, source, ctx.limits) catch |err| {
        try ctx.reports.add(archiveReport());
        return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.LimitExceeded => error.LimitExceeded,
            else => error.Malformed,
        };
    };

    const shared = blk: {
        const bytes = extract(&archive, arena, "xl/sharedStrings.xml", ctx) orelse
            break :blk &[_][]const u8{};
        break :blk parseSharedStrings(arena, bytes, ctx.limits) catch &[_][]const u8{};
    };
    const date_styles = blk: {
        const bytes = extract(&archive, arena, "xl/styles.xml", ctx) orelse
            break :blk &[_]NumberKind{};
        break :blk parseCellFormats(arena, bytes, ctx.limits) catch &[_]NumberKind{};
    };
    const workbook_rels = blk: {
        const bytes = extract(&archive, arena, "xl/_rels/workbook.xml.rels", ctx) orelse
            break :blk ooxml.Relationships.empty;
        break :blk ooxml.parseRelationships(
            arena,
            bytes,
            ctx.limits,
        ) catch ooxml.Relationships.empty;
    };

    const workbook_bytes = extract(&archive, arena, "xl/workbook.xml", ctx) orelse {
        try ctx.reports.add(notWorkbookReport());
        return error.Malformed;
    };

    var formula_noted = false;
    var parser = xml.Parser.init(arena, workbook_bytes, ctx.limits.max_xml_depth);
    defer parser.deinit();
    while (true) {
        const event = parser.next() catch {
            try ctx.reports.add(notWorkbookReport());
            return error.Malformed;
        };
        switch (event) {
            .done => break,
            .element_start => |element| {
                if (!element.name.is(main_ns, "sheet")) continue;
                var name: []const u8 = "Sheet";
                var rel_id: []const u8 = "";
                for (element.attributes) |attribute| {
                    if (std.mem.eql(u8, attribute.name.local, "name")) {
                        name = try arena.dupe(u8, attribute.value);
                    } else if (std.mem.eql(u8, attribute.name.uri, r_ns) and
                        std.mem.eql(u8, attribute.name.local, "id"))
                    {
                        rel_id = try arena.dupe(u8, attribute.value);
                    }
                }
                const relationship = workbook_rels.byId(rel_id) orelse continue;
                const part = try ooxml.resolveTarget(arena, "xl", relationship.target);
                const sheet_bytes = extract(&archive, arena, part, ctx) orelse continue;
                try readSheet(ctx, arena, name, sheet_bytes, shared, date_styles, &formula_noted);
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

// ------------------------------------------------------- shared strings

fn parseSharedStrings(
    arena: std.mem.Allocator,
    bytes: []const u8,
    limits: core.Limits,
) ![]const []const u8 {
    var strings: std.ArrayList([]const u8) = .empty;
    var parser = xml.Parser.init(arena, bytes, limits.max_xml_depth);
    defer parser.deinit();

    var current: std.ArrayList(u8) = .empty;
    var in_item = false;
    var in_text = false;
    while (true) {
        switch (try parser.next()) {
            .done => break,
            .element_start => |element| {
                if (element.name.is(main_ns, "si")) {
                    in_item = true;
                    current = .empty;
                } else if (element.name.is(main_ns, "t")) {
                    in_text = !element.self_closing;
                }
            },
            .element_end => |name| {
                if (std.mem.eql(u8, name.local, "si")) {
                    in_item = false;
                    try strings.append(arena, try current.toOwnedSlice(arena));
                } else if (std.mem.eql(u8, name.local, "t")) {
                    in_text = false;
                }
            },
            .text => |value| {
                if (in_item and in_text) try current.appendSlice(arena, value);
            },
        }
    }
    return strings.items;
}

// ------------------------------------------------------- number formats

const NumberKind = enum { general, date, percent };

/// Per cell-format index (the `s` attribute), whether its number format is
/// a date or a percentage — the two families where the raw number lies.
fn parseCellFormats(
    arena: std.mem.Allocator,
    bytes: []const u8,
    limits: core.Limits,
) ![]const NumberKind {
    var kinds: std.ArrayList(NumberKind) = .empty;
    var parser = xml.Parser.init(arena, bytes, limits.max_xml_depth);
    defer parser.deinit();

    var in_cell_xfs = false;
    while (true) {
        switch (try parser.next()) {
            .done => break,
            .element_start => |element| {
                if (element.name.is(main_ns, "cellXfs")) {
                    in_cell_xfs = true;
                } else if (in_cell_xfs and element.name.is(main_ns, "xf")) {
                    var kind: NumberKind = .general;
                    for (element.attributes) |attribute| {
                        if (std.mem.eql(u8, attribute.name.local, "numFmtId")) {
                            const id = std.fmt.parseInt(u32, attribute.value, 10) catch 0;
                            kind = builtinNumberKind(id);
                        }
                    }
                    try kinds.append(arena, kind);
                }
            },
            .element_end => |name| {
                if (std.mem.eql(u8, name.local, "cellXfs")) in_cell_xfs = false;
            },
            else => {},
        }
    }
    return kinds.items;
}

fn builtinNumberKind(id: u32) NumberKind {
    return switch (id) {
        14...22, 45...47 => .date,
        9, 10 => .percent,
        else => .general,
    };
}

// -------------------------------------------------------------- sheets

fn readSheet(
    ctx: *core.ReadContext,
    arena: std.mem.Allocator,
    name: []const u8,
    bytes: []const u8,
    shared: []const []const u8,
    date_styles: []const NumberKind,
    formula_noted: *bool,
) core.ReadError!void {
    // First pass: the column count, from the dimension when declared and
    // from the widest row otherwise.
    var columns: u32 = 0;
    {
        var parser = xml.Parser.init(arena, bytes, ctx.limits.max_xml_depth);
        defer parser.deinit();
        while (true) {
            const event = parser.next() catch break;
            switch (event) {
                .done => break,
                .element_start => |element| {
                    if (element.name.is(main_ns, "c")) {
                        for (element.attributes) |attribute| {
                            if (std.mem.eql(u8, attribute.name.local, "r")) {
                                columns = @max(columns, columnOf(attribute.value) + 1);
                            }
                        }
                    }
                },
                else => {},
            }
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

    var parser = xml.Parser.init(arena, bytes, ctx.limits.max_xml_depth);
    defer parser.deinit();

    var head_token: ?core.builder.BlockToken = null;
    var body_token: ?core.builder.BlockToken = null;
    var row_token: ?core.builder.BlockToken = null;
    var row_index: u32 = 0;
    var cell_column: u32 = 0;
    var emitted_in_row: u32 = 0;

    var in_value = false;
    var in_inline_text = false;
    var in_formula = false;
    var cell_kind: NumberKind = .general;
    var cell_type: enum { number, shared, inline_string, boolean, err } = .number;
    var cell_has_formula = false;
    var value_buffer: std.ArrayList(u8) = .empty;
    defer value_buffer.deinit(arena);
    var formula_buffer: std.ArrayList(u8) = .empty;
    defer formula_buffer.deinit(arena);

    while (true) {
        const event = parser.next() catch {
            // A malformed sheet keeps whatever rows were already emitted.
            break;
        };
        switch (event) {
            .done => break,
            .element_start => |element| {
                if (element.name.is(main_ns, "row")) {
                    if (row_index == 0) {
                        head_token = try ctx.out.beginBlock(.table_head);
                    } else if (row_index == 1) {
                        body_token = try ctx.out.beginTableBody(.{
                            .row_head_columns = 0,
                            .head_rows = 0,
                        });
                    }
                    row_token = try ctx.out.beginBlock(.table_row);
                    emitted_in_row = 0;
                    cell_column = 0;
                    // A self-closing `<row/>` gets no end event; close it
                    // as an empty row here or its token leaks.
                    if (element.self_closing) {
                        while (emitted_in_row < columns) : (emitted_in_row += 1) {
                            try emitCellText(ctx, "");
                        }
                        if (row_token) |token| ctx.out.endBlock(token);
                        row_token = null;
                        if (row_index == 0) {
                            if (head_token) |token| ctx.out.endBlock(token);
                            head_token = null;
                        }
                        row_index += 1;
                    }
                } else if (element.name.is(main_ns, "c")) {
                    cell_kind = .general;
                    cell_type = .number;
                    cell_has_formula = false;
                    value_buffer.clearRetainingCapacity();
                    formula_buffer.clearRetainingCapacity();
                    var declared_column: ?u32 = null;
                    for (element.attributes) |attribute| {
                        if (std.mem.eql(u8, attribute.name.local, "r")) {
                            declared_column = columnOf(attribute.value);
                        } else if (std.mem.eql(u8, attribute.name.local, "t")) {
                            if (std.mem.eql(u8, attribute.value, "s")) {
                                cell_type = .shared;
                            } else if (std.mem.eql(u8, attribute.value, "inlineStr") or
                                std.mem.eql(u8, attribute.value, "str"))
                            {
                                cell_type = .inline_string;
                            } else if (std.mem.eql(u8, attribute.value, "b")) {
                                cell_type = .boolean;
                            } else if (std.mem.eql(u8, attribute.value, "e")) {
                                cell_type = .err;
                            }
                        } else if (std.mem.eql(u8, attribute.name.local, "s")) {
                            const style = std.fmt.parseInt(u32, attribute.value, 10) catch 0;
                            if (style < date_styles.len) cell_kind = date_styles[style];
                        }
                    }
                    // Materialize the gap sparse rows skip over.
                    if (declared_column) |column| {
                        while (emitted_in_row < column and emitted_in_row < 1024) {
                            try emitCellText(ctx, "");
                            emitted_in_row += 1;
                        }
                    }
                    // A self-closing `<c/>` is a real (empty) cell with no
                    // end event; emit it now.
                    if (element.self_closing and row_token != null and emitted_in_row < 1024) {
                        try emitCellText(ctx, "");
                        emitted_in_row += 1;
                    }
                } else if (element.name.is(main_ns, "v")) {
                    in_value = !element.self_closing;
                } else if (element.name.is(main_ns, "t")) {
                    in_inline_text = !element.self_closing;
                } else if (element.name.is(main_ns, "f")) {
                    cell_has_formula = true;
                    in_formula = !element.self_closing;
                }
            },
            .element_end => |end_name| {
                if (std.mem.eql(u8, end_name.local, "row")) {
                    while (emitted_in_row < columns) : (emitted_in_row += 1) {
                        try emitCellText(ctx, "");
                    }
                    if (row_token) |token| ctx.out.endBlock(token);
                    row_token = null;
                    if (row_index == 0) {
                        if (head_token) |token| ctx.out.endBlock(token);
                        head_token = null;
                    }
                    row_index += 1;
                } else if (std.mem.eql(u8, end_name.local, "c")) {
                    if (row_token != null and emitted_in_row < 1024) {
                        const text = try cellText(
                            arena,
                            cell_type,
                            cell_kind,
                            value_buffer.items,
                            shared,
                        );
                        if (cell_has_formula and value_buffer.items.len == 0 and !formula_noted.*) {
                            formula_noted.* = true;
                            try ctx.reports.add(formulaNote());
                        }
                        // A cell with any content or formula carries its
                        // grid facet (ZDS 0013): exact coordinates, the
                        // formula source, and the cached value as spelled.
                        const grid: ?core.facets.GridData = if (value_buffer.items.len > 0 or
                            cell_has_formula)
                            .{
                                .sheet = name,
                                .row = row_index,
                                .col = emitted_in_row,
                                .value_type = gridValueType(
                                    cell_type,
                                    cell_kind,
                                    value_buffer.items,
                                ),
                                .formula = formula_buffer.items,
                                .cached = value_buffer.items,
                            }
                        else
                            null;
                        try emitCell(ctx, text, grid);
                        emitted_in_row += 1;
                    }
                } else if (std.mem.eql(u8, end_name.local, "v")) {
                    in_value = false;
                } else if (std.mem.eql(u8, end_name.local, "t")) {
                    in_inline_text = false;
                } else if (std.mem.eql(u8, end_name.local, "f")) {
                    in_formula = false;
                }
            },
            .text => |value| {
                if (in_value or in_inline_text) try value_buffer.appendSlice(arena, value);
                if (in_formula) try formula_buffer.appendSlice(arena, value);
            },
        }
    }

    if (row_token) |token| ctx.out.endBlock(token);
    if (head_token) |token| ctx.out.endBlock(token);
    if (body_token) |token| ctx.out.endBlock(token);
    ctx.out.endBlock(table);
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

/// The facet's value type (ZDS 0013): what the cell holds, judged from the
/// declared type and the number-format family.
fn gridValueType(
    cell_type: anytype,
    kind: NumberKind,
    raw: []const u8,
) core.facets.ValueType {
    return switch (cell_type) {
        .shared, .inline_string => .text,
        .boolean => .boolean,
        .err => .error_value,
        .number => if (raw.len == 0)
            .empty
        else switch (kind) {
            .date => .date,
            .percent, .general => .number,
        },
    };
}

fn cellText(
    arena: std.mem.Allocator,
    cell_type: anytype,
    kind: NumberKind,
    raw: []const u8,
    shared: []const []const u8,
) core.ReadError![]const u8 {
    switch (cell_type) {
        .shared => {
            const index = std.fmt.parseInt(usize, raw, 10) catch return "";
            if (index >= shared.len) return "";
            return shared[index];
        },
        .inline_string => return raw,
        .boolean => return if (std.mem.eql(u8, raw, "1")) "TRUE" else "FALSE",
        .err => return raw,
        .number => {
            if (raw.len == 0) return "";
            switch (kind) {
                .date => {
                    const serial = std.fmt.parseFloat(f64, raw) catch return raw;
                    return formatSerialDate(arena, serial) catch raw;
                },
                .percent => {
                    const value = std.fmt.parseFloat(f64, raw) catch return raw;
                    return std.fmt.allocPrint(arena, "{d}%", .{value * 100});
                },
                .general => return raw,
            }
        },
    }
}

/// Excel serial dates count days from the 1900 epoch; serial 25569 is
/// 1970-01-01. The conversion is Hinnant's civil-from-days. Serials below
/// 60 inherit Excel's fictional 1900-02-29 and land one day early; dates
/// that old do not appear in real spreadsheets.
fn formatSerialDate(arena: std.mem.Allocator, serial: f64) ![]const u8 {
    if (serial < 1 or serial > 2958465) return error.OutOfRange;
    const days = @as(i64, @intFromFloat(serial)) - 25569;
    const z = days + 719468;
    const era = @divFloor(z, 146097);
    const day_of_era: u64 = @intCast(z - era * 146097);
    const year_of_era = (day_of_era - day_of_era / 1460 +
        day_of_era / 36524 - day_of_era / 146096) / 365;
    const year = @as(i64, @intCast(year_of_era)) + era * 400;
    const day_of_year = day_of_era - (365 * year_of_era + year_of_era / 4 - year_of_era / 100);
    const month_prime = (5 * day_of_year + 2) / 153;
    const day = day_of_year - (153 * month_prime + 2) / 5 + 1;
    const month = if (month_prime < 10) month_prime + 3 else month_prime - 9;
    const civil_year: u32 = @intCast(if (month <= 2) year + 1 else year);
    return std.fmt.allocPrint(arena, "{d:0>4}-{d:0>2}-{d:0>2}", .{ civil_year, month, day });
}

fn columnOf(reference: []const u8) u32 {
    var column: u32 = 0;
    for (reference) |byte| {
        if (byte >= 'A' and byte <= 'Z') {
            column = column * 26 + (byte - 'A' + 1);
        } else break;
    }
    return if (column > 0) column - 1 else 0;
}

// ------------------------------------------------------------- reports

fn archiveReport() core.Report {
    return .{
        .severity = .err,
        .code = "xlsx.not-an-archive",
        .title = "NOT A READABLE XLSX ARCHIVE",
        .problem = "This file is not a ZIP archive zenfmt can read, or it " ++
            "trips an archive safety limit.",
        .consequence = "The conversion stopped and no output file was " ++
            "created.",
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
        .code = "xlsx.missing-workbook",
        .title = "THE WORKBOOK PART IS MISSING",
        .problem = "The archive opens but does not contain a readable " ++
            "xl/workbook.xml, so it is not a spreadsheet.",
        .consequence = "The conversion stopped and no output file was " ++
            "created.",
        .directions = &.{.{
            .title = "Re-export the file",
            .explanation = "Re-save the spreadsheet from its native " ++
                "application and convert the fresh copy.",
        }},
    };
}

fn formulaNote() core.Report {
    return .{
        .severity = .note,
        .code = "xlsx.formula-without-cached-value",
        .title = "FORMULAS WITHOUT CACHED VALUES",
        .problem = "Some cells hold formulas with no cached result, and " ++
            "zenfmt does not evaluate formulas.",
        .consequence = "Those cells are empty in the output.",
        .loss = .dropped,
        .directions = &.{.{
            .title = "Recalculate and re-save",
            .explanation = "Open the spreadsheet, let it recalculate, " ++
                "save, and convert again; the cached values will then be " ++
                "present.",
        }},
    };
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

test "self-closing rows and cells keep the table balanced" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const workbook =
        \\<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"
        \\  xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
        \\<sheets><sheet name="Data" sheetId="1" r:id="rId1"/></sheets>
        \\</workbook>
    ;
    const rels =
        \\<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        \\<Relationship Id="rId1"
        \\  Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet"
        \\  Target="worksheets/sheet1.xml"/>
        \\</Relationships>
    ;
    // Row 1 is entirely self-closing cells; row 2 is a self-closing row —
    // the shapes real producers write for styled-but-empty regions.
    const sheet =
        \\<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
        \\<sheetData>
        \\<row r="1"><c r="A1" s="1"/><c r="B1"><v>7</v></c></row>
        \\<row r="2"/>
        \\<row r="3"><c r="A3"><v>9</v></c></row>
        \\</sheetData>
        \\</worksheet>
    ;
    const bytes = try ooxml.zip.buildStoredArchive(arena, &.{
        .{ .name = "xl/workbook.xml", .data = workbook },
        .{ .name = "xl/_rels/workbook.xml.rels", .data = rels },
        .{ .name = "xl/worksheets/sheet1.xml", .data = sheet },
    });

    const store = try arena.create(core.ast.Store);
    store.* = .{};
    var b = core.builder.Builder.init(arena, store, .{});
    const reports = try arena.create(core.Reports);
    reports.* = core.Reports.init(arena, .{});
    var ctx: core.ReadContext = .{
        .gpa = arena,
        .out = .{ .builder = &b },
        .input = .{ .bytes = bytes },
        .input_name = "grid.xlsx",
        .reports = reports,
        .limits = .{},
    };
    try read(&ctx);
    const doc = try b.finish();
    try core.ast.validate(&doc, .{});

    var rows: u32 = 0;
    var cells: u32 = 0;
    for (doc.store.blocks.items(.tag)) |tag| {
        if (tag == .table_row) rows += 1;
        if (tag == .table_cell) cells += 1;
    }
    try testing.expectEqual(@as(u32, 3), rows);
    try testing.expectEqual(@as(u32, 6), cells);
}

test "grid facets carry coordinates, formula source, and cached values" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const workbook =
        \\<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"
        \\  xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
        \\<sheets><sheet name="Data" sheetId="1" r:id="rId1"/></sheets>
        \\</workbook>
    ;
    const rels =
        \\<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        \\<Relationship Id="rId1"
        \\  Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet"
        \\  Target="worksheets/sheet1.xml"/>
        \\</Relationships>
    ;
    const sheet =
        \\<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
        \\<sheetData>
        \\<row r="1"><c r="A1"><v>2</v></c><c r="B1"><v>4</v></c></row>
        \\<row r="2"><c r="B2"><f>SUM(B1:B1)</f><v>4</v></c></row>
        \\</sheetData>
        \\</worksheet>
    ;
    const bytes = try ooxml.zip.buildStoredArchive(arena, &.{
        .{ .name = "xl/workbook.xml", .data = workbook },
        .{ .name = "xl/_rels/workbook.xml.rels", .data = rels },
        .{ .name = "xl/worksheets/sheet1.xml", .data = sheet },
    });

    const store = try arena.create(core.ast.Store);
    store.* = .{};
    var b = core.builder.Builder.init(arena, store, .{});
    const reports = try arena.create(core.Reports);
    reports.* = core.Reports.init(arena, .{});
    var ctx: core.ReadContext = .{
        .gpa = arena,
        .out = .{ .builder = &b },
        .input = .{ .bytes = bytes },
        .input_name = "grid.xlsx",
        .reports = reports,
        .limits = .{},
    };
    try read(&ctx);
    const doc = try b.finish();
    try core.ast.validate(&doc, .{});

    // Three content cells, three facets; the padded gap in row 2 gets none.
    const rows = store.grid_facets.items;
    try testing.expectEqual(@as(usize, 3), rows.len);
    const formula_row = rows[2];
    try testing.expectEqualStrings("Data", store.textSlice(formula_row.sheet));
    try testing.expectEqual(@as(u32, 1), formula_row.row);
    try testing.expectEqual(@as(u32, 1), formula_row.col);
    try testing.expectEqual(core.facets.ValueType.number, formula_row.value_type);
    try testing.expectEqualStrings("SUM(B1:B1)", store.textSlice(formula_row.formula));
    try testing.expectEqualStrings("4", store.textSlice(formula_row.cached));
    try testing.expectEqual(@as(u16, 1), formula_row.merge_rows);
}

test "column references and serial dates" {
    try testing.expectEqual(@as(u32, 0), columnOf("A1"));
    try testing.expectEqual(@as(u32, 3), columnOf("D7"));
    try testing.expectEqual(@as(u32, 27), columnOf("AB2"));

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expectEqualStrings("2024-01-15", try formatSerialDate(arena, 45306));
    try testing.expectEqualStrings("1970-01-01", try formatSerialDate(arena, 25569));
}
