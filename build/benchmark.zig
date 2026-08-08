//! Benchmark harnesses (paxos-zig pattern): the cross-tool comparison, the
//! in-process stage split (ZDS 0013), and the dashboard aggregation that
//! feeds both the book's benchmark chapter and the site (ZDS 0015).
//!
//! Run `benchmarks/fetch_corpus.sh` once to populate `benchmarks/corpus`.

const std = @import("std");

pub fn add(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    cli: *std.Build.Step.Compile,
    umbrella: *std.Build.Module,
    core: *std.Build.Module,
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
    // The installed-wheel environment and its detailed suite run first so the
    // harness's cold `zenfmt-python-wheel` row uses the same wheel.
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
                .{ .name = "zenfmt", .module = umbrella },
                .{ .name = "zenfmt_core", .module = core },
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
