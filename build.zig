//! Build graph for the zenfmt monorepo.
//!
//! The workspace layout follows ZDS 0002: `core/` is the format-blind
//! `zenfmt_core` library, `formats/` holds one library per format, `src/` is
//! the umbrella `zenfmt` library assembling the default bundle, and `cli/` is
//! the command-line tool importing only the umbrella. Support libraries under
//! `support/` and further format libraries attach in later delivery phases.

const std = @import("std");
const zon = @import("build.zig.zon");

/// The canonical monorepo version (ZDS 0014): one `build.zig.zon` value
/// embedded in the CLI, the Python bridge, and the Python distribution.
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
    const build_info_module = build_info.createModule();

    const cli = addLibraries(b, target, optimize, test_step, build_info_module);
    const bridge = addPythonBridge(b, target, optimize, test_step, build_info_module);
    const python = addPythonWorkflows(b, target, test_step, bridge, cli);
    addBenchmark(b, target, cli, python.benchmark_python);
    addZds(b, target, optimize, test_step);
    addFormatting(b, python);
}

// ---------------------------------------------------------- python bridge

/// The private C ABI shared library consumed by the `zenfmt` Python
/// package (ZDS 0014). `zig build python-native` installs it into
/// `<prefix>/lib` under its canonical per-platform name; the standard
/// `--prefix` flag redirects output for cross-compiled wheel builds.
fn addPythonBridge(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    test_step: *std.Build.Step,
    build_info_module: *std.Build.Module,
) *std.Build.Step.Compile {
    const bridge_module = b.createModule(.{
        .root_source_file = b.path("bindings/python/abi.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "zenfmt", .module = b.modules.get("zenfmt").? },
            .{ .name = "zenfmt_core", .module = b.modules.get("zenfmt_core").? },
            .{ .name = "zenfmt_build", .module = build_info_module },
        },
    });
    const bridge = b.addLibrary(.{
        .name = "zenfmt_py",
        .linkage = .dynamic,
        .root_module = bridge_module,
    });
    // This is a dynamically loaded C-ABI library, so its target C runtime
    // must be recorded in the shared object's dependency table. Without an
    // explicit libc link Zig emits a static-PIE-style ELF DSO; glibc happens
    // to load it, but musl faults while resolving the bridge at `dlopen`.
    const install = b.addInstallArtifact(bridge, .{
        .dest_dir = .{ .override = .{ .custom = "lib" } },
    });
    const python_native = b.step(
        "python-native",
        "Build the Python bridge shared library into <prefix>/lib",
    );
    python_native.dependOn(&install.step);

    const bridge_tests = b.addTest(.{ .root_module = bridge_module });
    test_step.dependOn(&b.addRunArtifact(bridge_tests).step);
    return bridge;
}

/// The uv-orchestrated Python workflow steps (ZDS 0014). uv owns the
/// Python environment, lockfile, and command execution; missing uv is a
/// clear prerequisite failure, never a silent skip.
const PythonSteps = struct {
    lint: *std.Build.Step,
    format_check: *std.Build.Step,
    benchmark_python: *std.Build.Step,
};

