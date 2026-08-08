//! The browser WebAssembly target (ZDS 0015).
//!
//! A second module graph at `wasm32-freestanding` over the same sources as
//! the native build. The CPU model is pinned to Zig's `generic` wasm32
//! feature set — no SIMD, no atomics — so the shipped module is the same
//! bytes on every builder and instantiates in every supported browser.
//!
//! The shipping optimization mode is `ReleaseSafe`, following ZDS 0002: the
//! released binary keeps its safety checks. The browser is the most hostile
//! input environment zenfmt has and WebAssembly has no stack guard page, so
//! trading a diagnosable refusal for silent corruption there would be the
//! wrong economy.

const std = @import("std");
const modules = @import("modules.zig");

/// Linear memory is capped so exhaustion becomes an allocation failure the
/// engine reports, rather than a tab the browser ends. The site recycles its
/// worker at half this, so a recycle always precedes a memory refusal.
const max_memory_bytes = 1024 * 1024 * 1024;
const initial_memory_bytes = 16 * 1024 * 1024;

/// WebAssembly has no guard page, and the engine's bounded validation frames
/// are sized to the depth hard cap. The auditor checks that this region sits
/// below the data segments, so an overflow traps instead of overwriting them.
const stack_bytes = 8 * 1024 * 1024;

pub const Steps = struct {
    build: *std.Build.Step,
    check: *std.Build.Step,
    capabilities: *std.Build.Step,
};

pub fn add(
    b: *std.Build,
    optimize: std.builtin.OptimizeMode,
    build_info: *std.Build.Module,
    test_step: *std.Build.Step,
) Steps {
    const target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
        .cpu_model = .{ .explicit = &std.Target.wasm.cpu.generic },
    });

    // A second graph at a second target. The names are not published: a
    // module name can be registered once, and the native graph owns them.
    const graph = modules.create(b, target, .ReleaseSafe, build_info, false);
    const shared = modules.createShared(
        b,
        target,
        .ReleaseSafe,
        graph.get("zenfmt_core"),
        false,
    );

    const release = artifact(b, "zenfmt", target, .ReleaseSafe, graph, shared, build_info, true);
    // A second, unstripped artifact for diagnosing a failure in the field
    // without shipping symbol names to every visitor.
    const debuggable = artifact(b, "zenfmt-debug", target, optimize, graph, shared, build_info, false);

    const install = b.addInstallFileWithDir(
        release.getEmittedBin(),
        .{ .custom = "wasm" },
        "zenfmt.wasm",
    );
    const install_debug = b.addInstallFileWithDir(
        debuggable.getEmittedBin(),
        .{ .custom = "wasm" },
        "zenfmt-debug.wasm",
    );

    const build_step = b.step(
        "wasm",
        "Build the browser module and distribution into zig-out/wasm",
    );
    build_step.dependOn(&install.step);
    build_step.dependOn(&install_debug.step);

    const check_step = b.step(
        "wasm-check",
        "Audit the module's imports and exports and run the ABI tests",
    );
    check_step.dependOn(build_step);
    check_step.dependOn(addAudit(b, release));
    check_step.dependOn(addDeclarationCheck(b, test_step));

    const capabilities_step = addCapabilities(b, build_info);

    // The binding's own tests run natively: the browser bundle is a host
    // variant, not a target, so its behaviour needs no runtime to check.
    const native_tests = b.addTest(.{
        .root_module = bindingModule(b, b.graph.host, .Debug, build_info),
    });
    test_step.dependOn(&b.addRunArtifact(native_tests).step);
    check_step.dependOn(test_step);

    return .{
        .build = build_step,
        .check = check_step,
        .capabilities = capabilities_step,
    };
}

