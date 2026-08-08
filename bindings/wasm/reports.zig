//! Report serialization and the browser ABI's own diagnostics (ZDS 0015).
//!
//! Engine reports cross the boundary as the same canonical JSON the Python
//! bridge uses, so a browser caller and a Python caller read identical
//! machine fields for the same document.
//!
//! The `browser.*` codes below are authored here rather than in the engine's
//! catalogue, and deliberately so: they describe a caller's misuse of this
//! ABI, not anything about a document. They live outside the engine catalogue
//! for the same reason the bridge's own codes do — `tests/docs_sync.zig`
//! scans the engine, not the bindings.

const std = @import("std");
const core = @import("zenfmt_core");
const request_mod = @import("request.zig");

pub fn serialize(
    arena: std.mem.Allocator,
    reports: []const core.Report,
) error{OutOfMemory}![]const u8 {
    var stream = core.json.WriteStream.init(arena);
    defer stream.deinit();
    write(&stream, reports) catch return error.OutOfMemory;
    return stream.toOwnedSlice() catch return error.OutOfMemory;
}

fn write(
    stream: *core.json.WriteStream,
    reports: []const core.Report,
) core.json.WriteError!void {
    try stream.beginArray();
    for (reports) |value| {
        try core.report.writeJsonOptions(value, stream, .{
            .include_exit_class = true,
        });
    }
    try stream.endArray();
}

const use_the_cli: core.report.Direction = .{
    .title = "Use the command-line tool for this document",
    .explanation = "The browser build works within limits chosen so a page " ++
        "stays responsive on a phone. The command-line tool and the Python " ++
        "library convert the same document with the engine's full limits.",
};

/// The report for a request this ABI refused. Every one of these is a caller
/// mistake, so they carry the usage exit class and say what to change.
pub fn rejection(reason: request_mod.Rejection) core.Report {
    return switch (reason) {
        .malformed => .{
            .severity = .err,
            .code = "browser.malformed-request",
            .title = "THE CONVERSION REQUEST IS MALFORMED",
            .problem = "The request was not valid UTF-8 JSON matching this " ++
                "module's request schema.",
            .consequence = "The conversion did not start, and no output or " ++
                "manifest was created.",
            .exit_class = .usage,
            .directions = &.{.{
                .title = "Send a request the module understands",
                .explanation = "Use the published browser adapter rather " ++
                    "than building the request by hand; it constructs a " ++
                    "valid request for the module it loaded.",
            }},
        },
        .unknown_schema => .{
            .severity = .err,
            .code = "browser.unknown-request-schema",
            .title = "THE REQUEST SCHEMA IS NOT SUPPORTED",
            .problem = "The request names a schema version this module does " ++
                "not implement.",
            .consequence = "The conversion did not start. No output or " ++
                "manifest was created.",
            .exit_class = .usage,
            .directions = &.{.{
                .title = "Load matching adapter and module files",
                .explanation = "The adapter and the WebAssembly module come " ++
                    "from one release and are versioned together; serve both " ++
                    "from the same distribution.",
            }},
        },
        .invalid_source_name => .{
            .severity = .err,
            .code = "browser.invalid-source-name",
            .title = "THE DOCUMENT NAME IS NOT USABLE",
            .problem = "A source or artifact name was empty, too long, or " ++
                "contained a directory separator or control character.",
            .consequence = "The conversion did not start, because the name " ++
                "is used for detection, diagnostics, and resource naming.",
            .exit_class = .usage,
            .directions = &.{.{
                .title = "Pass the file's own name",
                .explanation = "Send the plain file name, such as " ++
                    "`report.docx`. A path is not meaningful to a module " ++
                    "that has no filesystem.",
            }},
        },
        .limit_above_profile => .{
            .severity = .err,
            .code = "browser.limit-above-browser-profile",
            .title = "THAT LIMIT IS ABOVE THE BROWSER PROFILE",
            .problem = "A requested resource limit is higher than the " ++
                "browser profile allows.",
            .consequence = "The conversion did not start. The limit was not " ++
                "quietly reduced, because a smaller number than you asked " ++
                "for would be a surprising thing to convert under.",
            .exit_class = .usage,
            .directions = &.{
                .{
                    .title = "Lower the limit instead",
                    .explanation = "The browser profile is a ceiling. A " ++
                        "request may reduce any limit below it, but not " ++
                        "raise one above it.",
                },
                use_the_cli,
            },
        },
        .unknown_limit => .{
            .severity = .err,
            .code = "browser.unknown-limit",
            .title = "THAT LIMIT DOES NOT EXIST",
            .problem = "The request names a resource limit this engine does " ++
                "not have.",
            .consequence = "The conversion did not start, because a limit " ++
                "that is silently ignored is worse than one that is refused.",
            .exit_class = .usage,
            .directions = &.{.{
                .title = "Read the limit names from the capability data",
                .explanation = "The module publishes every limit it has, " ++
                    "with its browser value, in its capability document.",
            }},
        },
    };
}

/// The report for an input larger than a browser conversion accepts. Refused
/// before any allocation, so an oversized document costs the page nothing.
pub fn inputTooLarge(limit: u64) core.Report {
    _ = limit;
    return .{
        .severity = .err,
        .code = "browser.input-too-large",
        .title = "THIS DOCUMENT IS TOO LARGE FOR THE BROWSER",
        .problem = "The document is larger than the browser profile accepts.",
        .consequence = "The conversion did not start, so the page stays " ++
            "responsive and the tab is not at risk of being ended by the " ++
            "browser for using too much memory.",
        .exit_class = .limit,
        .directions = &.{use_the_cli},
    };
}

test "every browser rejection serializes with its code and exit class" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    for (std.enums.values(request_mod.Rejection)) |reason| {
        const bytes = try serialize(arena.allocator(), &.{rejection(reason)});
        try std.testing.expect(
            std.mem.indexOf(u8, bytes, "\"exit_class\":\"usage\"") != null,
        );
        try std.testing.expect(std.mem.indexOf(u8, bytes, "browser.") != null);
    }
}

test "the oversize report is a limit failure, not a document failure" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const bytes = try serialize(arena.allocator(), &.{inputTooLarge(1)});
    try std.testing.expect(
        std.mem.indexOf(u8, bytes, "\"exit_class\":\"limit\"") != null,
    );
}
