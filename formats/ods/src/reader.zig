//! The ODS reader (anydoc-parity delivery): each sheet becomes a heading
//! naming it, followed by a table, mirroring the XLSX conventions. Cell
//! values come from the typed `office:*` attributes — an ODS date is
//! already ISO 8601 text, so no serial-date arithmetic is needed —
//! falling back to the displayed `text:p` content. Repeated rows and
//! columns are materialized under hard caps so a filler run to column
//! 16384 cannot amplify the input.

const std = @import("std");
const assert = std.debug.assert;
const core = @import("zenfmt_core");
const xml = @import("zenfmt_xml");
const ooxml = @import("zenfmt_ooxml");

pub const reader = core.Reader(.{
    .id = "ai.insan.zenfmt.ods",
    .format = "ods",
    .extensions = &.{"ods"},
    .input = .seekable,
    .data_version = 1,
    .read = read,
});

const office_ns = "urn:oasis:names:tc:opendocument:xmlns:office:1.0";
const table_ns = "urn:oasis:names:tc:opendocument:xmlns:table:1.0";
const text_ns = "urn:oasis:names:tc:opendocument:xmlns:text:1.0";

/// Materialization caps: repeats beyond these are filler, not data.
const max_cells_per_row = 1024;
const max_row_repeat = 1024;
const max_rows_per_sheet = 65536;

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

    var machine: Machine = .{ .ctx = ctx, .arena = arena };
    var parser = xml.Parser.init(arena, content_bytes, ctx.limits.max_xml_depth);
    defer parser.deinit();
    machine.parser = &parser;
    try machine.run();
}

// -------------------------------------------------------------- machine

const Cell = struct {
    text: []const u8,
    has_formula: bool = false,
    /// Grid facet fields (ZDS 0013), carried from parse to emission.
    formula: []const u8 = "",
    value_type: core.facets.ValueType = .empty,
    cached: []const u8 = "",
    merge_rows: u16 = 1,
    merge_cols: u16 = 1,
};

