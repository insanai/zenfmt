//! Build graph for the zenfmt monorepo.
//!
//! The repository currently ships the documentation tree and the tooling that
//! maintains it. The library and the CLI attach at the marked extension point
//! below once ZDS 0002 leaves discussion; see the delivery plan in that record.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const test_step = b.step("test", "Run the test suite");

    // ---------------------------------------------------------------
    // Extension point (ZDS 0002, phase 1): the `zenfmt` library module
    // rooted at src/root.zig, its unit tests, and the CLI package under
    // cli/ attach here. Nothing below this comment depends on them.
    // ---------------------------------------------------------------

    addZds(b, target, optimize, test_step);
    addFormatting(b);
}

// -------------------------------------------------------------- records

/// Compiles ZDS records, the index, and the experimental HTML bundle.
///
/// Records are discovered by scanning `docs/zds/records`, so adding a record
/// never requires editing this file. Only `docs/zds/registry.typ` and
/// `docs/zds/bundle.typ` carry per-record metadata, and `zig build
/// zds-promote` maintains both.
fn addZds(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    test_step: *std.Build.Step,
) void {
    const make_dir = b.addSystemCommand(&.{ "mkdir", "-p", "docs/build" });

    const filter = b.option(
        []const u8,
        "zds",
        "Build only the ZDS record matching this number (e.g. 2 or 0002) or slug",
    );

    const zds_step = b.step("zds", "Build the Zen Discussion (ZDS) record PDFs");
    const stems = zdsRecordStems(b, filter);
    if (stems.len == 0) {
        const message = if (filter) |value|
            b.fmt("no ZDS record in docs/zds/records matches -Dzds={s}", .{value})
        else
            "no numbered ZDS records found in docs/zds/records";
        zds_step.dependOn(&b.addFail(message).step);
    }
    for (stems) |stem| {
        const compile = b.addSystemCommand(&.{
            "typst",
            "compile",
            "--root",
            "docs",
            b.fmt("docs/zds/records/{s}.typ", .{stem}),
            b.fmt("docs/build/zds-{s}.pdf", .{stem}),
        });
        compile.step.dependOn(&make_dir.step);
        zds_step.dependOn(&compile.step);
    }

    const index_step = b.step("zds-index", "Build the ZDS index PDF");
    const compile_index = b.addSystemCommand(&.{
        "typst",              "compile",
        "--root",             "docs",
        "docs/zds/index.typ", "docs/build/zds-index.pdf",
    });
    compile_index.step.dependOn(&make_dir.step);
    index_step.dependOn(&compile_index.step);

    const site_step = b.step("zds-site", "Build the experimental ZDS HTML bundle");
    const make_site_dir = b.addSystemCommand(&.{ "mkdir", "-p", "docs/build/zds-site" });
    const compile_site = b.addSystemCommand(&.{
        "typst",               "compile",
        "--features",          "html,bundle",
        "--root",              "docs",
        "--format",            "bundle",
        "docs/zds/bundle.typ", "docs/build/zds-site",
    });
    compile_site.step.dependOn(&make_site_dir.step);
    site_step.dependOn(&compile_site.step);

    const docs_step = b.step("docs", "Build every ZDS artifact: records, index, and site");
    docs_step.dependOn(zds_step);
    docs_step.dependOn(index_step);
    docs_step.dependOn(site_step);

    addZdsTool(b, target, optimize, test_step);
}

/// Numbered record stems (`NNNN-slug`) discovered in docs/zds/records, or
/// every record matching `filter` when `-Dzds=` is given. Placeholder drafts
/// (`XXXXX-slug`) are built only when the filter selects them.
fn zdsRecordStems(b: *std.Build, filter: ?[]const u8) [][]const u8 {
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
            zdsRecordMatches(stem, numbered, value)
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

fn zdsRecordMatches(stem: []const u8, numbered: bool, filter: []const u8) bool {
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
fn addZdsTool(
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

// ------------------------------------------------------------ formatting

fn addFormatting(b: *std.Build) void {
    const check = b.addFmt(.{
        .paths = &.{ "build.zig", "tools" },
        .check = true,
    });
    const check_step = b.step("fmt-check", "Check Zig source formatting");
    check_step.dependOn(&check.step);

    const apply = b.addFmt(.{ .paths = &.{ "build.zig", "tools" } });
    const apply_step = b.step("fmt", "Format the Zig sources in place");
    apply_step.dependOn(&apply.step);
}
