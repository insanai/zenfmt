//! The server's metric catalog (ZDS 0016, Observability Specification).
//!
//! Every label set is a comptime enum, so cardinality is bounded by
//! construction and a scrape allocates nothing. The format labels are
//! generated from the compiled bundle's descriptor tables plus `unknown`:
//! adding a reader changes the label set at compile time, never at runtime.

const std = @import("std");
const zenfmt = @import("zenfmt");
const zenserve = @import("zenserve");

pub const RouteName = enum { convert, formats, status, healthz, readyz, metrics, ui, other };

pub const MethodLabel = enum {
    get,
    post,
    put,
    delete,
    patch,
    head,
    other,

    pub fn of(method: std.http.Method) MethodLabel {
        return switch (method) {
            .GET => .get,
            .POST => .post,
            .PUT => .put,
            .DELETE => .delete,
            .PATCH => .patch,
            .HEAD => .head,
            else => .other,
        };
    }
};

pub const StatusClass = enum {
    @"2xx",
    @"3xx",
    @"4xx",
    @"5xx",

    pub fn of(status: u16) StatusClass {
        std.debug.assert(status >= 100 and status <= 599);
        return switch (status / 100) {
            2 => .@"2xx",
            3 => .@"3xx",
            4 => .@"4xx",
            else => .@"5xx",
        };
    }
};

pub const RejectReason = enum { busy, head, body, rate };

pub const ExitClassLabel = enum {
    success,
    conversion,
    usage,
    limit,

    pub fn of(conversion: *const zenfmt.Conversion) ExitClassLabel {
        if (conversion.status == .success) return .success;
        return switch (conversion.exit_class) {
            .conversion => .conversion,
            .usage => .usage,
            .limit => .limit,
        };
    }
};

/// The format label values: every reader format, every writer format not
/// already present, and `unknown`.
pub const Format = BuildFormatEnum();

fn BuildFormatEnum() type {
    @setEvalBranchQuota(100_000);
    comptime var names: []const [:0]const u8 = &.{};
    inline for (zenfmt.Default.readers) |descriptor| {
        names = names ++ [_][:0]const u8{comptime nullTerminate(descriptor.format)};
    }
    inline for (zenfmt.Default.writers) |descriptor| {
        comptime var seen = false;
        inline for (names) |name| {
            if (comptime std.mem.eql(u8, name, descriptor.format)) seen = true;
        }
        if (!seen) names = names ++ [_][:0]const u8{comptime nullTerminate(descriptor.format)};
    }
    names = names ++ [_][:0]const u8{"unknown"};
    return @Enum(u8, .exhaustive, names, &std.simd.iota(u8, names.len));
}

fn nullTerminate(comptime text: []const u8) [:0]const u8 {
    return (text ++ [_]u8{0})[0..text.len :0];
}

/// Maps a runtime format identifier (or null) onto the label enum.
pub fn formatLabel(name: ?[]const u8) Format {
    const text = name orelse return .unknown;
    inline for (@typeInfo(Format).@"enum".fields) |field| {
        if (std.mem.eql(u8, field.name, text)) return @enumFromInt(field.value);
    }
    return .unknown;
}

const duration_buckets = [_]f64{ 0.005, 0.02, 0.1, 0.5, 2.0, 10.0, 60.0, 120.0 };
const size_buckets = [_]f64{
    1024,     65536,    1048576,
    16777216, 67108864, 268435456,
};

const specs = [_]zenserve.metrics.Spec{
    .{
        .name = "zenfmt_http_requests_total",
        .help = "Requests answered, by route pattern, method, and status class.",
        .kind = .counter,
        .Labels = struct { route: RouteName, method: MethodLabel, status_class: StatusClass },
    },
    .{
        .name = "zenfmt_http_request_duration_seconds",
        .help = "Request latency from head to flushed response.",
        .kind = .histogram,
        .Labels = struct { route: RouteName },
        .buckets = &duration_buckets,
    },
    .{
        .name = "zenfmt_http_connections_active",
        .help = "Connections currently owned by service tasks.",
        .kind = .gauge,
    },
    .{
        .name = "zenfmt_http_rejected_total",
        .help = "Connections and requests refused before a handler ran.",
        .kind = .counter,
        .Labels = struct { reason: RejectReason },
    },
    .{
        .name = "zenfmt_conversions_total",
        .help = "Conversions by source format, output format, and outcome.",
        .kind = .counter,
        .Labels = struct {
            source_format: Format,
            output_format: Format,
            exit_class: ExitClassLabel,
        },
    },
    .{
        .name = "zenfmt_conversion_duration_seconds",
        .help = "Engine conversion latency.",
        .kind = .histogram,
        .buckets = &duration_buckets,
    },
    .{
        .name = "zenfmt_conversion_input_bytes",
        .help = "Input document sizes.",
        .kind = .histogram,
        .buckets = &size_buckets,
    },
    .{
        .name = "zenfmt_conversion_artifact_bytes",
        .help = "Artifact sizes of successful conversions.",
        .kind = .histogram,
        .buckets = &size_buckets,
    },
    .{
        .name = "zenfmt_conversions_active",
        .help = "Conversions currently inside the engine.",
        .kind = .gauge,
    },
    .{
        .name = "zenfmt_auth_failures_total",
        .help = "Authentication failures by credential kind.",
        .kind = .counter,
        .Labels = struct { kind: AuthFailureKind },
    },
};

pub const AuthFailureKind = enum { password, token, key };

pub const Registry = zenserve.metrics.Registry(&specs);

/// The `zenfmt_build_info` series, rendered by hand because its labels are
/// free-form strings (version, revision), which the enum-labeled registry
/// deliberately cannot express.
pub fn writeBuildInfo(
    writer: *std.Io.Writer,
    version: []const u8,
    revision: []const u8,
) std.Io.Writer.Error!void {
    try writer.print(
        "# HELP zenfmt_build_info Build identity; always 1.\n" ++
            "# TYPE zenfmt_build_info gauge\n" ++
            "zenfmt_build_info{{version=\"{s}\",revision=\"{s}\"}} 1\n",
        .{ version, revision },
    );
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

test "the format enum covers the bundle plus unknown" {
    try testing.expect(@typeInfo(Format).@"enum".fields.len >= zenfmt.Default.readers.len + 1);
    try testing.expectEqual(Format.docx, formatLabel("docx"));
    try testing.expectEqual(Format.markdown, formatLabel("markdown"));
    try testing.expectEqual(Format.unknown, formatLabel("nope"));
    try testing.expectEqual(Format.unknown, formatLabel(null));
}

test "the registry instantiates and counts" {
    var registry: Registry = .init;
    registry.counter("zenfmt_http_requests_total", .{
        .route = .convert,
        .method = .post,
        .status_class = .@"2xx",
    }).inc();
    registry.counter("zenfmt_conversions_total", .{
        .source_format = .docx,
        .output_format = .markdown,
        .exit_class = .success,
    }).inc();
    registry.gauge("zenfmt_conversions_active", {}).set(2);
    registry.histogram("zenfmt_conversion_duration_seconds", {}).observe(0.05);
}

test "build info renders with string labels" {
    var buf: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try writeBuildInfo(&writer, "0.2.0", "abc123");
    try testing.expect(std.mem.indexOf(
        u8,
        writer.buffered(),
        "zenfmt_build_info{version=\"0.2.0\",revision=\"abc123\"} 1",
    ) != null);
}
