//! Typst documentation builds: ZDS record PDFs, the ZDS index, the HTML
//! bundle, and the book (ZDS 0001, ZDS 0015).
//!
//! Every Typst invocation goes through `compile` so the determinism flags
//! cannot be forgotten on one of them. Reproducibility is not incidental
//! here: Typst's HTML figure export embeds glyph outlines, so an installed
//! font that differs between two machines changes the generated HTML
//! byte-for-byte, not only the PDF. The build therefore ignores system fonts
//! and fixes the creation timestamp.
//!
//! Packages are left to the Typst CLI, which resolves and caches them itself.
//! The `@preview/...` imports name exact versions, so what a build resolves is
//! pinned by the source rather than by this file, and vendoring the sources
//! would mean carrying third-party licences inside an MIT repository for no
//! additional pinning.

const std = @import("std");

/// Fallback creation timestamp: 2026-08-09T00:00:00Z, the 0.2.0 release date.
/// CI passes the tag commit's timestamp through `-Dsource-date-epoch` so a
/// release's documents carry the revision's date rather than this constant.
const release_epoch_default = "1786233600";

pub const Options = struct {
    source_date_epoch: []const u8,
    /// Build only the record matching this number or slug.
    record_filter: ?[]const u8,
};

pub fn options(b: *std.Build) Options {
    const epoch = b.option(
        []const u8,
        "source-date-epoch",
        "Unix timestamp recorded as every generated document's creation date",
    ) orelse release_epoch_default;
    for (epoch) |byte| {
        if (!std.ascii.isDigit(byte)) {
            std.debug.panic(
                "-Dsource-date-epoch must be a Unix timestamp, got '{s}'",
                .{epoch},
            );
        }
    }
    return .{
        .source_date_epoch = epoch,
        .record_filter = b.option(
            []const u8,
            "zds",
            "Build only the ZDS record matching this number (e.g. 2 or 0002) or slug",
        ),
    };
}

/// One `typst compile` with the determinism flags applied. `root` is the
/// Typst project root; `extra` carries per-target flags such as the bundle
/// format.
pub fn compile(
    b: *std.Build,
    opts: Options,
    root: []const u8,
    extra: []const []const u8,
    input: []const u8,
    output: []const u8,
) *std.Build.Step.Run {
    return compileImpl(b, opts, root, extra, input, output, true);
}

/// CJK books name an exact Noto family but allow the operating system font
/// catalogue because those glyphs are not part of Typst's bundled fonts.
fn compileLocalized(
    b: *std.Build,
    opts: Options,
    root: []const u8,
    extra: []const []const u8,
    input: []const u8,
    output: []const u8,
) *std.Build.Step.Run {
    return compileImpl(b, opts, root, extra, input, output, false);
}

fn compileImpl(
    b: *std.Build,
    opts: Options,
    root: []const u8,
    extra: []const []const u8,
    input: []const u8,
    output: []const u8,
    ignore_system_fonts: bool,
) *std.Build.Step.Run {
    var argv = std.ArrayList([]const u8).empty;
    argv.appendSlice(b.allocator, &.{
        "typst", "compile", "--root", root,
    }) catch @panic("OOM");
    if (ignore_system_fonts) {
        argv.append(b.allocator, "--ignore-system-fonts") catch @panic("OOM");
    }
    argv.appendSlice(b.allocator, &.{
        "--creation-timestamp", opts.source_date_epoch,
    }) catch @panic("OOM");
    argv.appendSlice(b.allocator, extra) catch @panic("OOM");
    argv.appendSlice(b.allocator, &.{ input, output }) catch @panic("OOM");
    const run = b.addSystemCommand(argv.items);
    run.setCwd(b.path("."));
    // Typst discovers its own inputs, so the build graph cannot know when a
    // chapter or template changed. Without this the step is cached on its
    // argument list alone, which silently replays a stale success after a
    // source edit — including after an edit that no longer compiles.
    run.has_side_effects = true;
    return run;
}

