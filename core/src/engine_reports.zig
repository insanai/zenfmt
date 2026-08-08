//! The engine's diagnostic catalog (ZDS 0002, Diagnostics): the reports
//! `zenfmt_core` itself can emit — format resolution, limits, manifests,
//! commit failures. The four-part structure is only the floor: every
//! warning and refusal also gives a concrete action that can be taken with
//! the information present in the report.

const std = @import("std");
const root = @import("root.zig");
const report = @import("report.zig");
const plugin = @import("plugin.zig");
const lowering = @import("lowering.zig");
const adjacent_manifest = @import("adjacent_manifest.zig");

const Reports = report.Reports;
const Report = report.Report;
const limits_mod = @import("limits.zig");
const Limits = limits_mod.Limits;
const ResolvedInput = root.ResolvedInput;
const ConvertOptions = root.ConvertOptions;
const closestFormat = @import("format_suggestion.zig").closest;

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

pub fn inputTooLarge(
    arena: std.mem.Allocator,
    name: []const u8,
    size: u64,
    limit_values: Limits,
) error{OutOfMemory}!Report {
    return .{
        .severity = .err,
        .code = "core.input-too-large",
        .title = "INPUT EXCEEDS THE SIZE LIMIT",
        .problem = try std.fmt.allocPrint(
            arena,
            "`{s}` is {d} bytes, which exceeds max_input_bytes ({d}).",
            .{ name, size, limit_values.max_input_bytes },
        ),
        .consequence = "The conversion stopped before reading the whole " ++
            "input, and no output file was created.",
        .context = .{ .path = .{
            .path = name,
            .operation = "check the input size",
        } },
        .exit_class = .limit,
        .directions = try directionsSlice(arena, .{
            .title = "Raise the limit if the input is trusted",
            .explanation = try std.fmt.allocPrint(
                arena,
                "If the file is trusted, retry with --limit " ++
                    "max_input_bytes={d} or a larger exact byte count. " ++
                    "The converter may then read and allocate up to that " ++
                    "amount; otherwise split or shrink the source.",
                .{size},
            ),
        }),
    };
}

pub fn outputTooLarge(
    arena: std.mem.Allocator,
    artifact_name: []const u8,
    limit_values: Limits,
) error{OutOfMemory}!Report {
    return .{
        .severity = .err,
        .code = "core.output-too-large",
        .title = "OUTPUT EXCEEDS THE SIZE LIMIT",
        .problem = try std.fmt.allocPrint(
            arena,
            "Emitting `{s}` reached max_output_bytes ({d}) before the " ++
                "writer finished.",
            .{ artifact_name, limit_values.max_output_bytes },
        ),
        .consequence = "The conversion stopped before accepting another " ++
            "output byte, and no artifact or manifest was published.",
        .context = .{ .path = .{
            .path = artifact_name,
            .operation = "write the converted artifact",
        } },
        .exit_class = .limit,
        .directions = try directionsSlice(arena, .{
            .title = "Raise the limit if the output size is expected",
            .explanation = try std.fmt.allocPrint(
                arena,
                "If an artifact this large is expected, retry with --limit " ++
                    "max_output_bytes={d} or a larger exact byte count. The " ++
                    "converter may then hold or write up to that amount; " ++
                    "otherwise split or shrink the source document.",
                .{limit_values.max_output_bytes * 2},
            ),
        }),
    };
}

pub fn invalidLimitConfiguration(
    arena: std.mem.Allocator,
    name: []const u8,
    value: u64,
) error{OutOfMemory}!Report {
    const field = std.meta.stringToEnum(Limits.Field, name) orelse unreachable;
    const correction = if (value == 0)
        try std.fmt.allocPrint(
            arena,
            "Set ConvertOptions.limits.{s} to at least 1.",
            .{name},
        )
    else if (Limits.hardCap(field)) |cap|
        try std.fmt.allocPrint(
            arena,
            "Set ConvertOptions.limits.{s} to a value from 1 through {d}; " ++
                "larger values cannot fit the engine's bounded state.",
            .{ name, cap },
        )
    else
        unreachable;
    return .{
        .severity = .err,
        .code = "core.invalid-limit-configuration",
        .title = "INVALID RESOURCE LIMIT",
        .problem = try std.fmt.allocPrint(
            arena,
            "The programmatic limit `{s}` has the unsupported value {d}.",
            .{ name, value },
        ),
        .consequence = "The conversion did not read the input or open an " ++
            "output. No attacker-controlled allocation used this value.",
        .exit_class = .limit,
        .directions = try directionsSlice(arena, .{
            .title = "Correct this limit before converting",
            .explanation = correction,
        }),
    };
}

