//! `POST /api/v1/convert` (ZDS 0016, The conversion request).
//!
//! The request body is the document; metadata rides in headers and query
//! parameters, so `curl -T report.docx '…/convert?to=markdown'` stays one
//! line. The handler reads the body into the request arena under the body
//! cap, runs the engine under the conversion admission counter, and answers
//! the negotiated representation: bare artifact bytes (chunked) or the JSON
//! envelope. Failures follow the identical path with a failure envelope,
//! because `convert` never returns an error union.

const std = @import("std");
const zenfmt = @import("zenfmt");
const core = @import("zenfmt_core");
const zenserve = @import("zenserve");

const app_mod = @import("../app.zig");
const envelope = @import("../envelope.zig");
const reports = @import("../reports.zig");

const Context = zenserve.Context;
const HandlerError = zenserve.HandlerError;

const Query = struct {
    to: ?[]const u8 = null,
    from: ?[]const u8 = null,
    strict: zenfmt.Strictness = .off,
};

pub fn handle(ctx: *Context) HandlerError!void {
    const app = ctx.appAs(app_mod.App);

    const query = parseQuery(ctx) catch |err| switch (err) {
        error.Responded => return,
        error.WriteFailed => return error.WriteFailed,
        error.OutOfMemory => return error.OutOfMemory,
    };
    // Header facts are captured before any body read: the parsed head is
    // only valid until the body starts consuming the connection buffer.
    const facts = headFacts(ctx) catch return error.OutOfMemory;
    const input = readInput(ctx, facts) catch |err| switch (err) {
        error.Responded => return,
        error.OutOfMemory => return error.OutOfMemory,
        error.WriteFailed => return error.WriteFailed,
        error.ReadFailed => return error.ReadFailed,
    };
    if (input.data.len == 0) {
        try respondEntry(ctx, reports.missing_input, &.{});
        return;
    }

    // Admission control: the conversion cap refuses rather than queues.
    const active = app.conversions_active.fetchAdd(1, .acq_rel);
    if (active >= app.conversions_cap) {
        _ = app.conversions_active.fetchSub(1, .acq_rel);
        app.metrics.counter("zenfmt_http_rejected_total", .{ .reason = .busy }).inc();
        try respondEntry(ctx, reports.busy, &.{
            .{ .name = "retry-after", .value = "1" },
        });
        return;
    }
    defer _ = app.conversions_active.fetchSub(1, .acq_rel);
    app.metrics.gauge("zenfmt_conversions_active", {}).add(1);
    defer app.metrics.gauge("zenfmt_conversions_active", {}).sub(1);

    const artifact_name = derivedArtifactName(ctx.arena, input.name, query.to) catch
        return error.OutOfMemory;
    const started = std.Io.Clock.Timestamp.now(ctx.io, .awake);
    var conversion = zenfmt.convert(app.gpa, ctx.io, .{
        .input = .{ .bytes = .{ .name = input.name, .data = input.data } },
        .output = .{ .memory = .{ .artifact_name = artifact_name } },
        .from = query.from,
        .to = query.to,
        .strict = query.strict,
        .limits = app.options.limits,
    });
    defer conversion.deinit(app.gpa);
    const finished = std.Io.Clock.Timestamp.now(ctx.io, .awake);

    observeConversion(app, &conversion, input.data.len, started, finished);
    logConversion(app, ctx, &conversion, input.data.len);

    if (conversion.status == .failed) {
        const body = envelope.writeFailure(
            ctx.arena,
            conversion.reports,
            conversion.exit_class,
        ) catch return error.OutOfMemory;
        try ctx.respondBytes(
            @enumFromInt(envelope.statusForExitClass(conversion.exit_class)),
            &.{.{ .name = "content-type", .value = "application/json" }},
            body,
        );
        return;
    }

    if (facts.accept_json) {
        const body = envelope.writeSuccess(ctx.arena, &conversion) catch
            return error.OutOfMemory;
        try ctx.respondBytes(
            .ok,
            &.{.{ .name = "content-type", .value = "application/json" }},
            body,
        );
        return;
    }
    try respondArtifact(ctx, &conversion);
}

