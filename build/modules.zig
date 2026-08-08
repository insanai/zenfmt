//! The zenfmt Zig module graph (ZDS 0002, Workspace Layout).
//!
//! Import edges live here as data rather than as repeated calls, because the
//! browser target (ZDS 0015) builds the same graph a second time for
//! `wasm32-freestanding`. One table means the two graphs cannot drift: a
//! format library added for the CLI is compiled into the browser module by
//! construction, not by remembering to add it twice.
//!
//! Only the native graph publishes module names. A published name is a
//! package-level export that dependent build scripts may import, and a name
//! can be published once; the second graph therefore creates anonymous
//! modules with identical contents at a different target.

const std = @import("std");

/// One library: its module name, its root source file, and the modules it is
/// allowed to import. A library not named in `deps` is not reachable from
/// that library, which is how the layering rule is enforced.
pub const Library = struct {
    name: []const u8,
    root: []const u8,
    deps: []const []const u8 = &.{},
};

/// Format-blind core and the container support libraries.
pub const support_libraries = [_]Library{
    .{ .name = "zenfmt_core", .root = "core/src/root.zig" },
    .{ .name = "zenfmt_xml", .root = "support/xml/src/root.zig" },
    .{
        .name = "zenfmt_ooxml",
        .root = "support/ooxml/src/root.zig",
        .deps = &.{ "zenfmt_core", "zenfmt_xml" },
    },
    .{
        .name = "zenfmt_cfb",
        .root = "support/cfb/src/root.zig",
        .deps = &.{"zenfmt_core"},
    },
};

const core_only: []const []const u8 = &.{"zenfmt_core"};
const ooxml_stack: []const []const u8 = &.{ "zenfmt_core", "zenfmt_xml", "zenfmt_ooxml" };
const cfb_stack: []const []const u8 = &.{ "zenfmt_core", "zenfmt_cfb" };

/// The default bundle's format libraries, in `src/default_bundle.zig` order.
/// `zenfmt_html` precedes `zenfmt_epub` because EPUB reuses the HTML reader.
pub const format_libraries = [_]Library{
    .{ .name = "zenfmt_text", .root = "formats/text/src/root.zig", .deps = core_only },
    .{ .name = "zenfmt_markdown", .root = "formats/markdown/src/root.zig", .deps = core_only },
    .{ .name = "zenfmt_csv", .root = "formats/csv/src/root.zig", .deps = core_only },
    .{ .name = "zenfmt_docx", .root = "formats/docx/src/root.zig", .deps = ooxml_stack },
    .{ .name = "zenfmt_rtf", .root = "formats/rtf/src/root.zig", .deps = core_only },
    .{ .name = "zenfmt_xlsx", .root = "formats/xlsx/src/root.zig", .deps = ooxml_stack },
    .{ .name = "zenfmt_odt", .root = "formats/odt/src/root.zig", .deps = ooxml_stack },
    .{ .name = "zenfmt_pptx", .root = "formats/pptx/src/root.zig", .deps = ooxml_stack },
    .{ .name = "zenfmt_html", .root = "formats/html/src/root.zig", .deps = core_only },
    .{ .name = "zenfmt_asciidoc", .root = "formats/asciidoc/src/root.zig", .deps = core_only },
    .{ .name = "zenfmt_rst", .root = "formats/rst/src/root.zig", .deps = core_only },
    .{ .name = "zenfmt_ods", .root = "formats/ods/src/root.zig", .deps = ooxml_stack },
    .{ .name = "zenfmt_odp", .root = "formats/odp/src/root.zig", .deps = ooxml_stack },
    .{
        .name = "zenfmt_epub",
        .root = "formats/epub/src/root.zig",
        .deps = &.{ "zenfmt_core", "zenfmt_xml", "zenfmt_ooxml", "zenfmt_html" },
    },
    .{ .name = "zenfmt_pdf", .root = "formats/pdf/src/root.zig", .deps = core_only },
    .{ .name = "zenfmt_doc", .root = "formats/doc/src/root.zig", .deps = cfb_stack },
    .{ .name = "zenfmt_xls", .root = "formats/xls/src/root.zig", .deps = cfb_stack },
    .{ .name = "zenfmt_ppt", .root = "formats/ppt/src/root.zig", .deps = cfb_stack },
    .{ .name = "zenfmt_xlsb", .root = "formats/xlsb/src/root.zig", .deps = ooxml_stack },
};