const Machine = struct {
    ctx: *core.ReadContext,
    arena: std.mem.Allocator,
    parser: *xml.Parser = undefined,

    in_spreadsheet: bool = false,
    sheet_name: []const u8 = "Sheet",
    rows: std.ArrayList([]const Cell) = .empty,
    row: std.ArrayList(Cell) = .empty,
    row_repeat: u32 = 1,

    in_cell: bool = false,
    cell_repeat: u32 = 1,
    cell_value_type: []const u8 = "",
    cell_value: []const u8 = "",
    cell_date: []const u8 = "",
    cell_time: []const u8 = "",
    cell_boolean: []const u8 = "",
    cell_has_formula: bool = false,
    cell_formula: []const u8 = "",
    cell_merge_rows: u16 = 1,
    cell_merge_cols: u16 = 1,
    text_buffer: std.ArrayList(u8) = .empty,

    formula_noted: bool = false,

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
                .element_start => |element| try m.onElementStart(element),
                .element_end => |name| try m.onElementEnd(name),
                .text => |bytes| {
                    if (m.in_cell) try m.text_buffer.appendSlice(m.arena, bytes);
                },
            }
        }
    }

    fn onElementStart(m: *Machine, element: xml.ElementStart) core.ReadError!void {
        const name = element.name;
        if (name.is(office_ns, "spreadsheet")) {
            m.in_spreadsheet = true;
            return;
        }
        if (!m.in_spreadsheet) {
            // Styles, metadata, scripts: nothing in them is sheet data.
            return;
        }
        if (name.is(table_ns, "table")) {
            m.sheet_name = "Sheet";
            for (element.attributes) |attribute| {
                if (attribute.name.is(table_ns, "name")) {
                    m.sheet_name = try m.arena.dupe(u8, attribute.value);
                }
            }
            m.rows.clearRetainingCapacity();
            return;
        }
        if (name.is(table_ns, "table-row")) {
            m.row.clearRetainingCapacity();
            m.row_repeat = 1;
            for (element.attributes) |attribute| {
                if (attribute.name.is(table_ns, "number-rows-repeated")) {
                    const count = std.fmt.parseInt(u32, attribute.value, 10) catch 1;
                    m.row_repeat = @min(count, max_row_repeat);
                }
            }
            return;
        }
        if (name.is(table_ns, "covered-table-cell")) {
            // Merged continuations fold into their originating cell.
            if (!element.self_closing) {
                m.parser.skipElement() catch return error.Malformed;
            }
            return;
        }
        if (name.is(table_ns, "table-cell")) {
            return m.onCellStart(element);
        }
        if (name.is(office_ns, "annotation")) {
            try m.ctx.reports.add(annotationReport());
            if (!element.self_closing) {
                m.parser.skipElement() catch return error.Malformed;
            }
            return;
        }
        if (m.in_cell) {
            if (name.is(text_ns, "p")) {
                if (m.text_buffer.items.len > 0) {
                    try m.text_buffer.append(m.arena, ' ');
                }
            } else if (name.is(text_ns, "s") or name.is(text_ns, "tab")) {
                try m.text_buffer.append(m.arena, ' ');
            }
        }
    }

    fn onCellStart(m: *Machine, element: xml.ElementStart) core.ReadError!void {
        m.cell_repeat = 1;
        m.cell_value_type = "";
        m.cell_value = "";
        m.cell_date = "";
        m.cell_time = "";
        m.cell_boolean = "";
        m.cell_has_formula = false;
        m.cell_formula = "";
        m.cell_merge_rows = 1;
        m.cell_merge_cols = 1;
        m.text_buffer.clearRetainingCapacity();
        for (element.attributes) |attribute| {
            const a = attribute.name;
            if (a.is(table_ns, "number-columns-repeated")) {
                const count = std.fmt.parseInt(u32, attribute.value, 10) catch 1;
                m.cell_repeat = @min(count, max_cells_per_row);
            } else if (a.is(office_ns, "value-type")) {
                m.cell_value_type = try m.arena.dupe(u8, attribute.value);
            } else if (a.is(office_ns, "value")) {
                m.cell_value = try m.arena.dupe(u8, attribute.value);
            } else if (a.is(office_ns, "date-value")) {
                m.cell_date = try m.arena.dupe(u8, attribute.value);
            } else if (a.is(office_ns, "time-value")) {
                m.cell_time = try m.arena.dupe(u8, attribute.value);
            } else if (a.is(office_ns, "boolean-value")) {
                m.cell_boolean = try m.arena.dupe(u8, attribute.value);
            } else if (a.is(table_ns, "formula")) {
                m.cell_has_formula = true;
                m.cell_formula = try m.arena.dupe(u8, attribute.value);
            } else if (a.is(table_ns, "number-rows-spanned")) {
                const count = std.fmt.parseInt(u16, attribute.value, 10) catch 1;
                m.cell_merge_rows = @max(count, 1);
            } else if (a.is(table_ns, "number-columns-spanned")) {
                const count = std.fmt.parseInt(u16, attribute.value, 10) catch 1;
                m.cell_merge_cols = @max(count, 1);
            }
        }
        if (element.self_closing) {
            try m.finishCell();
        } else {
            m.in_cell = true;
        }
    }

    fn onElementEnd(m: *Machine, name: xml.Name) core.ReadError!void {
        if (!m.in_spreadsheet) return;
        const local = name.local;
        if (m.in_cell and std.mem.eql(u8, local, "table-cell")) {
            m.in_cell = false;
            try m.finishCell();
            return;
        }
        if (std.mem.eql(u8, local, "table-row")) {
            return m.finishRow();
        }
        if (std.mem.eql(u8, local, "table")) {
            return m.emitSheet();
        }
        if (std.mem.eql(u8, local, "spreadsheet")) {
            m.in_spreadsheet = false;
        }
    }

    fn finishCell(m: *Machine) core.ReadError!void {
        const text = try m.resolveCellText();
        if (m.cell_has_formula and text.len == 0 and !m.formula_noted) {
            m.formula_noted = true;
            try m.ctx.reports.add(formulaNote());
        }
        const cell: Cell = .{
            .text = text,
            .has_formula = m.cell_has_formula,
            .formula = m.cell_formula,
            .value_type = gridValueType(m.cell_value_type, text),
            .cached = m.cachedSpelling(text),
            .merge_rows = m.cell_merge_rows,
            .merge_cols = m.cell_merge_cols,
        };
        var i: u32 = 0;
        while (i < m.cell_repeat and m.row.items.len < max_cells_per_row) : (i += 1) {
            try m.row.append(m.arena, cell);
        }
    }

    /// The cached value exactly as the source spelled it: the typed
    /// attribute when present, the displayed text otherwise.
    fn cachedSpelling(m: *Machine, text: []const u8) []const u8 {
        if (m.cell_value.len > 0) return m.cell_value;
        if (m.cell_date.len > 0) return m.cell_date;
        if (m.cell_time.len > 0) return m.cell_time;
        if (m.cell_boolean.len > 0) return m.cell_boolean;
        return text;
    }

    /// Typed attributes are canonical and deterministic; the displayed
    /// text is the fallback for strings, times, and currencies.
    fn resolveCellText(m: *Machine) core.ReadError![]const u8 {
        const kind = m.cell_value_type;
        const displayed = std.mem.trim(u8, m.text_buffer.items, " ");
        if (std.mem.eql(u8, kind, "float")) {
            if (m.cell_value.len > 0) return m.cell_value;
        } else if (std.mem.eql(u8, kind, "percentage")) {
            if (std.fmt.parseFloat(f64, m.cell_value)) |value| {
                return std.fmt.allocPrint(m.arena, "{d}%", .{value * 100});
            } else |_| {}
        } else if (std.mem.eql(u8, kind, "date")) {
            if (m.cell_date.len >= 10) {
                const cut = std.mem.indexOfScalar(u8, m.cell_date, 'T') orelse m.cell_date.len;
                return m.cell_date[0..cut];
            }
        } else if (std.mem.eql(u8, kind, "time")) {
            if (formatDuration(m.arena, m.cell_time)) |formatted| return formatted else |_| {}
        } else if (std.mem.eql(u8, kind, "boolean")) {
            if (m.cell_boolean.len > 0) {
                return if (std.mem.eql(u8, m.cell_boolean, "true")) "TRUE" else "FALSE";
            }
        }
        if (displayed.len > 0) return try m.arena.dupe(u8, displayed);
        if (m.cell_value.len > 0) return m.cell_value;
        return "";
    }

    fn finishRow(m: *Machine) core.ReadError!void {
        // Trailing empty cells are grid filler, not data.
        var len = m.row.items.len;
        while (len > 0 and m.row.items[len - 1].text.len == 0) len -= 1;
        const cells = try m.arena.dupe(Cell, m.row.items[0..len]);
        var i: u32 = 0;
        while (i < m.row_repeat and m.rows.items.len < max_rows_per_sheet) : (i += 1) {
            try m.rows.append(m.arena, cells);
        }
    }

    fn emitSheet(m: *Machine) core.ReadError!void {
        // Trailing empty rows are grid filler too.
        var row_count = m.rows.items.len;
        while (row_count > 0 and m.rows.items[row_count - 1].len == 0) row_count -= 1;
        var columns: usize = 0;
        for (m.rows.items[0..row_count]) |cells| columns = @max(columns, cells.len);
        if (row_count == 0 or columns == 0) return;
        assert(columns <= max_cells_per_row);

        const ctx = m.ctx;
        const heading = try ctx.out.beginHeading(2);
        try ctx.out.text(m.sheet_name);
        ctx.out.endBlock(heading);

        var alignments: std.ArrayList(core.payload.Alignment) = .empty;
        defer alignments.deinit(m.arena);
        try alignments.appendNTimes(m.arena, .default, columns);
        const table = try ctx.out.beginTable(alignments.items);

        var head_token: ?core.builder.BlockToken = null;
        var body_token: ?core.builder.BlockToken = null;
        for (m.rows.items[0..row_count], 0..) |cells, row_index| {
            if (row_index == 0) {
                head_token = try ctx.out.beginBlock(.table_head);
            } else if (row_index == 1) {
                if (head_token) |token| {
                    ctx.out.endBlock(token);
                    head_token = null;
                }
                body_token = try ctx.out.beginTableBody(.{ .row_head_columns = 0, .head_rows = 0 });
            }
            const row_token = try ctx.out.beginBlock(.table_row);
            var column: usize = 0;
            while (column < columns) : (column += 1) {
                const text = if (column < cells.len) cells[column].text else "";
                const cell = try ctx.out.beginTableCell(.plain);
                if (column < cells.len and
                    (cells[column].text.len > 0 or cells[column].has_formula))
                {
                    const data = cells[column];
                    try ctx.out.attachGrid(cell, .{
                        .sheet = m.sheet_name,
                        .row = @intCast(row_index),
                        .col = @intCast(column),
                        .value_type = data.value_type,
                        .formula = data.formula,
                        .cached = data.cached,
                        .merge_rows = data.merge_rows,
                        .merge_cols = data.merge_cols,
                    });
                }
                const plain = try ctx.out.beginPlain();
                if (text.len > 0) try ctx.out.text(text);
                ctx.out.endBlock(plain);
                ctx.out.endBlock(cell);
            }
            ctx.out.endBlock(row_token);
        }
        if (head_token) |token| ctx.out.endBlock(token);
        if (body_token) |token| ctx.out.endBlock(token);
        ctx.out.endBlock(table);
    }
};