/// `POST /api/v1/convert/batch` (ZDS 0016, Streaming semantics): a
/// multipart request of at most `max_batch_parts` documents, converted
/// sequentially, each envelope flushed as its own NDJSON line before the
/// next part begins, so a client sees progress without polling.
pub fn handleBatch(ctx: *Context) HandlerError!void {
    const app = ctx.appAs(app_mod.App);
    const query = parseQuery(ctx) catch |err| switch (err) {
        error.Responded => return,
        error.WriteFailed => return error.WriteFailed,
        error.OutOfMemory => return error.OutOfMemory,
    };

    const content_type = ctx.request.head.content_type orelse "";
    if (!std.ascii.startsWithIgnoreCase(content_type, "multipart/form-data")) {
        return respondEntry(ctx, reports.unsupported_media, &.{});
    }
    var boundary_buf: [70]u8 = undefined;
    const boundary = zenserve.multipart.boundaryFromContentType(content_type, &boundary_buf) orelse
        return respondEntry(ctx, reports.unsupported_media, &.{});

    var transfer: [8 * 1024]u8 = undefined;
    const reader = ctx.bodyReader(&transfer) catch return error.WriteFailed;
    var parser = zenserve.multipart.Parser.init(reader, boundary);

    var stream_buf: [16 * 1024]u8 = undefined;
    var body = try ctx.respondStreaming(&stream_buf, .ok, null, &.{
        .{ .name = "content-type", .value = "application/x-ndjson" },
    });

    var parts: u32 = 0;
    var header: zenserve.multipart.PartHeader = undefined;
    while (parts < zenserve.multipart.max_parts) {
        const part = parser.nextPart(&header) catch break;
        if (part == null) break;
        parts += 1;

        var collected: std.Io.Writer.Allocating = .init(ctx.arena);
        _ = parser.streamBody(&collected.writer, app.options.max_body_bytes) catch {
            try writeLine(&body, envelope.writeServerFailure(ctx.arena, reports.body_too_large) catch return error.OutOfMemory);
            continue;
        };
        const data = collected.written();
        const name = if (header.filename().len > 0) header.filename() else sniffedName(ctx.arena, data) catch "upload";
        const line = convertOne(app, ctx, name, data, query) catch return error.OutOfMemory;
        try writeLine(&body, line);
    }
    body.end() catch return error.WriteFailed;
}

fn writeLine(body: *std.http.BodyWriter, line: []const u8) HandlerError!void {
    body.writer.writeAll(line) catch return error.WriteFailed;
    body.writer.writeByte('\n') catch return error.WriteFailed;
    body.writer.flush() catch return error.WriteFailed;
    body.flush() catch return error.WriteFailed;
}

/// Converts one batch part and returns its serialized envelope.
fn convertOne(
    app: *app_mod.App,
    ctx: *Context,
    name: []const u8,
    data: []const u8,
    query: Query,
) ![]const u8 {
    const active = app.conversions_active.fetchAdd(1, .acq_rel);
    defer _ = app.conversions_active.fetchSub(1, .acq_rel);
    if (active >= app.conversions_cap) {
        return envelope.writeServerFailure(ctx.arena, reports.busy);
    }
    const artifact_name = try derivedArtifactName(ctx.arena, name, query.to);
    const started = std.Io.Clock.Timestamp.now(ctx.io, .awake);
    var conversion = zenfmt.convert(app.gpa, ctx.io, .{
        .input = .{ .bytes = .{ .name = name, .data = data } },
        .output = .{ .memory = .{ .artifact_name = artifact_name } },
        .from = query.from,
        .to = query.to,
        .strict = query.strict,
        .limits = app.options.limits,
    });
    defer conversion.deinit(app.gpa);
    const finished = std.Io.Clock.Timestamp.now(ctx.io, .awake);
    observeConversion(app, &conversion, data.len, started, finished);
    if (conversion.status == .failed) {
        return envelope.writeFailure(ctx.arena, conversion.reports, conversion.exit_class);
    }
    return envelope.writeSuccess(ctx.arena, &conversion);
}

