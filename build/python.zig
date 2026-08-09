//! The Python bridge artifact and the uv-orchestrated Python workflows
//! (ZDS 0014).
//!
//! uv owns the Python environment, lockfile, and command execution; a missing
//! uv is a clear prerequisite failure, never a silent skip. Two uv projects
//! exist: `python/` publishes the library, and `docs/site/` holds the site
//! tooling (ZDS 0015). They are separate so the site's development
//! dependencies never enter the published distribution, which is why every
//! command names its project explicitly.

const std = @import("std");
const modules = @import("modules.zig");

pub const Steps = struct {
    lint: *std.Build.Step,
    format_check: *std.Build.Step,
    benchmark_python: *std.Build.Step,
    /// Runs uv commands for any project in the repository.
    uv: Uv,
};

/// Issues `uv` commands from the repository root. Holding the "uv is
/// missing" failure step here means each call site does not repeat the
/// prerequisite check, and the project directory is a parameter rather than a
/// literal so `docs/site` can use the same runner.
pub const Uv = struct {
    b: *std.Build,
    missing: ?*std.Build.Step,

    pub fn init(b: *std.Build) Uv {
        const missing: ?*std.Build.Step = blk: {
            _ = b.findProgram(&.{"uv"}, &.{}) catch {
                const fail = b.addFail(
                    "uv is required for the Python steps: install it from " ++
                        "https://docs.astral.sh/uv/ and re-run",
                );
                break :blk &fail.step;
            };
            break :blk null;
        };
        return .{ .b = b, .missing = missing };
    }

    /// A raw uv invocation, for commands such as `uv build` and `uv venv`
    /// that do not take `--project`.
    pub fn command(uv: Uv, argv: []const []const u8) *std.Build.Step.Run {
        const step = uv.b.addSystemCommand(argv);
        step.has_side_effects = true;
        step.setCwd(uv.b.path("."));
        if (uv.missing) |fail| step.step.dependOn(fail);
        return step;
    }

    /// `uv run --project <project> --locked <argv...>`.
    pub fn run(
        uv: Uv,
        project: []const u8,
        argv: []const []const u8,
    ) *std.Build.Step.Run {
        var full = std.ArrayList([]const u8).empty;
        full.appendSlice(uv.b.allocator, &.{
            "uv", "run", "--project", project, "--locked",
        }) catch @panic("OOM");
        full.appendSlice(uv.b.allocator, argv) catch @panic("OOM");
        return uv.command(full.items);
    }
};

/// The private C ABI shared library consumed by the `zenfmt` Python package.
/// `zig build python-native` installs it into `<prefix>/lib` under its
/// canonical per-platform name; the standard `--prefix` flag redirects output
/// for cross-compiled wheel builds.
pub fn addBridge(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    test_step: *std.Build.Step,
    build_info: *std.Build.Module,
    umbrella: *std.Build.Module,
    core: *std.Build.Module,
    shared: modules.Shared,
) *std.Build.Step.Compile {
    const bridge_module = b.createModule(.{
        .root_source_file = b.path("bindings/python/abi.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "zenfmt", .module = umbrella },
            .{ .name = "zenfmt_core", .module = core },
            .{ .name = "zenfmt_build", .module = build_info },
            .{ .name = "zenfmt_capabilities", .module = shared.capabilities },
            .{ .name = "zenfmt_names", .module = shared.names },
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

pub fn addWorkflows(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    test_step: *std.Build.Step,
    bridge: *std.Build.Step.Compile,
    cli: *std.Build.Step.Compile,
    revision: []const u8,
) Steps {
    // The host bridge staged into the source-layout package's private
    // resource directory: the editable install exposes exactly that location
    // as the package resource root, so development and wheels share one
    // loader rule.
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

    const uv = Uv.init(b);

    // The package version comes from the repository's build.zig.zon, outside
    // the uv project directory. Reinstall the editable package so a release
    // version bump cannot leave stale distribution metadata in the venv.
    const sync = uv.command(&.{
        "uv",        "sync",
        "--project", "python",
        "--locked",  "--reinstall-package",
        "zenfmt",
    });
    sync.step.dependOn(&stage.step);
    const sync_step = b.step(
        "python-sync",
        "Build and stage the host bridge, then sync the locked Python " ++
            "development environment",
    );
    sync_step.dependOn(&sync.step);

    const pytest = uv.run("python", &.{
        "pytest", "-m", "not release", "python/tests",
    });
    pytest.step.dependOn(&sync.step);
    const pytest_step = b.step(
        "python-test",
        "Build and stage the host bridge, then run pytest through uv",
    );
    pytest_step.dependOn(&pytest.step);
    test_step.dependOn(pytest_step);

    const lint = uv.run("python", &.{ "ruff", "check", "python" });
    const lint_step = b.step("python-lint", "Run ruff check through uv");
    lint_step.dependOn(&lint.step);

    const format = uv.run("python", &.{ "ruff", "format", "python" });
    const format_step = b.step(
        "python-format",
        "Run the Ruff formatter in write mode",
    );
    format_step.dependOn(&format.step);

    const format_check = uv.run("python", &.{
        "ruff", "format", "--check", "python",
    });
    const format_check_step = b.step(
        "python-format-check",
        "Check Ruff formatting without edits",
    );
    format_check_step.dependOn(&format_check.step);

    // `python-wheel`: the host platform wheel through uv; the Hatchling hook
    // invokes `zig build python-native` itself for a ReleaseSafe bridge and
    // sets the platform tag.
    const wheel = uv.command(&.{
        "uv",        "build",               "--wheel",
        "--out-dir", "zig-out/python/dist", "python",
    });
    const wheel_step = b.step(
        "python-wheel",
        "Build the host platform wheel into zig-out/python/dist",
    );
    wheel_step.dependOn(&wheel.step);

    // `python-check`: the release-gate aggregate (ZDS 0014): lint, format
    // check, the full pytest suite with every format required, a wheel and
    // source distribution, and the installed-artifact release tests.
    const strict_pytest = uv.run("python", &.{
        "pytest", "-m", "not release", "python/tests",
    });
    strict_pytest.step.dependOn(&sync.step);
    strict_pytest.setEnvironmentVariable("ZENFMT_REQUIRE_ALL_FORMATS", "1");

    const sdist = uv.command(&.{
        "uv",        "build",               "--sdist",
        "--out-dir", "zig-out/python/dist", "python",
    });

    const release_tests = uv.run("python", &.{
        "pytest", "-m", "release", "python/tests/release",
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

    // `benchmark-python` (ZDS 0014): a clean isolated environment holding the
    // exact just-built wheel, then the installed-wheel profile suite with
    // parity checks. `zig build benchmark` depends on this step so its cold
    // row runs against the same environment.
    const venv = uv.command(&.{ "uv", "venv", "--clear", "benchmarks/.venv-wheel" });
    venv.step.dependOn(&wheel.step);
    const wheel_install = uv.command(&.{
        "uv",                     "pip",
        "install",                "--python",
        "benchmarks/.venv-wheel", "--no-index",
        "--find-links",           "zig-out/python/dist",
        "--reinstall",            "zenfmt",
    });
    wheel_install.step.dependOn(&venv.step);
    const suite = uv.command(&.{
        "benchmarks/.venv-wheel/bin/python", "-I",
        "python/benchmarks/python_api.py",   "--suite",
        "--revision",                        revision,
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
        .uv = uv,
    };
}