/// The facet's value type (ZDS 0013) from ODF's `office:value-type`.
fn gridValueType(kind: []const u8, text: []const u8) core.facets.ValueType {
    if (std.mem.eql(u8, kind, "float") or
        std.mem.eql(u8, kind, "percentage") or
        std.mem.eql(u8, kind, "currency"))
    {
        return .number;
    }
    if (std.mem.eql(u8, kind, "date") or std.mem.eql(u8, kind, "time")) return .date;
    if (std.mem.eql(u8, kind, "boolean")) return .boolean;
    if (text.len == 0) return .empty;
    return .text;
}

/// `PT13H30M5S` becomes `13:30:05`; anything else is left to the caller.
fn formatDuration(arena: std.mem.Allocator, value: []const u8) ![]const u8 {
    if (!std.mem.startsWith(u8, value, "PT")) return error.Unrecognized;
    var hours: u32 = 0;
    var minutes: u32 = 0;
    var seconds: u32 = 0;
    var number: u32 = 0;
    var seen_digit = false;
    for (value["PT".len..]) |byte| {
        switch (byte) {
            '0'...'9' => {
                number = number *| 10 +| (byte - '0');
                seen_digit = true;
            },
            'H' => hours = number,
            'M' => minutes = number,
            'S' => seconds = number,
            '.' => {},
            else => return error.Unrecognized,
        }
        if (byte == 'H' or byte == 'M' or byte == 'S') number = 0;
    }
    if (!seen_digit) return error.Unrecognized;
    return std.fmt.allocPrint(arena, "{d:0>2}:{d:0>2}:{d:0>2}", .{ hours, minutes, seconds });
}