const InputError = error{ Responded, OutOfMemory, WriteFailed, ReadFailed };

/// Facts read from the request head before the body invalidates it.
const HeadFacts = struct {
    accept_json: bool = false,
    header_name: ?[]const u8 = null,
    disposition_name: ?[]const u8 = null,
};

fn headFacts(ctx: *Context) error{OutOfMemory}!HeadFacts {
    var facts: HeadFacts = .{};
    var iterator = ctx.request.iterateHeaders();
    while (iterator.next()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "accept")) {
            facts.accept_json =
                std.mem.indexOf(u8, header.value, "application/json") != null;
        } else if (std.ascii.eqlIgnoreCase(header.name, "x-zenfmt-name")) {
            facts.header_name = try ctx.arena.dupe(u8, header.value);
        } else if (std.ascii.eqlIgnoreCase(header.name, "content-disposition")) {
            if (filenameOf(header.value)) |filename| {
                facts.disposition_name = try ctx.arena.dupe(u8, filename);
            }
        }
    }
    return facts;
}

const Input = struct {
    name: []const u8,
    data: []const u8,
};

/// Reads the document from the raw body or a single-part multipart form,
/// and resolves the input name in the record's priority order: multipart
/// filename, `X-Zenfmt-Name`, `Content-Disposition`, then `upload` plus a
/// sniffed extension.
fn readInput(ctx: *Context, facts: HeadFacts) InputError!Input {
    const limit = ctx.max_body_bytes;
    const content_type = ctx.request.head.content_type orelse "";
    if (std.ascii.startsWithIgnoreCase(content_type, "multipart/form-data")) {
        const duped_type = ctx.arena.dupe(u8, content_type) catch
            return error.OutOfMemory;
        return readMultipart(ctx, duped_type, limit, facts);
    }

    var transfer: [8 * 1024]u8 = undefined;
    const data = (try ctx.readBodyAlloc(&transfer, limit)) orelse return error.Responded;
    const name = facts.header_name orelse facts.disposition_name orelse
        sniffedName(ctx.arena, data) catch return error.OutOfMemory;
    return .{ .name = name, .data = data };
}

fn readMultipart(
    ctx: *Context,
    content_type: []const u8,
    limit: u64,
    facts: HeadFacts,
) InputError!Input {
    var boundary_buf: [70]u8 = undefined;
    const boundary = zenserve.multipart.boundaryFromContentType(
        content_type,
        &boundary_buf,
    ) orelse {
        try respondEntry(ctx, reports.unsupported_media, &.{});
        return error.Responded;
    };
    var transfer: [8 * 1024]u8 = undefined;
    const reader = try ctx.bodyReader(&transfer);
    var parser = zenserve.multipart.Parser.init(reader, boundary);
    var header: zenserve.multipart.PartHeader = undefined;
    while (true) {
        const part = parser.nextPart(&header) catch {
            try respondEntry(ctx, reports.unsupported_media, &.{});
            return error.Responded;
        };
        if (part == null) {
            try respondEntry(ctx, reports.missing_input, &.{});
            return error.Responded;
        }
        if (std.mem.eql(u8, header.name(), "file")) break;
        // Any other part is drained and ignored, bounded by the body cap.
        var discard: std.Io.Writer.Discarding = .init(&.{});
        _ = parser.streamBody(&discard.writer, limit) catch {
            try respondEntry(ctx, reports.unsupported_media, &.{});
            return error.Responded;
        };
    }
    var collected: std.Io.Writer.Allocating = .init(ctx.arena);
    _ = parser.streamBody(&collected.writer, limit) catch |err| switch (err) {
        error.PartTooLarge => {
            try respondEntry(ctx, reports.body_too_large, &.{});
            return error.Responded;
        },
        else => {
            try respondEntry(ctx, reports.unsupported_media, &.{});
            return error.Responded;
        },
    };
    const data = collected.written();
    const part_filename: ?[]const u8 = if (header.filename().len > 0)
        ctx.arena.dupe(u8, header.filename()) catch return error.OutOfMemory
    else
        null;
    const name = part_filename orelse facts.header_name orelse
        facts.disposition_name orelse
        sniffedName(ctx.arena, data) catch return error.OutOfMemory;
    return .{ .name = name, .data = data };
}

