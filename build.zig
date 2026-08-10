//! Build graph for the zenfmt monorepo.
//!
//! The workspace layout follows ZDS 0002: `core/` is the format-blind
//! `zenfmt_core` library, `formats/` holds one library per format, `src/` is
//! the umbrella `zenfmt` library assembling the default bundle, and `cli/` is
//! the command-line tool importing only the umbrella. Support libraries live
//! under `support/`, language bindings under `bindings/`.
//!
//! This file is the orchestrator. The graph itself lives under `build/`, one
//! file per concern, because ZDS 0015 adds a second module graph for
//! `wasm32-freestanding` and a site pipeline, and one file would no longer
//! fit the standard's thousand-line bound.

const std = @import("std");
const zon = @import("build.zig.zon");

const modules = @import("build/modules.zig");
const python = @import("build/python.zig");
const benchmark = @import("build/benchmark.zig");
const docs = @import("build/docs.zig");
const wasm = @import("build/wasm.zig");
const site = @import("build/site.zig");
const server = @import("build/server.zig");

/// The canonical monorepo version (ZDS 0014): one `build.zig.zon` value
/// embedded in the CLI, the Python bridge, the browser module, and the
/// Python distribution.
pub const version: []const u8 = zon.version;

pub fn build(b: *std.Build) void {
    _ = std.SemanticVersion.parse(version) catch {
        @panic("build.zig.zon .version is not a valid semantic version");
    };
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const test_step = b.step("test", "Run the test suite");

    const build_info = b.addOptions();
    build_info.addOption([]const u8, "version", version);
    // The source revision the artifacts were built from. The identity role of
    // the browser ABI reports it, so it needs a value on every build; a local
    // build honestly says it does not know rather than inventing one.
    const revision = b.option(
        []const u8,
        "git-revision",
        "Source revision embedded in build artifacts; CI passes the commit SHA",
    ) orelse "unknown";
    build_info.addOption([]const u8, "revision", revision);
    // ZDS 0016: the serve subcommand and everything HTTP compile in by
    // default; `-Dserver=false` is the pure converter binary.
    const server_enabled = b.option(
        bool,
        "server",
        "Compile the zenfmt server and the serve subcommand (default true)",
    ) orelse true;
    build_info.addOption(bool, "server", server_enabled);
    const build_info_module = build_info.createModule();

    const graph = modules.create(b, target, optimize, build_info_module, true);
    const shared = modules.createShared(
        b,
        target,
        optimize,
        graph.get("zenfmt_core"),
        true,
    );
    const zencli_module = modules.createZencli(b, target, optimize);
    const server_modules = server.create(
        b,
        target,
        optimize,
        server_enabled,
        graph.umbrella,
        graph.get("zenfmt_core"),
        shared.capabilities,
        build_info_module,
        zencli_module,
    );
    const cli_module = modules.createCli(
        b,
        target,
        optimize,
        graph.umbrella,
        graph.get("zenfmt_core"),
        build_info_module,
        zencli_module,
        if (server_modules) |sm| sm.server else null,
    );
    const cli = addCli(b, target, optimize, graph, cli_module);
    addTests(b, target, optimize, test_step, graph, cli_module, zencli_module);

    const bridge = python.addBridge(
        b,
        target,
        optimize,
        test_step,
        build_info_module,
        graph.umbrella,
        graph.get("zenfmt_core"),
        shared,
    );
    const python_steps = python.addWorkflows(
        b,
        target,
        test_step,
        bridge,
        cli,
        revision,
    );

    server.addSteps(
        b,
        target,
        optimize,
        test_step,
        server_modules,
        cli,
        graph.umbrella,
        graph.get("zenfmt_core"),
        python_steps.uv,
    );

    const wasm_steps = wasm.add(b, optimize, build_info_module, test_step, version);
    benchmark.add(
        b,
        target,
        cli,
        graph.umbrella,
        graph.get("zenfmt_core"),
        python_steps.benchmark_python,
        python_steps.uv,
        version,
        revision,
        wasm_steps.build,
    );
    const docs_step = docs.add(b, target, optimize, test_step, docs.options(b));
    site.add(
        b,
        test_step,
        python_steps.uv,
        version,
        wasm_steps.build,
        wasm_steps.capabilities,
        docs_step,
    );
    addExamples(b, test_step);
    addFormatting(b, python_steps);
}