pub fn staleManifest(
    arena: std.mem.Allocator,
    invalid: adjacent_manifest.Invalid,
    input_path: []const u8,
) error{OutOfMemory}!Report {
    const problem = switch (invalid.reason) {
        .read_failed => |err| try std.fmt.allocPrint(
            arena,
            "I could not read `{s}` while checking `{s}` ({s}).",
            .{ invalid.path, input_path, @errorName(err) },
        ),
        .too_large => |limit| try std.fmt.allocPrint(
            arena,
            "`{s}` reaches max_manifest_bytes ({d}) while checking `{s}`.",
            .{ invalid.path, limit, input_path },
        ),
        .invalid_data => try std.fmt.allocPrint(
            arena,
            "`{s}` is not a valid supported zenfmt manifest for `{s}`.",
            .{ invalid.path, input_path },
        ),
        .digest_mismatch => try std.fmt.allocPrint(
            arena,
            "`{s}` records a digest that does not match the current " ++
                "bytes of `{s}`.",
            .{ invalid.path, input_path },
        ),
    };
    return .{
        .severity = .warning,
        .code = "core.stale-or-invalid-manifest",
        .title = "STALE OR INVALID MANIFEST",
        .problem = problem,
        .consequence = "The conversion continued without preservation " ++
            "data; nothing from the manifest was trusted or applied.",
        .context = .{ .path = .{
            .path = invalid.path,
            .operation = "verify the adjacent manifest",
        } },
        .directions = try directionsSlice(
            arena,
            try staleManifestDirection(arena, invalid.reason),
        ),
    };
}

fn staleManifestDirection(
    arena: std.mem.Allocator,
    reason: adjacent_manifest.Reason,
) error{OutOfMemory}!report.Direction {
    return switch (reason) {
        .read_failed => .{
            .title = "Make the sidecar readable or remove it",
            .explanation = "Correct the sidecar's ownership and read " ++
                "permissions. If it is no longer authoritative, remove it " ++
                "and regenerate the artifact from the original source.",
        },
        .too_large => |limit| try largeManifestDirection(arena, limit),
        .invalid_data => .{
            .title = "Replace the invalid sidecar",
            .explanation = "Remove this sidecar and convert again from the " ++
                "original source so zenfmt writes the supported schema.",
        },
        .digest_mismatch => .{
            .title = "Regenerate or remove the stale sidecar",
            .explanation = "Convert again from the original source to " ++
                "refresh both bytes and digest, or remove the sidecar if " ++
                "the artifact was intentionally edited by hand.",
        },
    };
}

fn largeManifestDirection(
    arena: std.mem.Allocator,
    limit: u32,
) error{OutOfMemory}!report.Direction {
    if (limit == std.math.maxInt(u32)) return .{
        .title = "Replace or remove the oversized sidecar",
        .explanation = "This sidecar exceeds the largest supported manifest " ++
            "limit. Remove it and convert from the original source, or " ++
            "produce a smaller manifest with only required preservation data.",
    };
    const doubled = @as(u64, limit) * 2;
    const suggested = @min(doubled, std.math.maxInt(u32));
    return .{
        .title = "Raise only the manifest limit or remove the sidecar",
        .explanation = try std.fmt.allocPrint(
            arena,
            "If this sidecar is trusted, retry with --limit " ++
                "max_manifest_bytes={d}. Otherwise remove it and " ++
                "regenerate from the original source.",
            .{suggested},
        ),
    };
}

pub fn invalidTreeReport(origin: []const u8) Report {
    return .{
        .severity = .err,
        .code = "core.invalid-document-tree",
        .title = "PLUGIN PRODUCED AN INVALID TREE",
        .problem = "A reader or filter produced a document tree that " ++
            "violates a structural invariant. This is an implementation " ++
            "bug, not evidence that the source document is malformed.",
        .consequence = "The conversion stopped and no output file was " ++
            "created.",
        .context = .{ .logical = origin },
        .directions = &.{.{
            .title = "Report this",
            .explanation = "Keep the input file and report this with the " ++
                "zenfmt version and the input that triggered it; the " ++
                "validator caught it before any output was written.",
        }},
    };
}