// ------------------------------------------------------------- reports

fn archiveReport() core.Report {
    return .{
        .severity = .err,
        .code = "ods.not-an-archive",
        .title = "NOT A READABLE ODS ARCHIVE",
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
        .code = "ods.missing-content",
        .title = "THE CONTENT PART IS MISSING",
        .problem = "The archive opens but contains no content.xml, so it " ++
            "is not an OpenDocument spreadsheet.",
        .consequence = "The conversion stopped and no output file was " ++
            "created.",
        .directions = &.{.{
            .title = "Re-export the file",
            .explanation = "Re-save the spreadsheet from LibreOffice or " ++
                "its producing application and convert the fresh copy.",
        }},
    };
}

fn malformedReport() core.Report {
    return .{
        .severity = .err,
        .code = "ods.malformed-xml",
        .title = "MALFORMED XML INSIDE THE SPREADSHEET",
        .problem = "A part inside this spreadsheet is not well-formed " ++
            "XML, or nests beyond the safety limit.",
        .consequence = "The conversion stopped and no output file was " ++
            "created.",
        .directions = &.{.{
            .title = "Re-export the file",
            .explanation = "Open the spreadsheet in LibreOffice; if it " ++
                "opens, re-save it and convert the fresh copy.",
        }},
    };
}