/// `examples/filters/` is a downstream consumer with its own build script: it
/// is the only thing in the repository that imports zenfmt the way a user
/// project does. Building it here is what turns a breaking change to the
/// published module names into a test failure rather than a bug report.
fn addExamples(b: *std.Build, test_step: *std.Build.Step) void {
    const build_example = b.addSystemCommand(&.{
        b.graph.zig_exe,
        "build",
        "--build-file",
        b.pathFromRoot("examples/filters/build.zig"),
        "--prefix",
        b.pathFromRoot("examples/filters/zig-out"),
    });
    build_example.has_side_effects = true;
    const step = b.step(
        "examples",
        "Build the downstream filter example against the published modules",
    );
    step.dependOn(&build_example.step);
    test_step.dependOn(step);
}

fn addCli(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    graph: modules.Set,
    cli_module: *std.Build.Module,
) *std.Build.Step.Compile {
    const cli = b.addExecutable(.{
        .name = "zenfmt",
        .root_module = b.createModule(.{
            .root_source_file = b.path("cli/src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zenfmt", .module = graph.umbrella },
                .{ .name = "zenfmt_cli", .module = cli_module },
            },
        }),
    });
    b.installArtifact(cli);

    const run_cli = b.addRunArtifact(cli);
    if (b.args) |args| run_cli.addArgs(args);
    const run_step = b.step("run", "Build and run the zenfmt CLI: zig build run -- ...");
    run_step.dependOn(&run_cli.step);
    return cli;
}

/// Per-module unit tests plus the end-to-end suites. Every module in the
/// graph is tested, so a library added to `build/modules.zig` is covered
/// without a second edit here.
fn addTests(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    test_step: *std.Build.Step,
    graph: modules.Set,
    cli_module: *std.Build.Module,
    zencli_module: *std.Build.Module,
) void {
    for (graph.modules) |entry| {
        const unit_tests = b.addTest(.{ .root_module = entry.module });
        test_step.dependOn(&b.addRunArtifact(unit_tests).step);
    }

    // The CLI and zencli modules sit outside the graph (they reach
    // std.process), so their behavior gates — the ZDS 0016 extraction
    // contract — are wired explicitly.
    const cli_tests = b.addTest(.{ .root_module = cli_module });
    test_step.dependOn(&b.addRunArtifact(cli_tests).step);
    const zencli_tests = b.addTest(.{ .root_module = zencli_module });
    test_step.dependOn(&b.addRunArtifact(zencli_tests).step);

    const end_to_end_sources = [_][]const u8{
        "tests/conversion.zig",
        "tests/manifest.zig",
        "tests/roundtrip.zig",
        "tests/fuzz.zig",
        "tests/filters.zig",
        "tests/docx.zig",
        "tests/detect.zig",
        "tests/media.zig",
        "tests/memory_output.zig",
        "tests/output_limit.zig",
        "tests/facets.zig",
        "tests/lowering.zig",
        "tests/oom.zig",
        "tests/docs_sync.zig",
        "tests/reports.zig",
        // The browser bundle is a host variant, not a target: its parity and
        // reachability run natively and cheaply, so `zig build test` covers
        // them without any WebAssembly compilation.
        "tests/wasm/parity.zig",
        "tests/wasm/limits.zig",
        "tests/wasm/reachability.zig",
    };
    for (end_to_end_sources) |source| {
        const end_to_end = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(source),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "zenfmt", .module = graph.umbrella },
                    .{ .name = "zenfmt_ooxml", .module = graph.get("zenfmt_ooxml") },
                    .{ .name = "zenfmt_core", .module = graph.get("zenfmt_core") },
                    .{ .name = "zenfmt_markdown", .module = graph.get("zenfmt_markdown") },
                },
            }),
        });
        test_step.dependOn(&b.addRunArtifact(end_to_end).step);
    }
}

const fmt_paths = [_][]const u8{
    "build.zig",                "build",
    "tools",                    "core",
    "support",                  "formats",
    "src",                      "cli",
    "server",                   "tests",
    "examples",                 "bindings",
    "benchmarks/benchmark.zig", "benchmarks/stages.zig",
};

fn addFormatting(b: *std.Build, steps: python.Steps) void {
    const check = b.addFmt(.{
        .paths = &fmt_paths,
        .check = true,
    });
    const check_step = b.step("fmt-check", "Check Zig and Python formatting");
    check_step.dependOn(&check.step);
    check_step.dependOn(steps.lint);
    check_step.dependOn(steps.format_check);

    const apply = b.addFmt(.{ .paths = &fmt_paths });
    const apply_step = b.step("fmt", "Format the Zig sources in place");
    apply_step.dependOn(&apply.step);

    // The site tooling is a separate uv project with its own Ruff settings,
    // so it gets its own invocation rather than being swept into the
    // library's.
    site.addFormatting(b, steps.uv, check_step, apply_step);
}
