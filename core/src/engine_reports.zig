//! The engine's diagnostic catalog (ZDS 0002, Diagnostics): the reports
//! `zenfmt_core` itself can emit — format resolution, limits, manifests,
//! commit failures — each answering the four questions.

const std = @import("std");
const root = @import("root.zig");
const report = @import("report.zig");
const plugin = @import("plugin.zig");

const Reports = report.Reports;
const Report = report.Report;
const Limits = @import("limits.zig").Limits;
const ResolvedInput = root.ResolvedInput;
const ConvertOptions = root.ConvertOptions;
const closestFormat = root.closestFormat;

pub const FormatRole = enum { input, output };

pub fn reportUnknownFormat(
    arena: std.mem.Allocator,
    reports: *Reports,
    name: []const u8,
    role: FormatRole,
    known: []const []const u8,
    input: ResolvedInput,
) error{OutOfMemory}!void {
    const role_name = switch (role) {
        .input => "input",
        .output => "output",
    };
    const problem = if (closestFormat(name, known)) |suggestion|
        try std.fmt.allocPrint(
            arena,
            "I do not recognize `{s}` as an {s} format. Did you mean `{s}`?",
            .{ name, role_name, suggestion },
        )
    else
        try std.fmt.allocPrint(
            arena,
            "I do not recognize `{s}` as an {s} format.",
            .{ name, role_name },
        );

    const listed = try std.mem.join(arena, "   ", known);
    const consequence = try std.fmt.allocPrint(
        arena,
        "No output file was created. These are the {s} formats I know: {s}",
        .{ role_name, listed },
    );

    const flag = switch (role) {
        .input => "--from",
        .output => "--to",
    };
    const suggested = closestFormat(name, known) orelse known[0];
    // Runtime-assembled argv vectors must outlive this function: the report
    // renders after the conversion returns, so they live in the arena.
    const command = try arena.dupe([]const u8, &.{ "zenfmt", flag, suggested, input.name });
    try reports.add(.{
        .severity = .err,
        .code = if (role == .input) "core.unknown-input-format" else "core.unknown-output-format",
        .title = if (role == .input) "UNKNOWN INPUT FORMAT" else "UNKNOWN OUTPUT FORMAT",
        .problem = problem,
        .consequence = consequence,
        .exit_class = .usage,
        .directions = try directionsSlice(arena, .{
            .title = "Select the intended format explicitly",
            .explanation = "Select the intended format explicitly:",
            .command = command,
        }),
    });
}

pub fn reportUndetectable(
    arena: std.mem.Allocator,
    reports: *Reports,
    input: ResolvedInput,
    known: []const []const u8,
) error{OutOfMemory}!void {
    const listed = try std.mem.join(arena, "   ", known);
    try reports.add(.{
        .severity = .err,
        .code = "core.undetectable-input-format",
        .title = "CANNOT DETECT INPUT FORMAT",
        .problem = try std.fmt.allocPrint(
            arena,
            "I cannot tell what format `{s}` is: its extension is not one " ++
                "I know and its content matches no signature I recognize. " ++
                "I never guess, because converting a misdetected binary " ++
                "produces baffling output.",
            .{input.name},
        ),
        .consequence = try std.fmt.allocPrint(
            arena,
            "No output file was created. These are the input formats I " ++
                "know: {s}",
            .{listed},
        ),
        .exit_class = .usage,
        .directions = try directionsSlice(arena, .{
            .title = "Name the format explicitly",
            .explanation = "Name the input format explicitly:",
            .command = try arena.dupe([]const u8, &.{
                "zenfmt", "--from", known[0], input.name,
            }),
        }),
    });
}

pub fn directionsSlice(
    arena: std.mem.Allocator,
    direction: report.Direction,
) error{OutOfMemory}![]const report.Direction {
    const slice = try arena.alloc(report.Direction, 1);
    slice[0] = direction;
    return slice;
}

pub fn inputTooLarge(name: []const u8, limit_values: Limits) Report {
    _ = name;
    _ = limit_values;
    return .{
        .severity = .err,
        .code = "core.input-too-large",
        .title = "INPUT EXCEEDS THE SIZE LIMIT",
        .problem = "This input is larger than the maximum input size limit.",
        .consequence = "The conversion stopped before reading the whole " ++
            "input, and no output file was created.",
        .exit_class = .limit,
        .directions = &.{.{
            .title = "Raise the limit if the input is trusted",
            .explanation = "If the file is a legitimate document from a " ++
                "trusted source, raise only this limit for this run with " ++
                "--limit max_input_bytes=<bytes>. A larger limit permits " ++
                "proportionally more memory use.",
        }},
    };
}

pub fn staleManifest(manifest_path: []const u8, input_path: []const u8) Report {
    _ = input_path;
    return .{
        .severity = .warning,
        .code = "core.stale-or-invalid-manifest",
        .title = "STALE OR INVALID MANIFEST",
        .problem = "There is a zenfmt manifest beside this input, but it " ++
            "does not match: it is malformed, from an incompatible " ++
            "version, or its digest does not match the input bytes.",
        .consequence = "The conversion continued without preservation " ++
            "data; nothing from the manifest was trusted or applied.",
        .context = .{ .path = .{
            .path = manifest_path,
            .operation = "verify the adjacent manifest",
        } },
        .directions = &.{.{
            .title = "Regenerate or remove the sidecar",
            .explanation = "Regenerate the artifact from its original " ++
                "source to refresh the manifest, or delete the stale " ++
                ".zenfmt.json file if the artifact was intentionally " ++
                "edited by hand.",
        }},
    };
}