/// The `filename` parameter of a Content-Disposition header value, when
/// present. A quoted value loses its quotes; escapes stay as-is, which is
/// harmless for a display-and-detection name.
fn filenameOf(value: []const u8) ?[]const u8 {
    const key = "filename=";
    const start = std.ascii.indexOfIgnoreCase(value, key) orelse return null;
    var rest = value[start + key.len ..];
    if (rest.len == 0) return null;
    if (rest[0] == '"') {
        rest = rest[1..];
        const end = std.mem.indexOfScalar(u8, rest, '"') orelse return null;
        if (end == 0) return null;
        return rest[0..end];
    }
    const end = std.mem.indexOfAny(u8, rest, "; \t") orelse rest.len;
    if (end == 0) return null;
    return rest[0..end];
}

/// `upload` plus the extension of the sniffed format; a sniff miss stays
/// extensionless so detection reports the undetectable input honestly.
fn sniffedName(arena: std.mem.Allocator, data: []const u8) error{OutOfMemory}![]const u8 {
    const format = core.sniffFormat(data) orelse return "upload";
    const extension = readerExtension(format) orelse return "upload";
    return std.fmt.allocPrint(arena, "upload.{s}", .{extension});
}

fn readerExtension(format: []const u8) ?[]const u8 {
    inline for (zenfmt.Default.readers) |descriptor| {
        if (std.mem.eql(u8, descriptor.format, format)) {
            return descriptor.extensions[0];
        }
    }
    return null;
}

/// `report.docx` becomes `report.md` under the selected writer's primary
/// extension, mirroring the CLI's derived output path.
fn derivedArtifactName(
    arena: std.mem.Allocator,
    input_name: []const u8,
    to: ?[]const u8,
) ![]const u8 {
    const format = to orelse zenfmt.default_output_format;
    const extension = zenfmt.Default.primaryExtension(format) orelse "out";
    const basename = std.fs.path.basename(input_name);
    const stem = if (std.mem.lastIndexOfScalar(u8, basename, '.')) |index|
        basename[0..index]
    else
        basename;
    if (stem.len == 0) return std.fmt.allocPrint(arena, "upload.{s}", .{extension});
    return std.fmt.allocPrint(arena, "{s}.{s}", .{ stem, extension });
}

/// Parses `?to=&from=&strict=&limit=`; responds and fails on a bad value.
/// The `to` and `from` values are duped into the arena because they slice
/// the request head buffer, which the body read overwrites before the
/// engine sees them.
fn parseQuery(ctx: *Context) error{ Responded, WriteFailed, OutOfMemory }!Query {
    var query: Query = .{};
    var iterator = zenserve.router.QueryIterator.init(
        zenserve.router.queryOf(ctx.request.head.target),
    );
    while (iterator.next()) |pair| {
        if (std.mem.eql(u8, pair.name, "to")) {
            query.to = try ctx.arena.dupe(u8, pair.value);
        } else if (std.mem.eql(u8, pair.name, "from")) {
            query.from = try ctx.arena.dupe(u8, pair.value);
        } else if (std.mem.eql(u8, pair.name, "strict")) {
            query.strict = zenfmt.Strictness.parse(pair.value) orelse {
                try respondEntry(ctx, reports.invalid_query, &.{});
                return error.Responded;
            };
        } else if (std.mem.eql(u8, pair.name, "limit")) {
            // Limit overrides are administrator-only (ZDS 0016); the open
            // mode principal is the anonymous user, so this always refuses
            // until secure mode arrives.
            if (ctx.principal.role != .administrator) {
                try respondEntry(ctx, reports.limit_override_forbidden, &.{});
                return error.Responded;
            }
        } else {
            try respondEntry(ctx, reports.invalid_query, &.{});
            return error.Responded;
        }
    }
    return query;
}