pub fn add(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    test_step: *std.Build.Step,
    opts: Options,
) *std.Build.Step {
    const make_dir = b.addSystemCommand(&.{ "mkdir", "-p", "docs/build" });
    const zds_step = addRecords(b, opts, make_dir);
    const index_step = addIndex(b, opts, make_dir);
    const site_step = addZdsSite(b, opts);
    const book_step = addBook(b, opts, make_dir);
    const book_site_step = addBookSite(b, opts);
    const translations_step = addTranslations(b, opts, make_dir);
    const docs_step = b.step("docs", "Build every ZDS artifact plus every book");
    for ([_]*std.Build.Step{
        zds_step,
        index_step,
        site_step,
        book_step,
        book_site_step,
        translations_step,
    }) |step| docs_step.dependOn(step);
    addTool(b, target, optimize, test_step);
    return docs_step;
}

fn addRecords(
    b: *std.Build,
    opts: Options,
    make_dir: *std.Build.Step.Run,
) *std.Build.Step {
    const zds_step = b.step("zds", "Build the Zen Discussion (ZDS) record PDFs");
    const stems = recordStems(b, opts.record_filter);
    if (stems.len == 0) {
        const message = if (opts.record_filter) |value|
            b.fmt("no ZDS record in docs/zds/records matches -Dzds={s}", .{value})
        else
            "no numbered ZDS records found in docs/zds/records";
        zds_step.dependOn(&b.addFail(message).step);
    }
    for (stems) |stem| {
        const run = compile(
            b,
            opts,
            "docs",
            &.{},
            b.fmt("docs/zds/records/{s}.typ", .{stem}),
            b.fmt("docs/build/zds-{s}.pdf", .{stem}),
        );
        run.step.dependOn(&make_dir.step);
        zds_step.dependOn(&run.step);
    }
    return zds_step;
}

fn addIndex(
    b: *std.Build,
    opts: Options,
    make_dir: *std.Build.Step.Run,
) *std.Build.Step {
    const index_step = b.step("zds-index", "Build the ZDS index PDF");
    const index = compile(
        b,
        opts,
        "docs",
        &.{},
        "docs/zds/index.typ",
        "docs/build/zds-index.pdf",
    );
    index.step.dependOn(&make_dir.step);
    index_step.dependOn(&index.step);
    return index_step;
}

fn addZdsSite(b: *std.Build, opts: Options) *std.Build.Step {
    const site_step = b.step("zds-site", "Build the ZDS HTML bundle");
    const make_site_dir = b.addSystemCommand(&.{ "mkdir", "-p", "docs/build/zds-site" });
    const site = compile(
        b,
        opts,
        "docs",
        &.{ "--features", "html,bundle", "--format", "bundle" },
        "docs/zds/bundle.typ",
        "docs/build/zds-site",
    );
    site.step.dependOn(&make_site_dir.step);
    site_step.dependOn(&site.step);
    return site_step;
}

fn addBook(
    b: *std.Build,
    opts: Options,
    make_dir: *std.Build.Step.Run,
) *std.Build.Step {
    const book_step = b.step("book", "Build the zenfmt book PDF");
    const book = compile(
        b,
        opts,
        ".",
        &.{},
        "docs/book.typ",
        "docs/build/zenfmt-book.pdf",
    );
    book.step.dependOn(&make_dir.step);
    book_step.dependOn(&book.step);
    return book_step;
}

fn addBookSite(b: *std.Build, opts: Options) *std.Build.Step {
    const book_site_step = b.step(
        "book-site",
        "Build the zenfmt book as one HTML document per chapter",
    );
    const make_book_dir = b.addSystemCommand(&.{ "mkdir", "-p", "docs/build/book-site" });
    const book_site = compile(
        b,
        opts,
        ".",
        &.{ "--features", "html,bundle", "--format", "bundle" },
        "docs/book/site.typ",
        "docs/build/book-site",
    );
    book_site.step.dependOn(&make_book_dir.step);
    book_site_step.dependOn(&book_site.step);
    return book_site_step;
}