pub fn invalidTreeReport(origin: []const u8) Report {
    _ = origin;
    return .{
        .severity = .err,
        .code = "core.invalid-document-tree",
        .title = "PLUGIN PRODUCED AN INVALID TREE",
        .problem = "The reader produced a document tree that violates a " ++
            "structural invariant. This is a bug in the plugin, not in " ++
            "your document.",
        .consequence = "The conversion stopped and no output file was " ++
            "created.",
        .directions = &.{.{
            .title = "Report this",
            .explanation = "Keep the input file and report this with the " ++
                "zenfmt version and the input that triggered it; the " ++
                "validator caught it before any output was written.",
        }},
    };
}

pub fn strictReport(input_name: []const u8) Report {
    _ = input_name;
    return .{
        .severity = .err,
        .code = "core.strict-warnings",
        .title = "STOPPED ON WARNINGS",
        .problem = "The conversion produced warnings and --strict is set.",
        .consequence = "No output file was committed. The warnings above " ++
            "describe exactly what would have been lost or changed.",
        .directions = &.{.{
            .title = "Review the warnings",
            .explanation = "Review each warning above. Run without " ++
                "--strict to accept the stated losses, or fix the source " ++
                "so the warnings disappear.",
        }},
    };
}

pub fn pathFailure(
    arena: std.mem.Allocator,
    operation: []const u8,
    path: []const u8,
    err: anyerror,
) error{OutOfMemory}!Report {
    return .{
        .severity = .err,
        .code = "core.file-operation-failed",
        .title = "A FILE OPERATION FAILED",
        .problem = try std.fmt.allocPrint(
            arena,
            "I could not {s}: the operating system reported `{s}`.",
            .{ operation, @errorName(err) },
        ),
        .consequence = "The conversion stopped. No partial output was " ++
            "left behind: outputs are written to a temporary file and " ++
            "renamed only on success.",
        .context = .{ .path = .{ .path = path, .operation = operation } },
        .directions = &.{.{
            .title = "Check the path and permissions",
            .explanation = "Check that the path exists, that you can " ++
                "write to its directory, and that the disk is not full, " ++
                "then run the same command again.",
        }},
    };
}

pub fn commitFailure(
    arena: std.mem.Allocator,
    path: []const u8,
    input: ResolvedInput,
    options: ConvertOptions,
    err: anyerror,
) error{OutOfMemory}!Report {
    if (err == error.PathAlreadyExists) {
        const output_path = switch (options.output) {
            .path => |p| p,
            .writer => path,
        };
        return .{
            .severity = .err,
            .code = "core.destination-exists",
            .title = "THE DESTINATION ALREADY EXISTS",
            .problem = try std.fmt.allocPrint(
                arena,
                "`{s}` already exists, and I do not replace files unless " ++
                    "asked to.",
                .{path},
            ),
            .consequence = "The existing file is untouched and the new " ++
                "conversion was discarded.",
            .context = .{ .path = .{ .path = path, .operation = "commit the output" } },
            .directions = try directionsSlice(arena, .{
                .title = "Replace it deliberately",
                .explanation = "Re-run with --overwrite to replace the " ++
                    "existing artifact and its manifest:",
                .command = try arena.dupe([]const u8, &.{
                    "zenfmt", "--overwrite", input.name, "-o", output_path,
                }),
            }),
        };
    }
    return pathFailure(arena, "commit the output", path, err);
}

pub fn ensureFailureReported(
    arena: std.mem.Allocator,
    reports: *Reports,
    err: plugin.ReadError,
    input: ResolvedInput,
) error{OutOfMemory}!void {
    _ = arena;
    if (reports.hasErrors()) return;
    // The reader failed without reporting specifics: still give the user
    // the four answers, generically. The plugin's own tests should catch
    // this path.
    try reports.add(.{
        .severity = .err,
        .code = switch (err) {
            error.Malformed => "core.malformed-input",
            error.DepthLimitExceeded => "core.depth-limit-exceeded",
            error.LimitExceeded => "core.limit-exceeded",
            error.OutOfMemory => unreachable,
        },
        .title = switch (err) {
            error.Malformed => "MALFORMED INPUT",
            error.DepthLimitExceeded => "INPUT NESTS TOO DEEPLY",
            error.LimitExceeded => "A RESOURCE LIMIT WAS HIT",
            error.OutOfMemory => unreachable,
        },
        .problem = "The input could not be read as its declared format.",
        .consequence = "The conversion stopped and no output file was " ++
            "created.",
        .context = .{ .path = .{ .path = input.name, .operation = "read the input" } },
        .exit_class = if (err == error.LimitExceeded) .limit else .conversion,
        .directions = &.{.{
            .title = "Verify the input",
            .explanation = "Open the file in its native application to " ++
                "verify it is intact, and check that the detected format " ++
                "matches what the file actually is (use --from to select " ++
                "it explicitly).",
        }},
    });
}