fn addPythonWorkflows(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    test_step: *std.Build.Step,
    bridge: *std.Build.Step.Compile,
    cli: *std.Build.Step.Compile,
) PythonSteps {
    // The host bridge staged into the source-layout package's private
    // resource directory: the editable install exposes exactly that
    // location as the package resource root, so development and wheels
    // share one loader rule.
    const runtime_name = switch (target.result.os.tag) {
        .windows => "zenfmt_py.dll",
        .macos => "libzenfmt_py.dylib",
        else => "libzenfmt_py.so",
    };
    const stage = b.addUpdateSourceFiles();
    stage.addCopyFileToSource(
        bridge.getEmittedBin(),
        b.fmt("python/src/zenfmt/_native/{s}", .{runtime_name}),
    );

    const uv_missing: ?*std.Build.Step = blk: {
        _ = b.findProgram(&.{"uv"}, &.{}) catch {
            const fail = b.addFail(
                "uv is required for the Python steps: install it from " ++
                    "https://docs.astral.sh/uv/ and re-run",
            );
            break :blk &fail.step;
        };
        break :blk null;
    };

    const Run = struct {
        fn command(
            builder: *std.Build,
            missing: ?*std.Build.Step,
            argv: []const []const u8,
        ) *std.Build.Step.Run {
            const run = builder.addSystemCommand(argv);
            run.has_side_effects = true;
            run.setCwd(builder.path("."));
            if (missing) |fail| run.step.dependOn(fail);
            return run;
        }
    };

    // Every uv command runs from the repository root (so zig-out/ and
    // benchmarks/ literals stay stable) and names the Python subproject
    // explicitly with --project python / a positional project directory.
    const sync = Run.command(b, uv_missing, &.{
        "uv", "sync", "--project", "python", "--locked",
    });
    sync.step.dependOn(&stage.step);
    const sync_step = b.step(
        "python-sync",
        "Build and stage the host bridge, then sync the locked Python " ++
            "development environment",
    );
    sync_step.dependOn(&sync.step);

    const pytest = Run.command(b, uv_missing, &.{
        "uv",           "run",    "--project", "python",
        "--locked",     "pytest", "-m",        "not release",
        "python/tests",
    });
    pytest.step.dependOn(&stage.step);
    const pytest_step = b.step(
        "python-test",
        "Build and stage the host bridge, then run pytest through uv",
    );
    pytest_step.dependOn(&pytest.step);
    test_step.dependOn(pytest_step);

    const lint = Run.command(b, uv_missing, &.{
        "uv", "run", "--project", "python", "--locked", "ruff", "check", "python",
    });
    const lint_step = b.step("python-lint", "Run ruff check through uv");
    lint_step.dependOn(&lint.step);

    const format = Run.command(b, uv_missing, &.{
        "uv", "run", "--project", "python", "--locked", "ruff", "format", "python",
    });
    const format_step = b.step(
        "python-format",
        "Run the Ruff formatter in write mode",
    );
    format_step.dependOn(&format.step);

    const format_check = Run.command(b, uv_missing, &.{
        "uv",       "run",  "--project", "python",
        "--locked", "ruff", "format",    "--check",
        "python",
    });
    const format_check_step = b.step(
        "python-format-check",
        "Check Ruff formatting without edits",
    );
    format_check_step.dependOn(&format_check.step);

    // `python-wheel`: the host platform wheel through uv; the Hatchling
    // hook invokes `zig build python-native` itself for a ReleaseSafe
    // bridge and sets the platform tag.
    const wheel = Run.command(b, uv_missing, &.{
        "uv",        "build",               "--wheel",
        "--out-dir", "zig-out/python/dist", "python",
    });
    const wheel_step = b.step(
        "python-wheel",
        "Build the host platform wheel into zig-out/python/dist",
    );
    wheel_step.dependOn(&wheel.step);

    // `python-check`: the release-gate aggregate (ZDS 0014): lint, format
    // check, the full pytest suite with every format required, a wheel
    // and source distribution, and the installed-artifact release tests.
    const strict_pytest = Run.command(b, uv_missing, &.{
        "uv",           "run",    "--project", "python",
        "--locked",     "pytest", "-m",        "not release",
        "python/tests",
    });
    strict_pytest.step.dependOn(&stage.step);
    strict_pytest.setEnvironmentVariable("ZENFMT_REQUIRE_ALL_FORMATS", "1");

    const sdist = Run.command(b, uv_missing, &.{
        "uv",        "build",               "--sdist",
        "--out-dir", "zig-out/python/dist", "python",
    });

    const release_tests = Run.command(b, uv_missing, &.{
        "uv",                   "run",    "--project", "python",
        "--locked",             "pytest", "-m",        "release",
        "python/tests/release",
    });
    release_tests.step.dependOn(&wheel.step);
    release_tests.step.dependOn(&sdist.step);

    const check_step = b.step(
        "python-check",
        "Run the full Python release gate: lint, format, tests, wheel, " ++
            "sdist, and installed-artifact checks",
    );
    check_step.dependOn(lint_step);
    check_step.dependOn(format_check_step);
    check_step.dependOn(&strict_pytest.step);
    check_step.dependOn(&release_tests.step);

    // `benchmark-python` (ZDS 0014): a clean isolated environment holding
    // the exact just-built wheel, then the installed-wheel profile suite
    // with parity checks. `zig build benchmark` depends on this step so
    // its cold row runs against the same environment.
    const venv = Run.command(b, uv_missing, &.{
        "uv", "venv", "--clear", "benchmarks/.venv-wheel",
    });
    venv.step.dependOn(&wheel.step);
    const wheel_install = Run.command(b, uv_missing, &.{
        "uv",                     "pip",
        "install",                "--python",
        "benchmarks/.venv-wheel", "--no-index",
        "--find-links",           "zig-out/python/dist",
        "--reinstall",            "zenfmt",
    });
    wheel_install.step.dependOn(&venv.step);
    const suite = Run.command(b, uv_missing, &.{
        "benchmarks/.venv-wheel/bin/python", "-I",
        "python/benchmarks/python_api.py",   "--suite",
    });
    suite.step.dependOn(&wheel_install.step);
    suite.step.dependOn(&b.addInstallArtifact(cli, .{}).step);
    const benchmark_python_step = b.step(
        "benchmark-python",
        "Clean-install the built wheel and run the Python API benchmark " ++
            "suite (writes benchmarks/results/python.json)",
    );
    benchmark_python_step.dependOn(&suite.step);

    return .{
        .lint = lint_step,
        .format_check = format_check_step,
        .benchmark_python = benchmark_python_step,
    };
}

