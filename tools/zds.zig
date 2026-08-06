//! Zen Discussion (ZDS) management tool.
//!
//! Drives the numbering workflow defined in ZDS 0001: placeholder drafts are
//! created from the template as `XXXXX-<slug>.typ`, and promotion assigns the
//! next permanent four-digit number, rewrites the draft's metadata, and adds
//! the registry and bundle entries. `build.zig` discovers numbered records by
//! scanning `docs/zds/records`, so no build file edit is needed.

const std = @import("std");
const Io = std.Io;

const usage_text =
    \\usage: zds-tool --root <repo-root> <command> [arguments]
    \\
    \\Commands:
    \\  list             Show registry entries and placeholder drafts.
    \\  new <slug>       Create docs/zds/records/XXXXX-<slug>.typ from the
    \\                   template with today's date.
    \\  promote <slug>   Assign the next four-digit number to the placeholder
    \\                   draft XXXXX-<slug>.typ, rewrite its metadata for
    \\                   discussion, and append registry.typ and bundle.typ
    \\                   entries.
    \\
    \\Slugs are lowercase words separated by hyphens, as in `docx-reader`.
    \\
;

const records_dir = "docs/zds/records";
const registry_path = "docs/zds/registry.typ";
const bundle_path = "docs/zds/bundle.typ";
const template_path = "docs/zds/template/rfc-template.typ";
const placeholder = "XXXXX";
const authors_literal = "(\"Zen Contributors\",)";
const maximum_file_bytes = 4 * 1024 * 1024;

const exit_ok: u8 = 0;
const exit_error: u8 = 1;
const exit_usage: u8 = 2;

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;

    var stdout_buffer: [16 * 1024]u8 = undefined;
    var stdout_writer = Io.File.stdout().writerStreaming(io, &stdout_buffer);
    const out = &stdout_writer.interface;
    var stderr_buffer: [4096]u8 = undefined;
    var stderr_writer = Io.File.stderr().writerStreaming(io, &stderr_buffer);
    const err_out = &stderr_writer.interface;

    const code = run(gpa, io, init.minimal.args, out, err_out) catch |err| blk: {
        err_out.print("error: {t}\n", .{err}) catch {};
        break :blk exit_error;
    };
    out.flush() catch {};
    err_out.flush() catch {};
    return code;
}

fn run(
    gpa: std.mem.Allocator,
    io: Io,
    args: std.process.Args,
    out: *Io.Writer,
    err_out: *Io.Writer,
) !u8 {
    var iterator = std.process.Args.Iterator.init(args);
    defer iterator.deinit();
    _ = iterator.next();

    var root_path: ?[]const u8 = null;
    var command: ?[]const u8 = null;
    var operand: ?[]const u8 = null;
    while (iterator.next()) |arg| {
        if (std.mem.eql(u8, arg, "--root")) {
            root_path = iterator.next() orelse return usageError(err_out, "--root needs a value");
        } else if (command == null) {
            command = arg;
        } else if (operand == null) {
            operand = arg;
        } else {
            return usageError(err_out, "too many arguments");
        }
    }

    const root = root_path orelse return usageError(err_out, "--root is required");
    const name = command orelse {
        try out.writeAll(usage_text);
        return exit_usage;
    };

    var root_dir = Io.Dir.cwd().openDir(io, root, .{}) catch |err| {
        try err_out.print("error: cannot open repository root {s}: {t}\n", .{ root, err });
        return exit_error;
    };
    defer root_dir.close(io);

    if (std.mem.eql(u8, name, "list")) {
        if (operand != null) return usageError(err_out, "list takes no argument");
        return list(gpa, io, root_dir, out);
    }
    if (std.mem.eql(u8, name, "new")) {
        const slug = operand orelse return usageError(err_out, "new needs a slug");
        return create(gpa, io, root_dir, slug, out, err_out);
    }
    if (std.mem.eql(u8, name, "promote")) {
        const slug = operand orelse return usageError(err_out, "promote needs a slug");
        return promote(gpa, io, root_dir, slug, out, err_out);
    }
    return usageError(err_out, "unknown command; expected list, new, or promote");
}

