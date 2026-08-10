//! Assembling and checking the deployable site (ZDS 0015).
//!
//! The assembler is a uv-managed Python project with no runtime dependencies.
//! `zig build site` owns the graph: it builds the WebAssembly module, the
//! capability document, and the Typst HTML first, then hands the assembler an
//! explicit set of inputs and one output directory.

const std = @import("std");
const python = @import("python.zig");

const project = "docs/site";

pub fn add(
    b: *std.Build,
    test_step: *std.Build.Step,
    uv: python.Uv,
    version: []const u8,
    wasm_step: *std.Build.Step,
    capabilities_step: *std.Build.Step,
    docs_step: *std.Build.Step,
) void {
    const base = b.option(
        []const u8,
        "site-base",
        "Deployment path prefix for the generated site (default \"/\")",
    ) orelse "/";
    const out = b.option(
        []const u8,
        "site-out",
        "Directory the assembled site is written to",
    ) orelse "zig-out/site";

    const build_site = uv.run(project, &.{
        "python", "-m", "zenfmt_site", "build",
        "--root", ".",  "--out",       out,
        "--base", base, "--version",   version,
    });
    build_site.step.dependOn(wasm_step);
    build_site.step.dependOn(capabilities_step);
    build_site.step.dependOn(docs_step);

    const site_step = b.step(
        "site",
        "Assemble the deployable site into zig-out/site",
    );
    site_step.dependOn(&build_site.step);

    // Reproducibility is asserted rather than assumed: the site is built a
    // second time into a separate directory and the two are compared. A
    // generator that quietly embeds a timestamp or iterates a set would pass
    // every other check and fail this one.
    const second = uv.run(project, &.{
        "python", "-m", "zenfmt_site", "build",
        "--root", ".",  "--out",       "zig-out/site-repeat",
        "--base", base, "--version",   version,
    });
    second.step.dependOn(&build_site.step);

    const compare = b.addSystemCommand(&.{
        "diff", "-r", out, "zig-out/site-repeat",
    });
    compare.setCwd(b.path("."));
    compare.has_side_effects = true;
    compare.step.dependOn(&second.step);

    const validate = uv.run(project, &.{
        "python", "-m", "zenfmt_site", "check", "--dir", out,
    });
    validate.step.dependOn(&compare.step);

    const check_step = b.step(
        "site-check",
        "Assemble the site twice, prove the two agree, and validate the result",
    );
    check_step.dependOn(&validate.step);

    const serve = uv.run(project, &.{
        "python", "-m", "zenfmt_site", "serve", "--dir", out,
    });
    serve.step.dependOn(site_step);
    const serve_step = b.step(
        "site-serve",
        "Serve the assembled site on localhost with the correct WASM type",
    );
    serve_step.dependOn(&serve.step);

    // The assembler's own unit tests need no built site and no browser, so
    // they belong in the ordinary test suite.
    const unit = uv.run(project, &.{ "pytest", "docs/site/tests" });
    const unit_step = b.step("site-test", "Run the site assembler's unit tests");
    unit_step.dependOn(&unit.step);
    test_step.dependOn(unit_step);

    const browser = uv.run(project, &.{ "pytest", "tests/site/browser" });
    browser.step.dependOn(&build_site.step);
    const browser_step = b.step(
        "site-browser-test",
        "Run the Chromium interaction suite against the assembled site",
    );
    browser_step.dependOn(&browser.step);
}

/// Ruff over the site tooling, kept separate from the library's Ruff run
/// because the two are different uv projects with different configuration.
pub fn addFormatting(
    b: *std.Build,
    uv: python.Uv,
    check_step: *std.Build.Step,
    apply_step: *std.Build.Step,
) void {
    const lint = uv.run(project, &.{
        "ruff",                      "check",
        "docs/site",                 "tests/site",
        "server/tests",              "benchmarks/browser",
        "tools/release_manifest.py", "tools/release_sbom.py",
    });
    const format_check = uv.run(project, &.{
        "ruff",               "format",                    "--check",
        "docs/site",          "tests/site",                "server/tests",
        "benchmarks/browser", "tools/release_manifest.py", "tools/release_sbom.py",
    });
    check_step.dependOn(&lint.step);
    check_step.dependOn(&format_check.step);

    const format = uv.run(project, &.{
        "ruff",                      "format",
        "docs/site",                 "tests/site",
        "server/tests",              "benchmarks/browser",
        "tools/release_manifest.py", "tools/release_sbom.py",
    });
    apply_step.dependOn(&format.step);
    _ = b;
}