// ------------------------------------------------------------- benchmark

/// `zig build benchmark` (paxos-zig pattern): converts the downloaded corpus
/// with zenfmt, pandoc, and anydoc, measuring latency, CPU, and peak RSS.
/// Run `benchmarks/fetch_corpus.sh` once to populate `benchmarks/corpus`.
fn addBenchmark(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    cli: *std.Build.Step.Compile,
    benchmark_python: *std.Build.Step,
) void {
    const harness = b.addExecutable(.{
        .name = "zenfmt-benchmark",
        .root_module = b.createModule(.{
            .root_source_file = b.path("benchmarks/benchmark.zig"),
            .target = target,
            .optimize = .ReleaseSafe,
        }),
    });
    const run_harness = b.addRunArtifact(harness);
    run_harness.has_side_effects = true;
    run_harness.setCwd(b.path("."));
    run_harness.addArg("--zenfmt");
    run_harness.addArtifactArg(cli);
    if (b.args) |args| run_harness.addArgs(args);
    // The installed-wheel environment and its detailed suite run first so
    // the harness's cold `zenfmt-python-wheel` row uses the same wheel.
    run_harness.step.dependOn(benchmark_python);
    const benchmark_step = b.step(
        "benchmark",
        "Run the conversion benchmark against pandoc, anydoc, and the " ++
            "installed zenfmt wheel (use -Doptimize=ReleaseSafe for " ++
            "publishable numbers)",
    );
    benchmark_step.dependOn(&run_harness.step);

    // `zig build benchmark-stages`: the in-process stage split (ZDS 0013),
    // written to benchmarks/results/stages.json.
    const stages = b.addExecutable(.{
        .name = "zenfmt-benchmark-stages",
        .root_module = b.createModule(.{
            .root_source_file = b.path("benchmarks/stages.zig"),
            .target = target,
            .optimize = .ReleaseSafe,
            .imports = &.{
                .{ .name = "zenfmt", .module = b.modules.get("zenfmt").? },
                .{ .name = "zenfmt_core", .module = b.modules.get("zenfmt_core").? },
            },
        }),
    });
    const run_stages = b.addRunArtifact(stages);
    run_stages.has_side_effects = true;
    run_stages.setCwd(b.path("."));
    if (b.args) |args| run_stages.addArgs(args);
    const stages_step = b.step(
        "benchmark-stages",
        "Run the in-process stage benchmark over the corpus " ++
            "(writes benchmarks/results/stages.json)",
    );
    stages_step.dependOn(&run_stages.step);
}

// ------------------------------------------------------------- libraries

