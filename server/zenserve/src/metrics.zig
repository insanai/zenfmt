//! Metrics (ZDS 0016, Observability core).
//!
//! A comptime-declared registry of counters, gauges, and fixed-bucket
//! histograms with atomic cells. Label sets are comptime enums, so
//! cardinality is bounded by construction: the storage for every label
//! combination is a dense array sized at compile time, lookup is index
//! arithmetic, and a scrape allocates nothing. Exposition is the
//! Prometheus text format, rendered directly to the response writer.

const std = @import("std");
const assert = std.debug.assert;

/// The three metric kinds of the Prometheus text format that zenserve uses.
pub const Kind = enum { counter, gauge, histogram };

/// Bound on the series count (the product of label enum sizes) of one
/// metric. The comptime validator rejects a spec that exceeds it.
pub const max_series_per_metric = 4096;

/// Bound on attempts of the compare-and-swap loop that folds an
/// observation into a histogram sum. Under the kernel's bounded task
/// count the loop settles in a handful of attempts; an update that still
/// loses after this many races is dropped rather than spun on forever.
pub const max_sum_cas_attempts = 64;

/// One metric declaration. `Labels` is a struct type whose fields are
/// all enums (or `void` for an unlabeled metric); `buckets` lists
/// ascending histogram upper bounds and must be empty for other kinds.
pub const Spec = struct {
    name: []const u8,
    help: []const u8,
    kind: Kind,
    Labels: type = void,
    buckets: []const f64 = &.{},
};

/// A monotonically increasing cell.
pub const Counter = struct {
    cell: std.atomic.Value(u64),

    pub fn add(counter: *Counter, n: u64) void {
        _ = counter.cell.fetchAdd(n, .monotonic);
    }

    pub fn inc(counter: *Counter) void {
        counter.add(1);
    }

    pub fn get(counter: *const Counter) u64 {
        return counter.cell.load(.monotonic);
    }
};

/// A cell that may move in both directions.
pub const Gauge = struct {
    cell: std.atomic.Value(i64),

    pub fn set(gauge: *Gauge, value: i64) void {
        gauge.cell.store(value, .monotonic);
    }

    pub fn add(gauge: *Gauge, n: i64) void {
        _ = gauge.cell.fetchAdd(n, .monotonic);
    }

    pub fn sub(gauge: *Gauge, n: i64) void {
        _ = gauge.cell.fetchSub(n, .monotonic);
    }

    pub fn get(gauge: *const Gauge) i64 {
        return gauge.cell.load(.monotonic);
    }
};

/// A histogram cell over a comptime bucket layout. Bucket counts are
/// stored per bound (not cumulative; render accumulates), the sum is an
/// f64 carried as bits in a u64 cell and folded in with a bounded
/// compare-and-swap loop.
pub fn Histogram(comptime buckets: []const f64) type {
    return struct {
        counts: [buckets.len]std.atomic.Value(u64),
        sum_bits: std.atomic.Value(u64),
        total: std.atomic.Value(u64),

        const Self = @This();

        /// The bucket upper bounds, materialized for runtime indexing.
        pub const bounds: [buckets.len]f64 = buckets[0..].*;

        pub fn observe(histogram: *Self, value: f64) void {
            assert(!std.math.isNan(value));
            for (&histogram.counts, &bounds) |*count, bound| {
                if (value <= bound) {
                    _ = count.fetchAdd(1, .monotonic);
                    break;
                }
            }
            _ = histogram.total.fetchAdd(1, .monotonic);
            histogram.addSum(value);
        }

        fn addSum(histogram: *Self, value: f64) void {
            var old = histogram.sum_bits.load(.monotonic);
            var attempts: usize = 0;
            while (attempts < max_sum_cas_attempts) : (attempts += 1) {
                const current: f64 = @bitCast(old);
                const new: u64 = @bitCast(current + value);
                old = histogram.sum_bits.cmpxchgWeak(
                    old,
                    new,
                    .monotonic,
                    .monotonic,
                ) orelse return;
            }
            assert(attempts == max_sum_cas_attempts);
            // The update lost every race within the bound; the sum drops
            // this observation rather than spinning unboundedly.
        }

        pub fn sum(histogram: *const Self) f64 {
            return @bitCast(histogram.sum_bits.load(.monotonic));
        }
    };
}