pub fn strictReport(input_name: []const u8, grade: lowering.Strictness) Report {
    const problem = switch (grade) {
        .off => unreachable,
        .content => "The conversion would drop semantic content and " ++
            "--strict is set.",
        .structure => "The conversion would drop content or degrade " ++
            "structure and --strict=structure is set.",
        .exact => "The conversion is not an exact rendering and " ++
            "--strict=exact is set.",
    };
    return .{
        .severity = .err,
        .code = "core.strict-refused",
        .title = "STOPPED ON DECLARED LOSS",
        .problem = problem,
        .consequence = "No output was committed. The notes above price " ++
            "exactly what the selected lowering would have lost.",
        .context = .{ .logical = input_name },
        .directions = &.{.{
            .title = "Review the losses",
            .explanation = "Review each note above. Run without --strict " ++
                "to accept the stated losses, choose a looser grade, or " ++
                "fix the source so the losses disappear.",
        }},
    };
}

pub fn strictNeedsCapabilities(
    arena: std.mem.Allocator,
    format: []const u8,
    input_name: []const u8,
) error{OutOfMemory}!Report {
    return .{
        .severity = .err,
        .code = "core.strict-unavailable",
        .title = "STRICT MODE IS UNAVAILABLE FOR THIS WRITER",
        .problem = try std.fmt.allocPrint(
            arena,
            "The {s} writer has not declared how every document construct " ++
                "is preserved, lowered, or refused, so zenfmt cannot prove " ++
                "this conversion satisfies the requested strictness grade.",
            .{format},
        ),
        .consequence = "The writer was not opened and no output was committed.",
        .context = .{ .logical = input_name },
        .directions = try directionsSlice(arena, .{
            .title = "Choose a declared writer or disable strict mode",
            .explanation = "Choose a writer with a capability declaration. " ++
                "If this is a development-only writer and its behavior is " ++
                "acceptable, run without --strict; plugin authors should add " ++
                "a total capabilities table and bounded lowering rules.",
            .command = try arena.dupe([]const u8, &.{
                "zenfmt", "--to", format, input_name,
            }),
        }),
    };
}

pub fn extensionMismatch(
    arena: std.mem.Allocator,
    input_name: []const u8,
    by_name: []const u8,
    by_bytes: []const u8,
) error{OutOfMemory}!Report {
    return .{
        .severity = .note,
        .code = "core.extension-mismatch",
        .title = "EXTENSION AND CONTENT DISAGREE",
        .problem = try std.fmt.allocPrint(
            arena,
            "The file name says {s}, but the bytes carry a {s} signature.",
            .{ by_name, by_bytes },
        ),
        .consequence = try std.fmt.allocPrint(
            arena,
            "Content evidence wins: the file was read as {s}.",
            .{by_bytes},
        ),
        .context = .{ .logical = try arena.dupe(u8, input_name) },
        .directions = &.{.{
            .title = "Name the format explicitly",
            .explanation = "Pass --from if the routing is wrong; renaming " ++
                "the file to its real extension silences this note.",
        }},
    };
}

pub fn refusedConstructReport(
    arena: std.mem.Allocator,
    format: []const u8,
    tag_name: []const u8,
    input_name: []const u8,
) error{OutOfMemory}!Report {
    return .{
        .severity = .err,
        .code = "core.construct-refused",
        .title = "CONSTRUCT REFUSED",
        .problem = try std.fmt.allocPrint(
            arena,
            "This document contains a '{s}' construct, and the {s} " ++
                "writer declares that degrading it would be misleading.",
            .{ tag_name, format },
        ),
        .consequence = "No output was committed.",
        .context = .{ .logical = input_name },
        .directions = try directionsSlice(arena, .{
            .title = "Remove this construct or select another writer",
            .explanation = try std.fmt.allocPrint(
                arena,
                "Remove or flatten the `{s}` construct in the source, or " ++
                    "select a target whose capability table accepts it. " ++
                    "The {s} writer deliberately has no lossy fallback.",
                .{ tag_name, format },
            ),
        }),
    };
}

pub fn invalidLoweringPlan(
    arena: std.mem.Allocator,
    format: []const u8,
    err: anyerror,
) error{OutOfMemory}!Report {
    return .{
        .severity = .err,
        .code = "core.invalid-lowering-plan",
        .title = "WRITER PLAN IS INVALID",
        .problem = try std.fmt.allocPrint(
            arena,
            "The {s} writer could not produce a bounded lowering plan ({t}).",
            .{ format, err },
        ),
        .consequence = "No output was written. This is a writer plugin " ++
            "defect, not malformed input.",
        .context = .{ .logical = format },
        .directions = &.{.{
            .title = "Report the writer defect",
            .explanation = "Include the input, target format, and zenfmt " ++
                "version so the missing or overflowing lowering rule can " ++
                "be corrected.",
        }},
    };
}