fn artifact(
    b: *std.Build,
    name: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    graph: modules.Set,
    shared: modules.Shared,
    build_info: *std.Build.Module,
    strip: bool,
) *std.Build.Step.Compile {
    const root = b.createModule(.{
        .root_source_file = b.path("bindings/wasm/root.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
        .imports = &.{
            .{ .name = "zenfmt", .module = graph.umbrella },
            .{ .name = "zenfmt_core", .module = graph.get("zenfmt_core") },
            .{ .name = "zenfmt_build", .module = build_info },
            .{ .name = "zenfmt_capabilities", .module = shared.capabilities },
            .{ .name = "zenfmt_names", .module = shared.names },
        },
    });
    const module = b.addExecutable(.{ .name = name, .root_module = root });
    // No `_start`: the only way into this module is the ABI.
    module.entry = .disabled;
    module.rdynamic = true;
    module.export_memory = true;
    module.import_memory = false;
    module.export_table = false;
    module.shared_memory = false;
    module.initial_memory = initial_memory_bytes;
    module.max_memory = max_memory_bytes;
    module.stack_size = stack_bytes;
    return module;
}

/// The binding compiled for the host, so its tests are ordinary Zig tests.
fn bindingModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    build_info: *std.Build.Module,
) *std.Build.Module {
    const graph = modules.create(b, target, optimize, build_info, false);
    const shared = modules.createShared(b, target, optimize, graph.get("zenfmt_core"), false);
    return b.createModule(.{
        .root_source_file = b.path("bindings/wasm/abi.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zenfmt", .module = graph.umbrella },
            .{ .name = "zenfmt_core", .module = graph.get("zenfmt_core") },
            .{ .name = "zenfmt_build", .module = build_info },
            .{ .name = "zenfmt_capabilities", .module = shared.capabilities },
            .{ .name = "zenfmt_names", .module = shared.names },
        },
    });
}

/// Checks the adapter against its declarations. Structural, not semantic:
/// see `tools/dts_check.zig` for exactly what that buys and what it does not.
fn addDeclarationCheck(b: *std.Build, test_step: *std.Build.Step) *std.Build.Step {
    const exports_module = b.createModule(.{
        .root_source_file = b.path("bindings/wasm/exports.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    const root = b.createModule(.{
        .root_source_file = b.path("tools/dts_check.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
        .imports = &.{.{ .name = "zenfmt_wasm_exports", .module = exports_module }},
    });
    const tool = b.addExecutable(.{ .name = "dts-check", .root_module = root });

    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = root })).step);

    const run = b.addRunArtifact(tool);
    run.addFileArg(b.path("site/assets/js/zenfmt.js"));
    run.addFileArg(b.path("site/assets/js/zenfmt.d.ts"));
    return &run.step;
}

/// `zig build capabilities`: the one place the capability document is
/// produced. The homepage's format list, the accepted-extension hint, the
/// download page, and the book's format tables all read this file, so none of
/// them can quietly disagree with the engine (ZDS 0015).
fn addCapabilities(b: *std.Build, build_info: *std.Build.Module) *std.Build.Step {
    const host = b.graph.host;
    const graph = modules.create(b, host, .Debug, build_info, false);
    const shared = modules.createShared(b, host, .Debug, graph.get("zenfmt_core"), false);

    const tool = b.addExecutable(.{
        .name = "zenfmt-capabilities",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/capabilities.zig"),
            .target = host,
            .optimize = .Debug,
            .imports = &.{.{
                .name = "zenfmt_wasm_capabilities",
                .module = b.createModule(.{
                    .root_source_file = b.path("bindings/wasm/capabilities.zig"),
                    .target = host,
                    .optimize = .Debug,
                    .imports = &.{
                        .{ .name = "zenfmt", .module = graph.umbrella },
                        .{ .name = "zenfmt_core", .module = graph.get("zenfmt_core") },
                        .{ .name = "zenfmt_build", .module = build_info },
                        .{ .name = "zenfmt_capabilities", .module = shared.capabilities },
                    },
                }),
            }},
        }),
    });

    const run = b.addRunArtifact(tool);
    run.has_side_effects = true;
    run.setCwd(b.path("."));
    run.addArg("zig-out/share/zenfmt/capabilities.json");
    const step = b.step(
        "capabilities",
        "Write the capability document from the compiled default bundle",
    );
    step.dependOn(&run.step);
    return step;
}

/// The section auditor: a host tool that parses the produced module and
/// checks its import and export tables against the allowlists. A textual
/// dump is not the security boundary (ZDS 0015, Target decision).
fn addAudit(b: *std.Build, module: *std.Build.Step.Compile) *std.Build.Step {
    const tool = b.addExecutable(.{
        .name = "wasm-audit",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/wasm_audit.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
            .imports = &.{.{
                .name = "zenfmt_wasm_exports",
                .module = b.createModule(.{
                    .root_source_file = b.path("bindings/wasm/exports.zig"),
                    .target = b.graph.host,
                    .optimize = .Debug,
                }),
            }},
        }),
    });
    const run = b.addRunArtifact(tool);
    run.addFileArg(module.getEmittedBin());
    run.addArg("--max-memory-pages");
    run.addArg(b.fmt("{d}", .{max_memory_bytes / (64 * 1024)}));
    return &run.step;
}