fn usageError(err_out: *Io.Writer, message: []const u8) !u8 {
    try err_out.print("error: {s}\n\n", .{message});
    try err_out.writeAll(usage_text);
    return exit_usage;
}

// ---------------------------------------------------------------- list

fn list(gpa: std.mem.Allocator, io: Io, root: Io.Dir, out: *Io.Writer) !u8 {
    const registry = try root.readFileAlloc(io, registry_path, gpa, .limited(maximum_file_bytes));
    defer gpa.free(registry);

    try out.writeAll("Registered discussions:\n");
    var registered: std.ArrayList([]const u8) = .empty;
    defer {
        for (registered.items) |entry| gpa.free(entry);
        registered.deinit(gpa);
    }
    var cursor: usize = 0;
    while (fieldAfter(registry, &cursor, "number: \"")) |number| {
        var entry_cursor = cursor;
        const slug = fieldAfter(registry, &entry_cursor, "slug: \"") orelse break;
        const title = fieldAfter(registry, &entry_cursor, "title: \"") orelse break;
        const state = fieldAfter(registry, &entry_cursor, "state: \"") orelse break;
        cursor = entry_cursor;
        try registered.append(gpa, try std.fmt.allocPrint(gpa, "{s}-{s}", .{ number, slug }));
        try out.print("  ZDS {s}  {s:<13}  {s}  ({s})\n", .{ number, state, title, slug });
    }

    var names = try recordFileNames(gpa, io, root);
    defer {
        for (names.items) |file_name| gpa.free(file_name);
        names.deinit(gpa);
    }

    var drafts_seen = false;
    for (names.items) |file_name| {
        const stem = file_name[0 .. file_name.len - ".typ".len];
        if (std.mem.startsWith(u8, stem, placeholder ++ "-")) {
            if (!drafts_seen) {
                try out.writeAll("Placeholder drafts:\n");
                drafts_seen = true;
            }
            try out.print("  {s}  (promote with: zig build zds-promote -- {s})\n", .{
                file_name,
                stem[placeholder.len + 1 ..],
            });
        }
    }

    for (names.items) |file_name| {
        const stem = file_name[0 .. file_name.len - ".typ".len];
        if (std.mem.startsWith(u8, stem, placeholder ++ "-")) continue;
        var known = false;
        for (registered.items) |entry| known = known or std.mem.eql(u8, entry, stem);
        if (!known) try out.print("warning: {s}/{s} has no registry.typ entry\n", .{
            records_dir,
            file_name,
        });
    }
    for (registered.items) |entry| {
        var present = false;
        for (names.items) |file_name| {
            present = present or std.mem.eql(u8, entry, file_name[0 .. file_name.len - ".typ".len]);
        }
        if (!present) try out.print("warning: registry entry {s} has no record file\n", .{entry});
    }
    return exit_ok;
}

// ----------------------------------------------------------------- new

fn create(
    gpa: std.mem.Allocator,
    io: Io,
    root: Io.Dir,
    slug: []const u8,
    out: *Io.Writer,
    err_out: *Io.Writer,
) !u8 {
    if (!validSlug(slug)) return usageError(err_out, "slug must be lowercase words joined by hyphens");

    const draft_path = try std.fmt.allocPrint(
        gpa,
        records_dir ++ "/" ++ placeholder ++ "-{s}.typ",
        .{slug},
    );
    defer gpa.free(draft_path);
    if (fileExists(io, root, draft_path)) {
        try err_out.print("error: {s} already exists\n", .{draft_path});
        return exit_error;
    }

    const template = try root.readFileAlloc(io, template_path, gpa, .limited(maximum_file_bytes));
    defer gpa.free(template);
    const date = try today(io);
    const quoted_date = try std.fmt.allocPrint(gpa, "\"{s}\"", .{&date});
    defer gpa.free(quoted_date);
    const dated = try replaceOnce(gpa, template, "\"YYYY-MM-DD\"", quoted_date);
    defer gpa.free(dated);

    try root.writeFile(io, .{ .sub_path = draft_path, .data = dated });
    try out.print("created {s}\n", .{draft_path});
    try out.print("preview it with: zig build zds -Dzds={s}\n", .{slug});
    try out.print("promote when ready: zig build zds-promote -- {s}\n", .{slug});
    return exit_ok;
}