fn annotationReport() core.Report {
    return .{
        .severity = .warning,
        .code = "ods.annotations-dropped",
        .title = "ANNOTATIONS DROPPED",
        .problem = "This spreadsheet contains annotations (comments), and " ++
            "comments have no place in the shared document tree.",
        .consequence = "The annotations are absent from the output.",
        .loss = .dropped,
        .directions = &.{.{
            .title = "Keep the source",
            .explanation = "Keep the source ODS if the annotations " ++
                "matter; they exist only there.",
        }},
    };
}

fn formulaNote() core.Report {
    return .{
        .severity = .note,
        .code = "ods.formula-without-cached-value",
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
const zip = ooxml.zip;

fn convertOds(arena: std.mem.Allocator, content: []const u8) !ConvertResult {
    const archive_bytes = try zip.buildStoredArchive(arena, &.{
        .{ .name = "mimetype", .data = "application/vnd.oasis.opendocument.spreadsheet" },
        .{ .name = "content.xml", .data = content },
    });
    const store = try arena.create(core.ast.Store);
    store.* = .{};
    var b = core.builder.Builder.init(arena, store, .{});
    const reports = try arena.create(core.Reports);
    reports.* = core.Reports.init(arena, .{});
    var ctx: core.ReadContext = .{
        .gpa = arena,
        .out = .{ .builder = &b },
        .input = .{ .bytes = archive_bytes },
        .input_name = "test.ods",
        .reports = reports,
        .limits = .{},
    };
    try read(&ctx);
    const doc = try b.finish();
    try core.ast.validate(&doc, .{});
    return .{ .doc = doc, .reports = reports };
}

const ConvertResult = struct {
    doc: core.ast.Document,
    reports: *core.Reports,
};

const content_prefix =
    \\<office:document-content
    \\  xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0"
    \\  xmlns:table="urn:oasis:names:tc:opendocument:xmlns:table:1.0"
    \\  xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0">
    \\<office:body><office:spreadsheet>
;
const content_suffix = "</office:spreadsheet></office:body></office:document-content>";

fn allText(arena: std.mem.Allocator, doc: *const core.ast.Document) ![]const u8 {
    var buffer: std.ArrayList(u8) = .empty;
    const tags = doc.store.inlines.items(.tag);
    for (tags, 0..) |tag, i| {
        if (tag != .text) continue;
        const view = doc.inlineView(@enumFromInt(i));
        try buffer.appendSlice(arena, doc.text(view.content.text));
        try buffer.append(arena, '|');
    }
    return buffer.items;
}

test "typed cells resolve through office attributes" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const result = try convertOds(arena, content_prefix ++
        \\<table:table table:name="Data">
        \\<table:table-row>
        \\<table:table-cell office:value-type="string"><text:p>Label</text:p></table:table-cell>
        \\<table:table-cell office:value-type="string"><text:p>Value</text:p></table:table-cell>
        \\</table:table-row>
        \\<table:table-row>
        \\<table:table-cell office:value-type="float" office:value="12.5"/>
        \\<table:table-cell office:value-type="percentage" office:value="0.25"/>
        \\</table:table-row>
        \\<table:table-row>
        \\<table:table-cell office:value-type="date" office:date-value="2024-01-15T00:00:00"/>
        \\<table:table-cell office:value-type="boolean" office:boolean-value="true"/>
        \\</table:table-row>
        \\</table:table>
    ++ content_suffix);

    const text = try allText(arena, &result.doc);
    try testing.expectEqualStrings(
        "Data|Label|Value|12.5|25%|2024-01-15|TRUE|",
        text,
    );

    var heads: u32 = 0;
    var rows: u32 = 0;
    for (result.doc.store.blocks.items(.tag)) |tag| switch (tag) {
        .table_head => heads += 1,
        .table_row => rows += 1,
        else => {},
    };
    try testing.expectEqual(@as(u32, 1), heads);
    try testing.expectEqual(@as(u32, 3), rows);
}

test "grid facets carry coordinates, formulas, and merges" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const result = try convertOds(arena, content_prefix ++
        \\<table:table table:name="Calc">
        \\<table:table-row>
        \\<table:table-cell office:value-type="float" office:value="2"/>
        \\<table:table-cell table:number-columns-spanned="2"
        \\  office:value-type="string"><text:p>wide</text:p></table:table-cell>
        \\<table:covered-table-cell/>
        \\</table:table-row>
        \\<table:table-row>
        \\<table:table-cell table:formula="of:=SUM([.A1])"
        \\  office:value-type="float" office:value="2"/>
        \\</table:table-row>
        \\</table:table>
    ++ content_suffix);
    try core.ast.validate(&result.doc, .{});

    const store = result.doc.store;
    const rows = store.grid_facets.items;
    try testing.expectEqual(@as(usize, 3), rows.len);
    try testing.expectEqualStrings("Calc", store.textSlice(rows[0].sheet));
    try testing.expectEqual(core.facets.ValueType.number, rows[0].value_type);
    try testing.expectEqualStrings("2", store.textSlice(rows[0].cached));
    try testing.expectEqual(@as(u16, 2), rows[1].merge_cols);
    try testing.expectEqual(core.facets.ValueType.text, rows[1].value_type);
    const formula_row = rows[2];
    try testing.expectEqual(@as(u32, 1), formula_row.row);
    try testing.expectEqual(@as(u32, 0), formula_row.col);
    try testing.expectEqualStrings("of:=SUM([.A1])", store.textSlice(formula_row.formula));
}