/// Rejects a malformed spec list at compile time: names must be unique
/// Prometheus identifiers, helps nonempty, buckets ascending and present
/// exactly when the kind is histogram, labels all-enum structs whose
/// series product stays within `max_series_per_metric`.
fn validateSpecs(comptime specs: []const Spec) void {
    for (specs, 0..) |spec, i| {
        assert(isMetricName(spec.name));
        assert(spec.help.len > 0);
        for (specs[0..i]) |prior| assert(!std.mem.eql(u8, prior.name, spec.name));
        switch (spec.kind) {
            .histogram => {
                assert(spec.buckets.len > 0);
                for (spec.buckets[0 .. spec.buckets.len - 1], spec.buckets[1..]) |a, b| {
                    assert(a < b);
                }
            },
            .counter, .gauge => assert(spec.buckets.len == 0),
        }
        assert(seriesCount(spec.Labels) <= max_series_per_metric);
    }
}

fn isMetricName(comptime name: []const u8) bool {
    if (name.len == 0) return false;
    for (name, 0..) |byte, i| switch (byte) {
        'A'...'Z', 'a'...'z', '_', ':' => {},
        '0'...'9' => if (i == 0) return false,
        else => return false,
    };
    return true;
}

fn enumCount(comptime E: type) usize {
    return @typeInfo(E).@"enum".fields.len;
}

/// The number of series of a label type: the product of its enum field
/// counts, or one for `void`. Comptime only.
fn seriesCount(comptime Labels: type) usize {
    if (Labels == void) return 1;
    const info = @typeInfo(Labels).@"struct";
    var product: usize = 1;
    for (info.fields) |field| {
        assert(@typeInfo(field.type) == .@"enum");
        product *= enumCount(field.type);
    }
    return product;
}

/// Maps a label value to its dense series index, mixed-radix with the
/// first declared field most significant. Every field of `Labels` must
/// be present in `labels` with no extras, so a wrong or missing label is
/// a compile error.
fn labelIndex(comptime Labels: type, labels: anytype) usize {
    if (Labels == void) {
        comptime assert(@TypeOf(labels) == void);
        return 0;
    }
    const fields = @typeInfo(Labels).@"struct".fields;
    const given = @typeInfo(@TypeOf(labels)).@"struct".fields;
    comptime assert(given.len == fields.len);
    var index: usize = 0;
    inline for (fields) |field| {
        const count = comptime enumCount(field.type);
        const value: field.type = @field(labels, field.name);
        index = index * count + @as(usize, @intFromEnum(value));
    }
    assert(index < comptime seriesCount(Labels));
    return index;
}

fn specIndex(comptime specs: []const Spec, comptime name: []const u8) usize {
    for (specs, 0..) |spec, i| {
        if (std.mem.eql(u8, spec.name, name)) return i;
    }
    @compileError("unknown metric: " ++ name);
}

fn SpecStorage(comptime spec: Spec) type {
    const series = seriesCount(spec.Labels);
    return switch (spec.kind) {
        .counter => [series]Counter,
        .gauge => [series]Gauge,
        .histogram => [series]Histogram(spec.buckets),
    };
}

/// Returns the registry type for a comptime spec list. All cells live
/// inline in the returned struct; `init` is the all-zero state.
pub fn Registry(comptime specs: []const Spec) type {
    comptime validateSpecs(specs);
    const storage_types = comptime blk: {
        var types: [specs.len]type = undefined;
        for (specs, 0..) |spec, i| types[i] = SpecStorage(spec);
        const frozen = types;
        break :blk frozen;
    };
    const Storage = std.meta.Tuple(&storage_types);

    return struct {
        storage: Storage,

        const Self = @This();

        pub const init: Self = .{ .storage = std.mem.zeroes(Storage) };

        /// Resolves a counter cell by metric name and label value. The
        /// name and the labels are checked at compile time; pass `{}`
        /// for an unlabeled metric.
        pub fn counter(
            self: *Self,
            comptime name: []const u8,
            labels: anytype,
        ) *Counter {
            const i = comptime specIndex(specs, name);
            comptime assert(specs[i].kind == .counter);
            return &self.storage[i][labelIndex(specs[i].Labels, labels)];
        }

        /// Resolves a gauge cell; see `counter` for the contract.
        pub fn gauge(
            self: *Self,
            comptime name: []const u8,
            labels: anytype,
        ) *Gauge {
            const i = comptime specIndex(specs, name);
            comptime assert(specs[i].kind == .gauge);
            return &self.storage[i][labelIndex(specs[i].Labels, labels)];
        }

        /// Resolves a histogram cell; see `counter` for the contract.
        pub fn histogram(
            self: *Self,
            comptime name: []const u8,
            labels: anytype,
        ) *Histogram(specs[specIndex(specs, name)].buckets) {
            const i = comptime specIndex(specs, name);
            comptime assert(specs[i].kind == .histogram);
            return &self.storage[i][labelIndex(specs[i].Labels, labels)];
        }

        /// Renders the whole registry in the Prometheus text format:
        /// `# HELP` and `# TYPE` per metric, one line per series in
        /// dense index order, histograms as cumulative buckets plus
        /// `+Inf`, `_sum`, and `_count`.
        pub fn render(
            self: *Self,
            writer: *std.Io.Writer,
        ) std.Io.Writer.Error!void {
            inline for (specs, 0..) |spec, i| {
                try writer.print("# HELP {s} {s}\n# TYPE {s} {s}\n", .{
                    spec.name, spec.help, spec.name, @tagName(spec.kind),
                });
                const series = comptime seriesCount(spec.Labels);
                var s: usize = 0;
                while (s < series) : (s += 1) {
                    switch (spec.kind) {
                        .counter => {
                            try writer.writeAll(spec.name);
                            try writeLabels(spec.Labels, writer, s, null);
                            const cell = &self.storage[i][s];
                            try writer.print(" {d}\n", .{cell.get()});
                        },
                        .gauge => {
                            try writer.writeAll(spec.name);
                            try writeLabels(spec.Labels, writer, s, null);
                            const cell = &self.storage[i][s];
                            try writer.print(" {d}\n", .{cell.get()});
                        },
                        .histogram => try renderHistogramSeries(
                            spec,
                            &self.storage[i][s],
                            writer,
                            s,
                        ),
                    }
                }
            }
        }
    };
}