// ------------------------------------------------------------- promote

fn promote(
    gpa: std.mem.Allocator,
    io: Io,
    root: Io.Dir,
    slug: []const u8,
    out: *Io.Writer,
    err_out: *Io.Writer,
) !u8 {
    if (!validSlug(slug)) return usageError(err_out, "slug must be lowercase words joined by hyphens");

    const draft_path = try std.fmt.allocPrint(
        gpa,
        records_dir ++ "/" ++ placeholder ++ "-{s}.typ",
        .{slug},
    );
    defer gpa.free(draft_path);
    const draft = root.readFileAlloc(io, draft_path, gpa, .limited(maximum_file_bytes)) catch |err| {
        try err_out.print("error: cannot read {s}: {t}\n", .{ draft_path, err });
        return exit_error;
    };
    defer gpa.free(draft);

    var names = try recordFileNames(gpa, io, root);
    defer {
        for (names.items) |file_name| gpa.free(file_name);
        names.deinit(gpa);
    }
    var highest: u16 = 0;
    for (names.items) |file_name| {
        const parsed = std.fmt.parseInt(u16, file_name[0..4], 10) catch continue;
        highest = @max(highest, parsed);
    }
    var number: [4]u8 = undefined;
    _ = try std.fmt.bufPrint(&number, "{d:0>4}", .{highest + 1});

    const date = try today(io);
    var content = try replaceMeta(gpa, draft, "number", &number);
    content = try replaceMetaOwned(gpa, content, "state", "discussion");
    content = try replaceMetaOwned(gpa, content, "status", "Open for Discussion");
    content = try replaceMetaOwned(gpa, content, "last-updated", &date);
    if (std.mem.eql(u8, metaValue(content, "created") orelse "", "YYYY-MM-DD")) {
        content = try replaceMetaOwned(gpa, content, "created", &date);
    }
    defer gpa.free(content);

    const title = metaValue(content, "title") orelse "Untitled";
    const summary = metaValue(content, "discussion") orelse "";
    const created = metaValue(content, "created") orelse &date;
    const area = firstLabel(content) orelse "engineering";
    const category = metaValue(content, "category") orelse "Engineering Discussion";

    const record_path = try std.fmt.allocPrint(
        gpa,
        records_dir ++ "/{s}-{s}.typ",
        .{ number, slug },
    );
    defer gpa.free(record_path);
    if (fileExists(io, root, record_path)) {
        try err_out.print("error: {s} already exists\n", .{record_path});
        return exit_error;
    }

    const registry_entry = try std.fmt.allocPrint(gpa,
        \\  (
        \\    number: "{s}",
        \\    slug: "{s}",
        \\    title: "{s}",
        \\    state: "discussion",
        \\    area: "{s}",
        \\    category: "{s}",
        \\    status: "Open for Discussion",
        \\    created: "{s}",
        \\    updated: "{s}",
        \\    summary: "{s}",
        \\    source: "docs/zds/records/{s}-{s}.typ",
        \\    html: "zds/{s}-{s}.html",
        \\    pdf: "pdf/zds-{s}-{s}.pdf",
        \\  ),
        \\
    , .{
        &number, slug,    title, area,    category, created, &date,
        summary, &number, slug,  &number, slug,     &number, slug,
    });
    defer gpa.free(registry_entry);

    const registry = try root.readFileAlloc(io, registry_path, gpa, .limited(maximum_file_bytes));
    defer gpa.free(registry);
    const close_at = std.mem.lastIndexOf(u8, registry, "\n)") orelse {
        try err_out.print("error: {s} has no closing parenthesis\n", .{registry_path});
        return exit_error;
    };
    const updated_registry = try std.mem.concat(gpa, u8, &.{
        registry[0 .. close_at + 1],
        registry_entry,
        registry[close_at + 1 ..],
    });
    defer gpa.free(updated_registry);

    const bundle_entry = try std.fmt.allocPrint(gpa,
        \\
        \\#document(
        \\  "zds/{s}-{s}.html",
        \\  title: [ZDS {s}: {s}],
        \\  author: {s},
        \\  description: [{s}],
        \\)[
        \\  #include "records/{s}-{s}.typ"
        \\]
        \\
        \\#document("pdf/zds-{s}-{s}.pdf")[
        \\  #include "records/{s}-{s}.typ"
        \\]
        \\
    , .{
        &number, slug,    &number, title,   authors_literal,
        summary, &number, slug,    &number, slug,
        &number, slug,
    });
    defer gpa.free(bundle_entry);

    const bundle = try root.readFileAlloc(io, bundle_path, gpa, .limited(maximum_file_bytes));
    defer gpa.free(bundle);
    const updated_bundle = try std.mem.concat(gpa, u8, &.{ bundle, bundle_entry });
    defer gpa.free(updated_bundle);

    // All reads and formatting succeeded; apply the writes.
    try root.writeFile(io, .{ .sub_path = record_path, .data = content });
    try root.deleteFile(io, draft_path);
    try root.writeFile(io, .{ .sub_path = registry_path, .data = updated_registry });
    try root.writeFile(io, .{ .sub_path = bundle_path, .data = updated_bundle });

    try out.print("promoted {s} -> {s}\n", .{ draft_path, record_path });
    try out.print("updated {s} and {s}\n", .{ registry_path, bundle_path });
    try out.print("build it with: zig build zds -Dzds={s}\n", .{number});
    try out.writeAll("review the registry summary and area fields before committing.\n");
    return exit_ok;
}