pub fn invalidManifestEncoding(
    arena: std.mem.Allocator,
    format: []const u8,
    err: anyerror,
) error{OutOfMemory}!Report {
    return .{
        .severity = .err,
        .code = "core.manifest-encoding-failed",
        .title = "MANIFEST DATA IS NOT CANONICAL",
        .problem = try std.fmt.allocPrint(
            arena,
            "While preparing the {s} result, generated manifest data " ++
                "violated the canonical JSON contract ({s}).",
            .{ format, @errorName(err) },
        ),
        .consequence = "No path output was published. For a direct stream, " ++
            "the conversion result records whether artifact bytes had " ++
            "already been delivered.",
        .context = .{ .logical = format },
        .directions = &.{.{
            .title = "Report the plugin or encoder defect",
            .explanation = "Keep the source and report the target format, " ++
                "zenfmt version, and this diagnostic. Plugin authors should " ++
                "validate UTF-8, emit bytewise-sorted unique keys, and use " ++
                "WriteStream instead of assembling JSON text.",
        }},
    };
}

pub fn invalidPreservationData(
    arena: std.mem.Allocator,
    plugin_id: []const u8,
    expected_version: u32,
    err: anyerror,
) error{OutOfMemory}!Report {
    const correction = switch (err) {
        error.VersionMismatch => try std.fmt.allocPrint(
            arena,
            "Emit schema version {d}, matching the reader descriptor's " ++
                "`.data_version`, or emit no preservation entry.",
            .{expected_version},
        ),
        error.TooLarge => "Keep the namespace below " ++
            "max_plugin_data_bytes, or preserve only the minimal data " ++
            "needed for a later same-family writer.",
        else => "Encode the value with json.WriteStream; it must be valid " ++
            "UTF-8 JSON with unique object keys.",
    };
    return .{
        .severity = .err,
        .code = "core.invalid-preservation-data",
        .title = "PLUGIN PRESERVATION DATA IS INVALID",
        .problem = try std.fmt.allocPrint(
            arena,
            "Reader `{s}` returned preservation data that does not match " ++
                "its declared contract ({s}).",
            .{ plugin_id, @errorName(err) },
        ),
        .consequence = "The conversion stopped before planning or opening " ++
            "the output; invalid plugin data was not stored or carried.",
        .context = .{ .logical = plugin_id },
        .directions = try directionsSlice(arena, .{
            .title = "Correct the reader's preservation codec",
            .explanation = correction,
        }),
    };
}

pub fn loweringLimitReport(
    arena: std.mem.Allocator,
    input_name: []const u8,
    limits: Limits,
    err: lowering.PlanError,
) error{OutOfMemory}!Report {
    const name = loweringLimitName(err);
    const value = loweringLimitValue(limits, err);
    const explanation = try loweringLimitExplanation(arena, name, value, err);
    return .{
        .severity = .err,
        .code = "core.lowering-limit",
        .title = "LOWERING STOPPED AT A SAFETY LIMIT",
        .problem = try std.fmt.allocPrint(
            arena,
            "Planning this conversion exhausted `{s}` ({d}).",
            .{ name, value },
        ),
        .consequence = "Planning stopped before the writer opened the " ++
            "output, so no artifact was created or replaced.",
        .context = .{ .logical = input_name },
        .exit_class = .limit,
        .directions = try directionsSlice(arena, .{
            .title = "Simplify the source or raise only this limit",
            .explanation = explanation,
        }),
    };
}

fn loweringLimitExplanation(
    arena: std.mem.Allocator,
    name: []const u8,
    value: u64,
    err: lowering.PlanError,
) error{OutOfMemory}![]const u8 {
    const cap: ?u64 = switch (err) {
        error.AlternativeLimitExceeded => limits_mod.max_lowering_alternatives_hard,
        error.DepthLimitExceeded => limits_mod.max_depth_hard_cap,
        error.WorkLimitExceeded => null,
        else => unreachable,
    };
    const doubled = std.math.mul(u64, value, 2) catch std.math.maxInt(u64);
    const recommended = if (cap) |maximum| @min(doubled, maximum) else doubled;
    if (recommended > value) return std.fmt.allocPrint(
        arena,
        "If the input and writer plugin are trusted, retry with --limit " ++
            "{s}={d}. This permits up to twice the planning work or memory; " ++
            "otherwise simplify the source construct.",
        .{ name, recommended },
    );
    return std.fmt.allocPrint(
        arena,
        "`{s}` is already at its compiled safety cap ({d}), so it cannot " ++
            "be raised. Simplify or split the source construct instead.",
        .{ name, value },
    );
}

