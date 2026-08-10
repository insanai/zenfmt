//! Benchmark harnesses (paxos-zig pattern): the cross-tool comparison, the
//! in-process stage split (ZDS 0013), and the dashboard aggregation that
//! feeds both the book's benchmark chapter and the site (ZDS 0015).
//!
//! Run `benchmarks/fetch_corpus.sh` once to populate `benchmarks/corpus`.

const std = @import("std");
const python = @import("python.zig");

pub fn add(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    cli: *std.Build.Step.Compile,
    umbrella: *std.Build.Module,
    core: *std.Build.Module,
    benchmark_python: *std.Build.Step,
    uv: python.Uv,
    version: []const u8,
    revision: []const u8,
    wasm_step: *std.Build.Step,
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
    run_harness.addArgs(&.{ "--version", version, "--revision", revision });
    if (b.args) |args| run_harness.addArgs(args);
    // The installed-wheel environment and its detailed suite run first so the
    // harness's cold `zenfmt-python-wheel` row uses the same wheel.
    run_harness.step.dependOn(benchmark_python);
    const benchmark_step = b.step(
        "benchmark",
        "Run the conversion benchmark against Docling, AnyDoc, Pandoc, and " ++
            "the installed zenfmt wheel (use -Doptimize=ReleaseSafe for " ++
            "publishable numbers)",
    );
    benchmark_step.dependOn(&run_harness.step);

    // The Docling comparison environment (ZDS 0016): a pinned uv venv with
    // Docling and no OCR extras. `benchmark-docling-setup` provisions it;
    // the maintainer runs it once before a publishable benchmark, and the
    // harness's `--docling` default points at its interpreter.
    const docling_venv = uv.command(&.{
        "uv", "venv", "--python", "3.13", "benchmarks/.venv-docling",
    });
    const docling_install = uv.command(&.{
        "uv",                       "pip",
        "install",                  "--python",
        "benchmarks/.venv-docling", "docling",
    });
    docling_install.step.dependOn(&docling_venv.step);
    const docling_setup_step = b.step(
        "benchmark-docling-setup",
        "Provision the pinned Docling comparison environment (uv venv)",
    );
    docling_setup_step.dependOn(&docling_install.step);

    // `zig build benchmark-stages`: the in-process stage split (ZDS 0013),
    // written to benchmarks/results/stages.json.
    const stages = b.addExecutable(.{
        .name = "zenfmt-benchmark-stages",
        .root_module = b.createModule(.{
            .root_source_file = b.path("benchmarks/stages.zig"),
            .target = target,
            .optimize = .ReleaseSafe,
            .imports = &.{
                .{ .name = "zenfmt", .module = umbrella },
                .{ .name = "zenfmt_core", .module = core },
            },
        }),
    });
    const run_stages = b.addRunArtifact(stages);
    run_stages.has_side_effects = true;
    run_stages.setCwd(b.path("."));
    run_stages.addArgs(&.{ "--version", version, "--revision", revision });
    if (b.args) |args| run_stages.addArgs(args);
    const stages_step = b.step(
        "benchmark-stages",
        "Run the in-process stage benchmark over the corpus " ++
            "(writes benchmarks/results/stages.json)",
    );
    stages_step.dependOn(&run_stages.step);

    const run_browser = uv.run("docs/site", &.{
        "python",     "benchmarks/browser/run.py",
        "--version",  version,
        "--revision", revision,
        "--python",   "benchmarks/.venv-wheel/bin/python",
    });
    run_browser.step.dependOn(wasm_step);
    run_browser.step.dependOn(benchmark_python);
    const browser_step = b.step(
        "benchmark-wasm",
        "Run the parity-gated Chromium WebAssembly benchmark",
    );
    browser_step.dependOn(&run_browser.step);

    // `zig build benchmark-server`: the server lens (ZDS 0016). Starts
    // zenfmt open mode and a pinned Apache Tika Server over loopback and
    // writes benchmarks/results/server.json. Requires Java and the pinned
    // Tika distribution under benchmarks/.tika (see the book's server
    // chapter for the one-time fetch).
    const server_bench = b.addExecutable(.{
        .name = "zenfmt-benchmark-server",
        .root_module = b.createModule(.{
            .root_source_file = b.path("benchmarks/server.zig"),
            .target = target,
            .optimize = .ReleaseSafe,
        }),
    });
    const run_server = b.addRunArtifact(server_bench);
    run_server.has_side_effects = true;
    run_server.setCwd(b.path("."));
    run_server.addArg("--zenfmt");
    run_server.addArtifactArg(cli);
    run_server.addArgs(&.{ "--version", version, "--revision", revision });
    if (b.args) |args| run_server.addArgs(args);
    const server_step = b.step(
        "benchmark-server",
        "Run the server lens against Apache Tika over loopback " ++
            "(writes benchmarks/results/server.json; needs Java and " ++
            "benchmarks/.tika)",
    );
    server_step.dependOn(&run_server.step);

    const aggregate = uv.run("docs/site", &.{
        "python",     "benchmarks/browser/aggregate.py",
        "--version",  version,
        "--revision", revision,
    });
    aggregate.step.dependOn(&run_harness.step);
    aggregate.step.dependOn(&run_stages.step);
    aggregate.step.dependOn(&run_browser.step);
    aggregate.step.dependOn(&run_server.step);
    const release_step = b.step(
        "benchmark-release",
        "Regenerate native, Python, WASM, stage, server, and site records",
    );
    release_step.dependOn(&aggregate.step);
}
