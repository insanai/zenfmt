//! Opaque result ownership for the Python bridge (ZDS 0014).
//!
//! One `Result` per conversion, heap-allocated from the caller-supplied
//! allocator, owning the engine conversion (whose arena owns every byte
//! slice) plus a bridge arena for request copies and the serialized
//! reports. Accessor slices borrow from the result until the single
//! `free`. The bridge retains no pointer into caller memory after
//! `convert` returns.

const std = @import("std");
const zenfmt = @import("zenfmt");
const core = @import("zenfmt_core");
const abi = @import("abi.zig");
const request_mod = @import("request.zig");

pub const status_success: u32 = 0;
pub const status_failed: u32 = 1;
pub const status_invalid_request: u32 = 2;

pub const Result = struct {
    gpa: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    conversion: ?zenfmt.Conversion,
    status: u32,
    exit_class: u32,
    /// Canonical report array JSON including `exit_class` per report,
    /// arena-owned.
    reports_json: []const u8,

    pub fn destroy(result: *Result) void {
        const gpa = result.gpa;
        if (result.conversion) |*conversion| conversion.deinit(gpa);
        result.arena.deinit();
        gpa.destroy(result);
    }

    pub fn ensemble(result: *const Result) ?zenfmt.MemoryEnsemble {
        if (result.conversion) |*conversion| return conversion.ensemble;
        return null;
    }
};

/// The only allocation entry point, parameterized so tests can inject a
/// failing or leak-checked allocator. Returns null only when the result
/// itself cannot be constructed; engine allocation exhaustion inside a
/// conversion is a `failed` result with the canonical report.
pub fn convert(
    gpa: std.mem.Allocator,
    request: *const abi.Request,
) ?*Result {
    const result = gpa.create(Result) catch return null;
    result.* = .{
        .gpa = gpa,
        .arena = std.heap.ArenaAllocator.init(gpa),
        .conversion = null,
        .status = status_invalid_request,
        .exit_class = @intFromEnum(core.report.ExitClass.usage),
        .reports_json = "[]",
    };
    fill(result, request) catch {
        result.destroy();
        return null;
    };
    return result;
}

fn fill(result: *Result, request: *const abi.Request) error{OutOfMemory}!void {
    const arena = result.arena.allocator();
    const decoded = request_mod.decode(arena, request) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidRequest => {
            result.status = status_invalid_request;
            result.exit_class = @intFromEnum(core.report.ExitClass.usage);
            result.reports_json = try serializeReports(
                arena,
                &.{invalidRequestReport()},
            );
            return;
        },
    };

    var threaded = std.Io.Threaded.init(result.gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const conversion = zenfmt.convert(result.gpa, io, decoded.options);
    result.conversion = conversion;
    result.status = switch (conversion.status) {
        .success => status_success,
        .failed => status_failed,
    };
    result.exit_class = @intFromEnum(conversion.exit_class);
    // Serialized while the request memory is still valid; afterwards no
    // report structure is exposed across the ABI.
    result.reports_json = try serializeReports(arena, conversion.reports);
}

/// The bridge-authored diagnostic for a malformed request. The Python
/// layer builds request JSON itself, so this is an embedding defect
/// (`NativeLibraryError` in Python terms), not a document failure. The
/// `bridge.*` namespace is intentionally absent from the engine's report
/// catalog because this ABI is private.
fn invalidRequestReport() core.Report {
    return .{
        .severity = .err,
        .code = "bridge.invalid-request",
        .title = "THE BRIDGE REQUEST IS MALFORMED",
        .problem = "The request structure or options JSON does not match " ++
            "this bridge's ABI schema.",
        .consequence = "The conversion did not start, and no output or " ++
            "manifest was created.",
        .exit_class = .usage,
        .directions = &.{.{
            .title = "Reinstall the zenfmt distribution",
            .explanation = "The installed Python layer and native bridge " ++
                "disagree; reinstall the package so both come from one " ++
                "release.",
        }},
    };
}

fn serializeReports(
    arena: std.mem.Allocator,
    reports: []const core.Report,
) error{OutOfMemory}![]const u8 {
    var stream = core.json.WriteStream.init(arena);
    defer stream.deinit();
    writeReports(&stream, reports) catch return error.OutOfMemory;
    return stream.toOwnedSlice() catch return error.OutOfMemory;
}

fn writeReports(
    stream: *core.json.WriteStream,
    reports: []const core.Report,
) core.json.WriteError!void {
    try stream.beginArray();
    for (reports) |report| {
        try core.report.writeJsonOptions(report, stream, .{
            .include_exit_class = true,
        });
    }
    try stream.endArray();
}

test "reports serialize with exit_class included" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const bytes = try serializeReports(
        arena.allocator(),
        &.{invalidRequestReport()},
    );
    try std.testing.expect(
        std.mem.indexOf(u8, bytes, "\"exit_class\":\"usage\"") != null,
    );
    try std.testing.expect(
        std.mem.indexOf(u8, bytes, "\"code\":\"bridge.invalid-request\"") != null,
    );
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, bytes, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 1), parsed.value.array.items.len);
}