fn loweringLimitName(err: lowering.PlanError) []const u8 {
    return switch (err) {
        error.AlternativeLimitExceeded => "max_lowering_alternatives",
        error.WorkLimitExceeded => "max_lowering_work",
        error.DepthLimitExceeded => "max_depth",
        else => unreachable,
    };
}

fn loweringLimitValue(limits: Limits, err: lowering.PlanError) u64 {
    return switch (err) {
        error.AlternativeLimitExceeded => limits.max_lowering_alternatives,
        error.WorkLimitExceeded => limits.max_lowering_work,
        error.DepthLimitExceeded => limits.max_depth,
        else => unreachable,
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
        .consequence = "The conversion stopped. Unpublished temporary " ++
            "files were discarded. If artifact publication had already " ++
            "started, no manifest was left claiming that the incomplete " ++
            "output ensemble was complete.",
        .context = .{ .path = .{ .path = path, .operation = operation } },
        .directions = &.{pathDirection(err)},
    };
}

fn pathDirection(err: anyerror) report.Direction {
    const name = @errorName(err);
    if (std.mem.eql(u8, name, "FileNotFound") or
        std.mem.eql(u8, name, "NotDir"))
    {
        return .{
            .title = "Create or correct the parent path",
            .explanation = "Check the spelling and create the missing " ++
                "parent directory, then run the same command again.",
        };
    }
    if (std.mem.eql(u8, name, "AccessDenied") or
        std.mem.eql(u8, name, "PermissionDenied") or
        std.mem.eql(u8, name, "ReadOnlyFileSystem"))
    {
        return .{
            .title = "Choose a writable location",
            .explanation = "Grant access to this path or choose an output " ++
                "inside a directory your user can write, then retry.",
        };
    }
    if (std.mem.eql(u8, name, "NoSpaceLeft") or
        std.mem.eql(u8, name, "DiskQuota") or
        std.mem.eql(u8, name, "FileTooBig"))
    {
        return .{
            .title = "Make space or choose another filesystem",
            .explanation = "Free enough space and quota for the artifact, " ++
                "manifest, and media, or write them to another filesystem.",
        };
    }
    return .{
        .title = "Resolve the reported operating-system error",
        .explanation = "Inspect this exact path for a missing parent, an " ++
            "open-file conflict, permissions, and available disk space; " ++
            "correct the cause matching the error above, then retry.",
    };
}

pub fn writerFailure(
    arena: std.mem.Allocator,
    format: []const u8,
    artifact_name: []const u8,
    err: anyerror,
    direct: bool,
    delivered: bool,
) error{OutOfMemory}!Report {
    const consequence = if (!direct)
        "The staged artifact was discarded, and no manifest was published."
    else if (delivered)
        "The caller already received an incomplete byte prefix. Discard " ++
            "that stream before retrying; no completion manifest was published."
    else
        "The caller received no artifact bytes, and no completion manifest " ++
            "was published.";
    return .{
        .severity = .err,
        .code = "core.writer-output-failed",
        .title = "THE WRITER COULD NOT FINISH THE OUTPUT",
        .problem = try std.fmt.allocPrint(
            arena,
            "The {s} writer stopped while emitting `{s}` ({s}).",
            .{ format, artifact_name, @errorName(err) },
        ),
        .consequence = consequence,
        .context = .{ .path = .{
            .path = artifact_name,
            .operation = "write the converted artifact",
        } },
        .directions = &.{.{
            .title = "Check the destination writer, then retry",
            .explanation = "For an API stream, ensure the supplied writer " ++
                "accepts writes and flushes. Plugin authors should attach a " ++
                "specific diagnostic before returning WriteFailed.",
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
            .writer, .memory => path,
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
    format: []const u8,
) error{OutOfMemory}!void {
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
        .directions = try directionsSlice(arena, .{
            .title = "Verify the input",
            .explanation = try std.fmt.allocPrint(
                arena,
                "Open the file in its native application to verify it is " ++
                    "intact. If it is really {s}, retry with the command " ++
                    "below; otherwise replace {s} with its actual format.",
                .{ format, format },
            ),
            .command = try arena.dupe([]const u8, &.{
                "zenfmt", "--from", format, input.name,
            }),
        }),
    });
}