/// Renders one histogram series: cumulative `_bucket` lines, the `+Inf`
/// bucket, `_sum`, and `_count`.
fn renderHistogramSeries(
    comptime spec: Spec,
    cell: *const Histogram(spec.buckets),
    writer: *std.Io.Writer,
    series: usize,
) std.Io.Writer.Error!void {
    const bounds = Histogram(spec.buckets).bounds;
    var cumulative: u64 = 0;
    var b: usize = 0;
    while (b < bounds.len) : (b += 1) {
        cumulative += cell.counts[b].load(.monotonic);
        try writer.print("{s}_bucket", .{spec.name});
        try writeLabels(spec.Labels, writer, series, bounds[b]);
        try writer.print(" {d}\n", .{cumulative});
    }
    const total = cell.total.load(.monotonic);
    assert(cumulative <= total);
    try writer.print("{s}_bucket", .{spec.name});
    try writeLabels(spec.Labels, writer, series, std.math.inf(f64));
    try writer.print(" {d}\n", .{total});
    try writer.print("{s}_sum", .{spec.name});
    try writeLabels(spec.Labels, writer, series, null);
    try writer.print(" {d}\n", .{cell.sum()});
    try writer.print("{s}_count", .{spec.name});
    try writeLabels(spec.Labels, writer, series, null);
    try writer.print(" {d}\n", .{total});
}

/// Writes the `{name="value",...}` label block for a dense series index,
/// decoding the mixed-radix index back into enum tag names. `le` appends
/// the histogram bucket label; infinity renders as `+Inf`. An unlabeled
/// non-bucket series writes nothing.
fn writeLabels(
    comptime Labels: type,
    writer: *std.Io.Writer,
    series: usize,
    le: ?f64,
) std.Io.Writer.Error!void {
    const field_count = comptime if (Labels == void)
        0
    else
        @typeInfo(Labels).@"struct".fields.len;
    if (field_count == 0 and le == null) return;

    try writer.writeByte('{');
    var stride = comptime seriesCount(Labels);
    if (Labels != void) {
        inline for (@typeInfo(Labels).@"struct".fields, 0..) |field, j| {
            const count = comptime enumCount(field.type);
            stride /= count;
            const value_index = (series / stride) % count;
            const tag: field.type = @enumFromInt(value_index);
            if (j != 0) try writer.writeByte(',');
            try writer.print("{s}=\"{s}\"", .{ field.name, @tagName(tag) });
        }
    }
    if (le) |bound| {
        if (field_count != 0) try writer.writeByte(',');
        if (std.math.isInf(bound)) {
            try writer.writeAll("le=\"+Inf\"");
        } else {
            try writer.print("le=\"{d}\"", .{bound});
        }
    }
    try writer.writeByte('}');
}

// ---- tests

const testing = std.testing;

const TestMethod = enum { get, post };
const TestClass = enum { ok, err };

const test_specs = [_]Spec{
    .{
        .name = "test_requests_total",
        .help = "Requests handled.",
        .kind = .counter,
        .Labels = struct { method: TestMethod, class: TestClass },
    },
    .{
        .name = "test_active",
        .help = "Active connections.",
        .kind = .gauge,
    },
    .{
        .name = "test_duration_seconds",
        .help = "Request duration.",
        .kind = .histogram,
        .buckets = &.{ 0.5, 2 },
    },
};

const TestRegistry = Registry(&test_specs);