fn addTranslations(
    b: *std.Build,
    opts: Options,
    make_dir: *std.Build.Step.Run,
) *std.Build.Step {
    const translations_step = b.step(
        "book-translations",
        "Build the Simplified Chinese, Japanese, and Korean books",
    );
    const translations = [_]struct { code: []const u8, directory: []const u8 }{
        .{ .code = "zh-Hans", .directory = "zh-Hans" },
        .{ .code = "ja", .directory = "ja" },
        .{ .code = "ko", .directory = "ko" },
    };
    for (translations) |translation| {
        const pdf = compileLocalized(
            b,
            opts,
            ".",
            &.{},
            b.fmt("docs/i18n/{s}/book.typ", .{translation.directory}),
            b.fmt("docs/build/zenfmt-book-{s}.pdf", .{translation.code}),
        );
        pdf.step.dependOn(&make_dir.step);
        translations_step.dependOn(&pdf.step);

        const make_translation_dir = b.addSystemCommand(&.{
            "mkdir",
            "-p",
            b.fmt("docs/build/book-site-{s}", .{translation.code}),
        });
        const html = compileLocalized(
            b,
            opts,
            ".",
            &.{ "--features", "html,bundle", "--format", "bundle" },
            b.fmt("docs/i18n/{s}/site.typ", .{translation.directory}),
            b.fmt("docs/build/book-site-{s}", .{translation.code}),
        );
        html.step.dependOn(&make_translation_dir.step);
        translations_step.dependOn(&html.step);
    }
    return translations_step;
}

/// Numbered record stems (`NNNN-slug`) discovered in docs/zds/records, or
/// every record matching `filter` when `-Dzds=` is given. Placeholder drafts
/// (`XXXXX-slug`) are built only when the filter selects them.
fn recordStems(b: *std.Build, filter: ?[]const u8) [][]const u8 {
    const io = b.graph.io;
    var stems = std.ArrayList([]const u8).empty;
    var dir = b.build_root.handle.openDir(io, "docs/zds/records", .{ .iterate = true }) catch
        return stems.items;
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".typ")) continue;
        const stem = entry.name[0 .. entry.name.len - ".typ".len];
        if (stem.len < "0000-a".len) continue;
        const numbered = for (stem[0..4]) |byte| {
            if (!std.ascii.isDigit(byte)) break false;
        } else stem[4] == '-';
        const selected = if (filter) |value|
            recordMatches(stem, numbered, value)
        else
            numbered;
        if (selected) stems.append(b.allocator, b.dupe(stem)) catch @panic("OOM");
    }
    std.mem.sort([]const u8, stems.items, {}, struct {
        fn lessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
            return std.mem.order(u8, lhs, rhs) == .lt;
        }
    }.lessThan);
    return stems.items;
}

fn recordMatches(stem: []const u8, numbered: bool, filter: []const u8) bool {
    if (std.mem.eql(u8, stem, filter)) return true;
    const slug = if (numbered)
        stem["0000-".len..]
    else if (std.mem.startsWith(u8, stem, "XXXXX-"))
        stem["XXXXX-".len..]
    else
        stem;
    if (std.mem.eql(u8, slug, filter)) return true;
    if (numbered) {
        // Accept unpadded numbers such as -Dzds=2 for 0002.
        const wanted = std.fmt.parseInt(u16, filter, 10) catch return false;
        const actual = std.fmt.parseInt(u16, stem[0..4], 10) catch return false;
        return wanted == actual;
    }
    return false;
}

/// Wires tools/zds.zig, which owns the ZDS numbering workflow from ZDS 0001.
fn addTool(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    test_step: *std.Build.Step,
) void {
    const tool = b.addExecutable(.{
        .name = "zds-tool",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/zds.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });

    const list_run = b.addRunArtifact(tool);
    list_run.has_side_effects = true;
    list_run.addArgs(&.{ "--root", b.pathFromRoot("."), "list" });
    const list_step = b.step("zds-list", "List ZDS registry entries and placeholder drafts");
    list_step.dependOn(&list_run.step);

    const new_run = b.addRunArtifact(tool);
    new_run.has_side_effects = true;
    new_run.addArgs(&.{ "--root", b.pathFromRoot("."), "new" });
    if (b.args) |args| new_run.addArgs(args);
    const new_step = b.step(
        "zds-new",
        "Create a placeholder ZDS draft: zig build zds-new -- <slug>",
    );
    new_step.dependOn(&new_run.step);

    const promote_run = b.addRunArtifact(tool);
    promote_run.has_side_effects = true;
    promote_run.addArgs(&.{ "--root", b.pathFromRoot("."), "promote" });
    if (b.args) |args| promote_run.addArgs(args);
    const promote_step = b.step(
        "zds-promote",
        "Assign the next number to a draft and register it: zig build zds-promote -- <slug>",
    );
    promote_step.dependOn(&promote_run.step);

    const tool_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/zds.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(tool_tests).step);
}