/// Streams the artifact bytes chunked with the summary headers.
fn respondArtifact(ctx: *Context, conversion: *const zenfmt.Conversion) HandlerError!void {
    const ensemble = conversion.ensemble.?;
    var count_buf: [12]u8 = undefined;
    const count_text = std.fmt.bufPrint(
        &count_buf,
        "{d}",
        .{conversion.reports.len},
    ) catch unreachable;
    var stream_buf: [16 * 1024]u8 = undefined;
    var body = try ctx.respondStreaming(&stream_buf, .ok, null, &.{
        .{ .name = "content-type", .value = "text/markdown; charset=utf-8" },
        .{ .name = "x-zenfmt-report-count", .value = count_text },
        .{ .name = "x-zenfmt-exit-class", .value = @tagName(conversion.exit_class) },
    });
    var offset: usize = 0;
    const chunk = 64 * 1024;
    while (offset < ensemble.artifact.len) {
        const end = @min(offset + chunk, ensemble.artifact.len);
        body.writer.writeAll(ensemble.artifact[offset..end]) catch return error.WriteFailed;
        offset = end;
    }
    body.end() catch return error.WriteFailed;
}

fn respondEntry(
    ctx: *Context,
    entry: @import("../reports.zig").Entry,
    extra: []const std.http.Header,
) error{WriteFailed}!void {
    const body = envelope.writeServerFailure(ctx.arena, entry) catch {
        // The arena is exhausted: fall back to the static OOM envelope.
        try ctx.respondBytes(
            .internal_server_error,
            &.{.{ .name = "content-type", .value = "application/json" }},
            zenserve.report.out_of_memory_body,
        );
        return;
    };
    var headers_buf: [8]std.http.Header = undefined;
    std.debug.assert(extra.len + 1 <= headers_buf.len);
    headers_buf[0] = .{ .name = "content-type", .value = "application/json" };
    for (extra, 0..) |header, i| headers_buf[i + 1] = header;
    ctx.request.head.expect = null;
    try ctx.respondBytes(
        @enumFromInt(entry.status),
        headers_buf[0 .. extra.len + 1],
        body,
    );
}

fn observeConversion(
    app: *app_mod.App,
    conversion: *const zenfmt.Conversion,
    input_bytes: usize,
    started: std.Io.Clock.Timestamp,
    finished: std.Io.Clock.Timestamp,
) void {
    const app_metrics = @import("../metrics.zig");
    app.metrics.counter("zenfmt_conversions_total", .{
        .source_format = app_metrics.formatLabel(conversion.source_format),
        .output_format = app_metrics.formatLabel(conversion.output_format),
        .exit_class = app_metrics.ExitClassLabel.of(conversion),
    }).inc();
    const nanos = started.durationTo(finished).raw.nanoseconds;
    const seconds = @as(f64, @floatFromInt(nanos)) / std.time.ns_per_s;
    app.metrics.histogram("zenfmt_conversion_duration_seconds", {}).observe(seconds);
    app.metrics.histogram("zenfmt_conversion_input_bytes", {})
        .observe(@floatFromInt(input_bytes));
    if (conversion.ensemble) |ensemble| {
        app.metrics.histogram("zenfmt_conversion_artifact_bytes", {})
            .observe(@floatFromInt(ensemble.artifact.len));
    }
}

fn logConversion(
    app: *app_mod.App,
    ctx: *Context,
    conversion: *const zenfmt.Conversion,
    input_bytes: usize,
) void {
    const artifact_bytes: u64 = if (conversion.ensemble) |ensemble|
        ensemble.artifact.len
    else
        0;
    app.logger.emit(ctx.io, .info, "convert.done", &.{
        .{ .name = "request_id", .value = .{ .string = ctx.requestId() } },
        .{ .name = "source_format", .value = .{ .string = conversion.source_format orelse "unknown" } },
        .{ .name = "output_format", .value = .{ .string = conversion.output_format orelse "unknown" } },
        .{ .name = "exit_class", .value = .{ .string = @tagName(conversion.exit_class) } },
        .{ .name = "report_count", .value = .{ .unsigned = conversion.reports.len } },
        .{ .name = "input_bytes", .value = .{ .unsigned = input_bytes } },
        .{ .name = "artifact_bytes", .value = .{ .unsigned = artifact_bytes } },
    });
}