test "counter, gauge, and histogram arithmetic" {
    var registry: TestRegistry = .init;

    const c = registry.counter("test_requests_total", .{
        .method = .get,
        .class = .ok,
    });
    c.inc();
    c.add(4);
    try testing.expectEqual(@as(u64, 5), c.get());

    const g = registry.gauge("test_active", {});
    g.set(10);
    g.add(3);
    g.sub(5);
    try testing.expectEqual(@as(i64, 8), g.get());

    const h = registry.histogram("test_duration_seconds", {});
    h.observe(0.25);
    h.observe(0.5);
    h.observe(4.0);
    try testing.expectEqual(@as(u64, 2), h.counts[0].load(.monotonic));
    try testing.expectEqual(@as(u64, 0), h.counts[1].load(.monotonic));
    try testing.expectEqual(@as(u64, 3), h.total.load(.monotonic));
    try testing.expectEqual(@as(f64, 4.75), h.sum());
}

test "label indexing addresses each combination distinctly" {
    var registry: TestRegistry = .init;
    const methods = [_]TestMethod{ .get, .post };
    const classes = [_]TestClass{ .ok, .err };
    var expected: u64 = 1;
    for (methods) |method| {
        for (classes) |class| {
            const labels = .{ .method = method, .class = class };
            registry.counter("test_requests_total", labels).add(expected);
            expected += 1;
        }
    }
    expected = 1;
    for (methods) |method| {
        for (classes) |class| {
            const labels = .{ .method = method, .class = class };
            const cell = registry.counter("test_requests_total", labels);
            try testing.expectEqual(expected, cell.get());
            expected += 1;
        }
    }
    try testing.expectEqual(
        @as(usize, 4),
        comptime seriesCount(test_specs[0].Labels),
    );
}

test "render emits the exact Prometheus text" {
    var registry: TestRegistry = .init;
    registry.counter("test_requests_total", .{
        .method = .post,
        .class = .ok,
    }).add(3);
    registry.gauge("test_active", {}).set(2);
    const h = registry.histogram("test_duration_seconds", {});
    h.observe(0.25);
    h.observe(0.5);
    h.observe(4.0);

    var buf: [2048]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try registry.render(&writer);
    try testing.expectEqualStrings(
        \\# HELP test_requests_total Requests handled.
        \\# TYPE test_requests_total counter
        \\test_requests_total{method="get",class="ok"} 0
        \\test_requests_total{method="get",class="err"} 0
        \\test_requests_total{method="post",class="ok"} 3
        \\test_requests_total{method="post",class="err"} 0
        \\# HELP test_active Active connections.
        \\# TYPE test_active gauge
        \\test_active 2
        \\# HELP test_duration_seconds Request duration.
        \\# TYPE test_duration_seconds histogram
        \\test_duration_seconds_bucket{le="0.5"} 2
        \\test_duration_seconds_bucket{le="2"} 2
        \\test_duration_seconds_bucket{le="+Inf"} 3
        \\test_duration_seconds_sum 4.75
        \\test_duration_seconds_count 3
        \\
    , writer.buffered());
}

test "labeled histogram renders le after the label set" {
    const specs = [_]Spec{.{
        .name = "test_labeled_seconds",
        .help = "Labeled duration.",
        .kind = .histogram,
        .Labels = struct { method: TestMethod },
        .buckets = &.{1},
    }};
    var registry: Registry(&specs) = .init;
    registry.histogram("test_labeled_seconds", .{ .method = .get }).observe(0.5);

    var buf: [1024]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try registry.render(&writer);
    try testing.expectEqualStrings(
        \\# HELP test_labeled_seconds Labeled duration.
        \\# TYPE test_labeled_seconds histogram
        \\test_labeled_seconds_bucket{method="get",le="1"} 1
        \\test_labeled_seconds_bucket{method="get",le="+Inf"} 1
        \\test_labeled_seconds_sum{method="get"} 0.5
        \\test_labeled_seconds_count{method="get"} 1
        \\test_labeled_seconds_bucket{method="post",le="1"} 0
        \\test_labeled_seconds_bucket{method="post",le="+Inf"} 0
        \\test_labeled_seconds_sum{method="post"} 0
        \\test_labeled_seconds_count{method="post"} 0
        \\
    , writer.buffered());
}

test "repeated adds accumulate exactly" {
    var registry: TestRegistry = .init;
    const c = registry.counter("test_requests_total", .{
        .method = .get,
        .class = .err,
    });
    const h = registry.histogram("test_duration_seconds", {});
    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        c.inc();
        h.observe(0.25);
    }
    try testing.expectEqual(@as(u64, 1000), c.get());
    try testing.expectEqual(@as(u64, 1000), h.total.load(.monotonic));
    try testing.expectEqual(@as(f64, 250.0), h.sum());
}