/// One resolved graph. `modules` holds every library in creation order:
/// support libraries, then format libraries, then the umbrella.
pub const Set = struct {
    modules: []const Named,
    umbrella: *std.Build.Module,

    pub const Named = struct {
        name: []const u8,
        module: *std.Build.Module,
    };

    /// The module registered under `name`. A miss is a build-script defect,
    /// not a user error, so it panics rather than returning null.
    pub fn get(set: Set, name: []const u8) *std.Build.Module {
        for (set.modules) |entry| {
            if (std.mem.eql(u8, entry.name, name)) return entry.module;
        }
        std.debug.panic("no module named '{s}' in the graph", .{name});
    }
};

/// Builds the whole graph at one target. `publish` registers the public
/// module names; pass false for a second graph at another target.
pub fn create(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    build_info: *std.Build.Module,
    publish: bool,
) Set {
    var created = std.ArrayList(Set.Named).empty;
    created.ensureTotalCapacity(
        b.allocator,
        support_libraries.len + format_libraries.len + 1,
    ) catch @panic("OOM");

    for (support_libraries ++ format_libraries) |library| {
        const module = define(b, publish, library.name, .{
            .root_source_file = b.path(library.root),
            .target = target,
            .optimize = optimize,
            .imports = importsFor(b, created.items, library.deps),
        });
        created.appendAssumeCapacity(.{ .name = library.name, .module = module });
    }

    const umbrella = define(b, publish, "zenfmt", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = umbrellaImports(b, created.items, build_info),
    });
    created.appendAssumeCapacity(.{ .name = "zenfmt", .module = umbrella });

    return .{ .modules = created.items, .umbrella = umbrella };
}

/// The comptime helpers every language binding shares: capability document
/// generators and display-name validation. Leaf modules, so both the native
/// bridge and the browser module can hold them without either depending on
/// the other.
pub const Shared = struct {
    capabilities: *std.Build.Module,
    names: *std.Build.Module,
};

pub fn createShared(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    core: *std.Build.Module,
    publish: bool,
) Shared {
    return .{
        .capabilities = define(b, publish, "zenfmt_capabilities", .{
            .root_source_file = b.path("bindings/shared/capabilities.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zenfmt_core", .module = core }},
        }),
        .names = define(b, publish, "zenfmt_names", .{
            .root_source_file = b.path("bindings/shared/names.zig"),
            .target = target,
            .optimize = optimize,
        }),
    };
}

/// The command-line front end, deliberately outside the umbrella.
///
/// It reaches `std.process` and threaded I/O, neither of which exists on
/// `wasm32-freestanding`. Keeping it in the umbrella would mean the browser
/// module's ability to build depended on Zig never analyzing an unused
/// declaration — true today, and not something the security boundary should
/// rest on. As its own module it simply is not in that graph.
pub fn createCli(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    umbrella: *std.Build.Module,
    core: *std.Build.Module,
    build_info: *std.Build.Module,
) *std.Build.Module {
    return b.addModule("zenfmt_cli", .{
        .root_source_file = b.path("src/cli.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zenfmt", .module = umbrella },
            .{ .name = "zenfmt_core", .module = core },
            .{ .name = "zenfmt_build", .module = build_info },
        },
    });
}

fn define(
    b: *std.Build,
    publish: bool,
    name: []const u8,
    options: std.Build.Module.CreateOptions,
) *std.Build.Module {
    return if (publish) b.addModule(name, options) else b.createModule(options);
}

fn importsFor(
    b: *std.Build,
    created: []const Set.Named,
    deps: []const []const u8,
) []const std.Build.Module.Import {
    const imports = b.allocator.alloc(
        std.Build.Module.Import,
        deps.len,
    ) catch @panic("OOM");
    for (deps, imports) |name, *import| {
        import.* = .{ .name = name, .module = lookup(created, name) };
    }
    return imports;
}

/// The umbrella imports the build-info options module, core, and every
/// format library, so `src/default_bundle.zig` can assemble the bundle.
fn umbrellaImports(
    b: *std.Build,
    created: []const Set.Named,
    build_info: *std.Build.Module,
) []const std.Build.Module.Import {
    const imports = b.allocator.alloc(
        std.Build.Module.Import,
        format_libraries.len + 2,
    ) catch @panic("OOM");
    imports[0] = .{ .name = "zenfmt_build", .module = build_info };
    imports[1] = .{ .name = "zenfmt_core", .module = lookup(created, "zenfmt_core") };
    for (format_libraries, imports[2..]) |library, *import| {
        import.* = .{ .name = library.name, .module = lookup(created, library.name) };
    }
    return imports;
}

fn lookup(created: []const Set.Named, name: []const u8) *std.Build.Module {
    for (created) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return entry.module;
    }
    std.debug.panic("library '{s}' is imported before it is created", .{name});
}