/// The Zig module graph from ZDS 0002. Import edges are enforced here by
/// construction: core imports nothing, format libraries import core (plus
/// support libraries when those exist), the umbrella imports core and the
/// default formats, and the CLI imports only the umbrella.
fn addLibraries(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    test_step: *std.Build.Step,
    build_info_module: *std.Build.Module,
) *std.Build.Step.Compile {
    const core = b.addModule("zenfmt_core", .{
        .root_source_file = b.path("core/src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const xml = b.addModule("zenfmt_xml", .{
        .root_source_file = b.path("support/xml/src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const ooxml = b.addModule("zenfmt_ooxml", .{
        .root_source_file = b.path("support/ooxml/src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zenfmt_core", .module = core },
            .{ .name = "zenfmt_xml", .module = xml },
        },
    });

    const text = b.addModule("zenfmt_text", .{
        .root_source_file = b.path("formats/text/src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "zenfmt_core", .module = core }},
    });

    const markdown = b.addModule("zenfmt_markdown", .{
        .root_source_file = b.path("formats/markdown/src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "zenfmt_core", .module = core }},
    });

    const csv = b.addModule("zenfmt_csv", .{
        .root_source_file = b.path("formats/csv/src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "zenfmt_core", .module = core }},
    });

    const docx = b.addModule("zenfmt_docx", .{
        .root_source_file = b.path("formats/docx/src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zenfmt_core", .module = core },
            .{ .name = "zenfmt_xml", .module = xml },
            .{ .name = "zenfmt_ooxml", .module = ooxml },
        },
    });

    const rtf = b.addModule("zenfmt_rtf", .{
        .root_source_file = b.path("formats/rtf/src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "zenfmt_core", .module = core }},
    });

    const xlsx = b.addModule("zenfmt_xlsx", .{
        .root_source_file = b.path("formats/xlsx/src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zenfmt_core", .module = core },
            .{ .name = "zenfmt_xml", .module = xml },
            .{ .name = "zenfmt_ooxml", .module = ooxml },
        },
    });

    const odt = b.addModule("zenfmt_odt", .{
        .root_source_file = b.path("formats/odt/src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zenfmt_core", .module = core },
            .{ .name = "zenfmt_xml", .module = xml },
            .{ .name = "zenfmt_ooxml", .module = ooxml },
        },
    });

    const html = b.addModule("zenfmt_html", .{
        .root_source_file = b.path("formats/html/src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "zenfmt_core", .module = core }},
    });

    const asciidoc = b.addModule("zenfmt_asciidoc", .{
        .root_source_file = b.path("formats/asciidoc/src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "zenfmt_core", .module = core }},
    });

    const rst = b.addModule("zenfmt_rst", .{
        .root_source_file = b.path("formats/rst/src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "zenfmt_core", .module = core }},
    });

    const pptx = b.addModule("zenfmt_pptx", .{
        .root_source_file = b.path("formats/pptx/src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zenfmt_core", .module = core },
            .{ .name = "zenfmt_xml", .module = xml },
            .{ .name = "zenfmt_ooxml", .module = ooxml },
        },
    });

    const cfb = b.addModule("zenfmt_cfb", .{
        .root_source_file = b.path("support/cfb/src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "zenfmt_core", .module = core }},
    });

    const ods = b.addModule("zenfmt_ods", .{
        .root_source_file = b.path("formats/ods/src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zenfmt_core", .module = core },
            .{ .name = "zenfmt_xml", .module = xml },
            .{ .name = "zenfmt_ooxml", .module = ooxml },
        },
    });

    const odp = b.addModule("zenfmt_odp", .{
        .root_source_file = b.path("formats/odp/src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zenfmt_core", .module = core },
            .{ .name = "zenfmt_xml", .module = xml },
            .{ .name = "zenfmt_ooxml", .module = ooxml },
        },
    });

    const epub = b.addModule("zenfmt_epub", .{
        .root_source_file = b.path("formats/epub/src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zenfmt_core", .module = core },
            .{ .name = "zenfmt_xml", .module = xml },
            .{ .name = "zenfmt_ooxml", .module = ooxml },
            .{ .name = "zenfmt_html", .module = html },
        },
    });

    const pdf = b.addModule("zenfmt_pdf", .{
        .root_source_file = b.path("formats/pdf/src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "zenfmt_core", .module = core }},
    });

    const doc = b.addModule("zenfmt_doc", .{
        .root_source_file = b.path("formats/doc/src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zenfmt_core", .module = core },
            .{ .name = "zenfmt_cfb", .module = cfb },
        },
    });

    const xls = b.addModule("zenfmt_xls", .{
        .root_source_file = b.path("formats/xls/src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zenfmt_core", .module = core },
            .{ .name = "zenfmt_cfb", .module = cfb },
        },
    });

    const ppt = b.addModule("zenfmt_ppt", .{
        .root_source_file = b.path("formats/ppt/src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zenfmt_core", .module = core },
            .{ .name = "zenfmt_cfb", .module = cfb },
        },
    });

    const xlsb = b.addModule("zenfmt_xlsb", .{
        .root_source_file = b.path("formats/xlsb/src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zenfmt_core", .module = core },
            .{ .name = "zenfmt_xml", .module = xml },
            .{ .name = "zenfmt_ooxml", .module = ooxml },
        },
    });

    const umbrella = b.addModule("zenfmt", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zenfmt_build", .module = build_info_module },
            .{ .name = "zenfmt_core", .module = core },
            .{ .name = "zenfmt_text", .module = text },
            .{ .name = "zenfmt_markdown", .module = markdown },
            .{ .name = "zenfmt_csv", .module = csv },
            .{ .name = "zenfmt_docx", .module = docx },
            .{ .name = "zenfmt_rtf", .module = rtf },
            .{ .name = "zenfmt_xlsx", .module = xlsx },
            .{ .name = "zenfmt_odt", .module = odt },
            .{ .name = "zenfmt_pptx", .module = pptx },
            .{ .name = "zenfmt_html", .module = html },
            .{ .name = "zenfmt_asciidoc", .module = asciidoc },
            .{ .name = "zenfmt_rst", .module = rst },
            .{ .name = "zenfmt_ods", .module = ods },
            .{ .name = "zenfmt_odp", .module = odp },
            .{ .name = "zenfmt_epub", .module = epub },
            .{ .name = "zenfmt_pdf", .module = pdf },
            .{ .name = "zenfmt_doc", .module = doc },
            .{ .name = "zenfmt_xls", .module = xls },
            .{ .name = "zenfmt_ppt", .module = ppt },
            .{ .name = "zenfmt_xlsb", .module = xlsb },
        },
    });

    const cli = b.addExecutable(.{
        .name = "zenfmt",
        .root_module = b.createModule(.{
            .root_source_file = b.path("cli/src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zenfmt", .module = umbrella }},
        }),
    });
    b.installArtifact(cli);

    const run_cli = b.addRunArtifact(cli);
    if (b.args) |args| run_cli.addArgs(args);
    const run_step = b.step("run", "Build and run the zenfmt CLI: zig build run -- ...");
    run_step.dependOn(&run_cli.step);

    const unit_test_modules = [_]*std.Build.Module{
        core, xml,  ooxml, cfb,  text, markdown, csv,  docx,
        rtf,  xlsx, odt,   pptx, html, asciidoc, rst,  ods,
        odp,  epub, pdf,   doc,  xls,  ppt,      xlsb, umbrella,
    };
    for (unit_test_modules) |module| {
        const unit_tests = b.addTest(.{ .root_module = module });
        test_step.dependOn(&b.addRunArtifact(unit_tests).step);
    }

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
    };
    for (end_to_end_sources) |source| {
        const end_to_end = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(source),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "zenfmt", .module = umbrella },
                    .{ .name = "zenfmt_ooxml", .module = ooxml },
                    .{ .name = "zenfmt_core", .module = core },
                    .{ .name = "zenfmt_markdown", .module = markdown },
                },
            }),
        });
        test_step.dependOn(&b.addRunArtifact(end_to_end).step);
    }
    return cli;
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

    // The book compiles with the repository as the Typst root: the
    // benchmark chapter reads benchmarks/results/latest.json.
    const book_step = b.step("book", "Build the zenfmt book PDF");
    const compile_book = b.addSystemCommand(&.{
        "typst",         "compile",
        "--root",        ".",
        "docs/book.typ", "docs/build/zenfmt-book.pdf",
    });
    compile_book.step.dependOn(&make_dir.step);
    book_step.dependOn(&compile_book.step);

    const docs_step = b.step("docs", "Build every ZDS artifact plus the book");
    docs_step.dependOn(zds_step);
    docs_step.dependOn(index_step);
    docs_step.dependOn(site_step);
    docs_step.dependOn(book_step);

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

const fmt_paths = [_][]const u8{
    "build.zig",                "tools",
    "core",                     "support",
    "formats",                  "src",
    "cli",                      "tests",
    "examples",                 "bindings",
    "benchmarks/benchmark.zig", "benchmarks/stages.zig",
};

fn addFormatting(b: *std.Build, python: PythonSteps) void {
    const check = b.addFmt(.{
        .paths = &fmt_paths,
        .check = true,
    });
    const check_step = b.step("fmt-check", "Check Zig and Python formatting");
    check_step.dependOn(&check.step);
    check_step.dependOn(python.lint);
    check_step.dependOn(python.format_check);

    const apply = b.addFmt(.{ .paths = &fmt_paths });
    const apply_step = b.step("fmt", "Format the Zig sources in place");
    apply_step.dependOn(&apply.step);
}