// ------------------------------------------------------------- helpers

fn recordFileNames(
    gpa: std.mem.Allocator,
    io: Io,
    root: Io.Dir,
) !std.ArrayList([]const u8) {
    var names: std.ArrayList([]const u8) = .empty;
    errdefer names.deinit(gpa);
    var dir = try root.openDir(io, records_dir, .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".typ")) continue;
        if (entry.name.len < "0000-a.typ".len) continue;
        try names.append(gpa, try gpa.dupe(u8, entry.name));
    }
    std.mem.sort([]const u8, names.items, {}, stringLessThan);
    return names;
}

fn stringLessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

fn fileExists(io: Io, root: Io.Dir, sub_path: []const u8) bool {
    root.access(io, sub_path, .{}) catch return false;
    return true;
}

fn validSlug(slug: []const u8) bool {
    if (slug.len == 0 or slug[0] == '-' or slug[slug.len - 1] == '-') return false;
    for (slug) |byte| {
        const ok = std.ascii.isLower(byte) or std.ascii.isDigit(byte) or byte == '-';
        if (!ok) return false;
    }
    return std.mem.indexOf(u8, slug, "--") == null;
}

/// Returns the value of `#let zds-<key> = "<value>"`, or null.
fn metaValue(source: []const u8, comptime key: []const u8) ?[]const u8 {
    const prefix = "#let zds-" ++ key ++ " = \"";
    const start = (std.mem.indexOf(u8, source, prefix) orelse return null) + prefix.len;
    const end = std.mem.indexOfScalarPos(u8, source, start, '"') orelse return null;
    return source[start..end];
}

/// Returns the first entry of `#let zds-labels = ("a", ...)`, or null.
fn firstLabel(source: []const u8) ?[]const u8 {
    const prefix = "#let zds-labels = (\"";
    const start = (std.mem.indexOf(u8, source, prefix) orelse return null) + prefix.len;
    const end = std.mem.indexOfScalarPos(u8, source, start, '"') orelse return null;
    return source[start..end];
}

fn replaceMeta(
    gpa: std.mem.Allocator,
    source: []const u8,
    comptime key: []const u8,
    value: []const u8,
) ![]u8 {
    const old = metaValue(source, key) orelse return error.MissingMetadata;
    const value_start = @intFromPtr(old.ptr) - @intFromPtr(source.ptr);
    return std.mem.concat(gpa, u8, &.{
        source[0..value_start],
        value,
        source[value_start + old.len ..],
    });
}