test "repeated filler cells and rows stay bounded" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const result = try convertOds(arena, content_prefix ++
        \\<table:table table:name="Sparse">
        \\<table:table-row>
        \\<table:table-cell office:value-type="string"><text:p>A</text:p></table:table-cell>
        \\<table:table-cell table:number-columns-repeated="16384"/>
        \\</table:table-row>
        \\<table:table-row table:number-rows-repeated="1048576"/>
        \\</table:table>
    ++ content_suffix);

    var cells: u32 = 0;
    var rows: u32 = 0;
    for (result.doc.store.blocks.items(.tag)) |tag| switch (tag) {
        .table_cell => cells += 1,
        .table_row => rows += 1,
        else => {},
    };
    // The filler run and the repeated empty rows both collapse.
    try testing.expectEqual(@as(u32, 1), rows);
    try testing.expectEqual(@as(u32, 1), cells);
}

test "covered cells fold and annotations report" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const result = try convertOds(arena, content_prefix ++
        \\<table:table table:name="Merged">
        \\<table:table-row>
        \\<table:table-cell table:number-columns-spanned="2" office:value-type="string">
        \\<office:annotation><text:p>a comment</text:p></office:annotation>
        \\<text:p>Wide</text:p></table:table-cell>
        \\<table:covered-table-cell/>
        \\</table:table-row>
        \\<table:table-row>
        \\<table:table-cell office:value-type="string"><text:p>x</text:p></table:table-cell>
        \\<table:table-cell office:value-type="string"><text:p>y</text:p></table:table-cell>
        \\</table:table-row>
        \\</table:table>
    ++ content_suffix);

    const text = try allText(arena, &result.doc);
    try testing.expectEqualStrings("Merged|Wide|x|y|", text);

    var found = false;
    for (try result.reports.finalize()) |report| {
        if (std.mem.eql(u8, report.code, "ods.annotations-dropped")) found = true;
    }
    try testing.expect(found);
}

test "formula without cached value notes once" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const result = try convertOds(arena, content_prefix ++
        \\<table:table table:name="Calc">
        \\<table:table-row>
        \\<table:table-cell table:formula="of:=SUM(A1:A9)"/>
        \\<table:table-cell table:formula="of:=1+1" office:value-type="float" office:value="2"/>
        \\</table:table-row>
        \\</table:table>
    ++ content_suffix);

    const text = try allText(arena, &result.doc);
    try testing.expectEqualStrings("Calc|2|", text);

    var found = false;
    for (try result.reports.finalize()) |report| {
        if (std.mem.eql(u8, report.code, "ods.formula-without-cached-value")) found = true;
    }
    try testing.expect(found);
}
