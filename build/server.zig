//! Server build graph (ZDS 0016): the zenserve kernel library, the
//! `zenfmt_server` application module, and their steps.
//!
//! Gated by `-Dserver` (default true): the false build produces the pure
//! converter binary with no serve subcommand, no HTTP code, and (once
//! secure mode lands) no zaxonlite link.

const std = @import("std");

const python = @import("python.zig");

pub const Modules = struct {
    zenserve: *std.Build.Module,
    server: *std.Build.Module,
    ui_wasm: *std.Build.Step.Compile,
};

/// The interface module's size budget (ZDS 0016): 300 KiB compiled.
pub const ui_wasm_budget_bytes: u64 = 300 * 1024;

/// Creates the zenserve and zenfmt_server modules. Returns null when the
/// server is compiled out.
pub fn create(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    enabled: bool,
    umbrella: *std.Build.Module,
    core: *std.Build.Module,
    capabilities: *std.Build.Module,
    build_info: *std.Build.Module,
    zencli: *std.Build.Module,
) ?Modules {
    if (!enabled) return null;

    // The one new package dependency (ZDS 0016): embedded replicated
    // SQLite, consumed single-node with the TLS transport compiled out so
    // the build carries no OpenSSL surface.
    const zaxonlite = b.dependency("zaxonlite", .{
        .target = target,
        .optimize = optimize,
        .tls = false,
    }).module("zaxonlite");

    const zenserve = b.addModule("zenserve", .{
        .root_source_file = b.path("server/zenserve/src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // The interface module: wasm32-freestanding at ReleaseSmall, mirroring
    // the browser module's target conventions (build/wasm.zig) while
    // sharing no code with it. The compiled bytes embed into the server.
    const ui_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
        .cpu_model = .{ .explicit = &std.Target.wasm.cpu.generic },
    });
    const ui_module = b.createModule(.{
        .root_source_file = b.path("server/ui/src/main.zig"),
        .target = ui_target,
        .optimize = .ReleaseSmall,
        .strip = true,
    });
    const ui_wasm = b.addExecutable(.{
        .name = "zenfmt-server-ui",
        .root_module = ui_module,
    });
    // No `_start`: the only way into this module is the ABI.
    ui_wasm.entry = .disabled;
    ui_wasm.rdynamic = true;
    ui_wasm.export_memory = true;
    ui_wasm.import_memory = false;
    ui_wasm.export_table = false;
    ui_wasm.shared_memory = false;
    ui_wasm.initial_memory = 2 * 1024 * 1024;
    ui_wasm.max_memory = 64 * 1024 * 1024;
    ui_wasm.stack_size = 1024 * 1024;

    const server = b.addModule("zenfmt_server", .{
        .root_source_file = b.path("server/src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zenfmt", .module = umbrella },
            .{ .name = "zenfmt_core", .module = core },
            .{ .name = "zenfmt_capabilities", .module = capabilities },
            .{ .name = "zenfmt_build", .module = build_info },
            .{ .name = "zencli", .module = zencli },
            .{ .name = "zenserve", .module = zenserve },
            .{ .name = "zaxonlite", .module = zaxonlite },
        },
    });

    server.addAnonymousImport("ui_shell", .{
        .root_source_file = b.path("server/ui/shell/index.html"),
    });
    server.addAnonymousImport("ui_glue", .{
        .root_source_file = b.path("server/ui/glue/ui.js"),
    });
    server.addAnonymousImport("ui_css_vendor", .{
        .root_source_file = b.path("server/ui/assets/daisyui-5.0.45.css"),
    });
    server.addAnonymousImport("ui_css", .{
        .root_source_file = b.path("server/ui/assets/layout.css"),
    });
    server.addAnonymousImport("ui_wasm", .{
        .root_source_file = ui_wasm.getEmittedBin(),
    });
    server.addAnonymousImport("openapi_json", .{
        .root_source_file = b.path("server/openapi.json"),
    });

    return .{ .zenserve = zenserve, .server = server, .ui_wasm = ui_wasm };
}

/// Wires the server steps: `zig build serve`, `zig build server-test`.
pub fn addSteps(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    test_step: *std.Build.Step,
    server_modules: ?Modules,
    cli: *std.Build.Step.Compile,
    umbrella: *std.Build.Module,
    core: *std.Build.Module,
    uv: python.Uv,
) void {
    const serve_step = b.step(
        "serve",
        "Build and run the zenfmt server: zig build serve -- --port 9000",
    );
    const modules = server_modules orelse {
        serve_step.dependOn(&b.addFail(
            "zig build serve requires -Dserver=true",
        ).step);
        return;
    };

    const run_serve = b.addRunArtifact(cli);
    run_serve.addArg("serve");
    if (b.args) |args| run_serve.addArgs(args);
    serve_step.dependOn(&run_serve.step);

    const server_test_step = b.step(
        "server-test",
        "Run the zenserve and server unit tests plus the loopback suite",
    );
    const zenserve_tests = b.addTest(.{ .root_module = modules.zenserve });
    server_test_step.dependOn(&b.addRunArtifact(zenserve_tests).step);
    const server_tests = b.addTest(.{ .root_module = modules.server });
    server_test_step.dependOn(&b.addRunArtifact(server_tests).step);

    // The ui module's golden tests run natively: no browser, no wasm.
    const ui_native = b.createModule(.{
        .root_source_file = b.path("server/ui/src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    const ui_tests = b.addTest(.{ .root_module = ui_native });
    server_test_step.dependOn(&b.addRunArtifact(ui_tests).step);

    // `zig build server-ui`: compile the interface module and hold it to
    // the record's size budget.
    const size_check = b.addExecutable(.{
        .name = "size-check",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/size_check.zig"),
            .target = target,
            .optimize = .Debug,
        }),
    });
    const run_size_check = b.addRunArtifact(size_check);
    run_size_check.addFileArg(modules.ui_wasm.getEmittedBin());
    run_size_check.addArg(b.fmt("{d}", .{ui_wasm_budget_bytes}));
    const ui_step = b.step(
        "server-ui",
        "Compile the interface wasm module and check its size budget",
    );
    const install_ui = b.addInstallFileWithDir(
        modules.ui_wasm.getEmittedBin(),
        .{ .custom = "wasm" },
        "zenfmt-server-ui.wasm",
    );
    ui_step.dependOn(&install_ui.step);
    ui_step.dependOn(&run_size_check.step);
    server_test_step.dependOn(&run_size_check.step);

    const e2e = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("server/tests/e2e.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zenfmt", .module = umbrella },
                .{ .name = "zenfmt_core", .module = core },
                .{ .name = "zenfmt_server", .module = modules.server },
                .{ .name = "zenserve", .module = modules.zenserve },
            },
        }),
    });
    server_test_step.dependOn(&b.addRunArtifact(e2e).step);

    test_step.dependOn(server_test_step);

    // The interface smoke test drives the real server with a real browser,
    // through the same uv-managed Playwright harness the site tests use.
    const browser = uv.run("docs/site", &.{ "pytest", "server/tests/browser" });
    browser.step.dependOn(b.getInstallStep());
    const browser_step = b.step(
        "server-browser-test",
        "Run the Chromium interface smoke test against a live server",
    );
    browser_step.dependOn(&browser.step);
}