fn replaceMetaOwned(
    gpa: std.mem.Allocator,
    source: []u8,
    comptime key: []const u8,
    value: []const u8,
) ![]u8 {
    defer gpa.free(source);
    return replaceMeta(gpa, source, key, value);
}

fn replaceOnce(
    gpa: std.mem.Allocator,
    source: []const u8,
    needle: []const u8,
    replacement: []const u8,
) ![]u8 {
    const at = std.mem.indexOf(u8, source, needle) orelse return error.MissingMetadata;
    return std.mem.concat(gpa, u8, &.{
        source[0..at],
        replacement,
        source[at + needle.len ..],
    });
}

fn fieldAfter(
    source: []const u8,
    cursor: *usize,
    comptime prefix: []const u8,
) ?[]const u8 {
    const start = (std.mem.indexOfPos(u8, source, cursor.*, prefix) orelse return null) +
        prefix.len;
    const end = std.mem.indexOfScalarPos(u8, source, start, '"') orelse return null;
    cursor.* = end + 1;
    return source[start..end];
}

/// Today's UTC date as `YYYY-MM-DD`.
fn today(io: Io) ![10]u8 {
    const timestamp = Io.Clock.real.now(io);
    const seconds: u64 = @intCast(@divTrunc(timestamp.nanoseconds, std.time.ns_per_s));
    const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = seconds };
    const year_day = epoch_seconds.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    var date: [10]u8 = undefined;
    _ = try std.fmt.bufPrint(&date, "{d:0>4}-{d:0>2}-{d:0>2}", .{
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
    });
    return date;
}

// --------------------------------------------------------------- tests

const testing = std.testing;

test "validSlug accepts lowercase hyphenated words" {
    try testing.expect(validSlug("docx-reader"));
    try testing.expect(validSlug("ir"));
    try testing.expect(validSlug("zds-0002-followup"));
}

test "validSlug rejects malformed slugs" {
    try testing.expect(!validSlug(""));
    try testing.expect(!validSlug("-leading"));
    try testing.expect(!validSlug("trailing-"));
    try testing.expect(!validSlug("double--hyphen"));
    try testing.expect(!validSlug("Upper"));
    try testing.expect(!validSlug("with space"));
    try testing.expect(!validSlug("under_score"));
}

test "metaValue reads the zds metadata header" {
    const source =
        \\#let zds-number = "0002"
        \\#let zds-title = "zenfmt: Architecture and Implementation"
        \\#let zds-state = "discussion"
        \\
    ;
    try testing.expectEqualStrings("0002", metaValue(source, "number").?);
    try testing.expectEqualStrings(
        "zenfmt: Architecture and Implementation",
        metaValue(source, "title").?,
    );
    try testing.expect(metaValue(source, "absent") == null);
}

test "firstLabel reads the first label as the registry area" {
    const source = "#let zds-labels = (\"architecture\", \"ir\",)\n";
    try testing.expectEqualStrings("architecture", firstLabel(source).?);
    try testing.expect(firstLabel("#let zds-title = \"x\"\n") == null);
}

test "replaceMeta rewrites one value in place" {
    const source =
        \\#let zds-number = "XXXXX"
        \\#let zds-state = "prediscussion"
        \\
    ;
    const updated = try replaceMeta(testing.allocator, source, "number", "0003");
    defer testing.allocator.free(updated);
    try testing.expectEqualStrings("0003", metaValue(updated, "number").?);
    try testing.expectEqualStrings("prediscussion", metaValue(updated, "state").?);
}

test "fieldAfter walks successive registry fields" {
    const registry =
        \\  (
        \\    number: "0001",
        \\    slug: "zds-process",
        \\  ),
        \\
    ;
    var cursor: usize = 0;
    try testing.expectEqualStrings("0001", fieldAfter(registry, &cursor, "number: \"").?);
    try testing.expectEqualStrings("zds-process", fieldAfter(registry, &cursor, "slug: \"").?);
    try testing.expect(fieldAfter(registry, &cursor, "number: \"") == null);
}
