//! The server benchmark (ZDS 0016, Server lens against Apache Tika Server).
//!
//! Starts zenfmt in open mode on an ephemeral loopback port and a pinned
//! Apache Tika Server on a second, then measures the long-running HTTP
//! service each product is: startup readiness, sequential warm latency per
//! corpus file, concurrent throughput, and the peak resident memory of the
//! whole service process tree. zenfmt is reached through
//! `PUT /api/v1/convert?to=markdown`; Tika through its documented Markdown
//! handler, `PUT /tika/md`.
//!
//! The lens answers a different question from the native benchmark and its
//! numbers are never merged with it: process startup, HTTP transfer, and
//! service isolation are different costs. A response counts only when its
//! status is successful and its body is nonempty; the charset is each
//! product's own choice, so this lens does not require UTF-8 (Tika emits
//! ISO-8859-1 for some documents). Only files both services convert
//! contribute to a shared aggregate.
//!
//! Results land in `benchmarks/results/server.json` with full provenance.

const std = @import("std");
const Io = std.Io;

const max_corpus_files = 128;
const readiness_timeout_ms = 60_000;
const startup_samples = 5;
const warm_samples = 8;
const throughput_levels = [_]u32{ 1, 2, 4, 8 };
const throughput_requests = 24;

const Options = struct {
    zenfmt: []const u8 = "zig-out/bin/zenfmt",
    java: []const u8 = "java",
    // The Tika distribution directory and the runnable jar within it. Tika's
    // pipes mode forks a child JVM whose classpath resolves relative to this
    // directory, so the server must run with it as the working directory or
    // the fork reports FAILED_TO_INITIALIZE.
    tika_dir: []const u8 = "benchmarks/.tika",
    tika_jar: []const u8 = "tika-server-standard-4.0.0-beta-1.jar",
    corpus: []const u8 = "benchmarks/corpus",
    out: []const u8 = "benchmarks/results/server.json",
    version: []const u8 = "unknown",
    revision: []const u8 = "unknown",
    tika_version: []const u8 = "4.0.0-beta-1",
};

/// One HTTP conversion service under test.
const Server = struct {
    name: []const u8,
    /// The request path and query for a Markdown conversion.
    convert_path: []const u8,
    /// The readiness probe path; a 200 means ready to serve.
    ready_path: []const u8,
    child: std.process.Child = undefined,
    port: u16 = 0,
    started_ns: u64 = 0,
    peak_rss_kib: u64 = 0,
};

const FileResult = struct {
    name: []const u8,
    size: u64,
    zenfmt: Latency,
    tika: Latency,
};

const Latency = struct {
    ok: bool = false,
    /// Median wall latency of the warm samples, nanoseconds.
    wall_ns: u64 = 0,
    p95_ns: u64 = 0,
};

const ThroughputResult = struct {
    concurrency: u32,
    zenfmt_docs_per_s: f64,
    tika_docs_per_s: f64,
};

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;
    var options = Options{};
    parseArgs(init.minimal.args, &options);

    const names = try corpusFiles(gpa, io, options.corpus);
    defer {
        for (names) |name| gpa.free(name);
        gpa.free(names);
    }
    if (names.len == 0) {
        std.debug.print(
            "server-benchmark: no corpus files in {s}; run benchmarks/fetch_corpus.sh first\n",
            .{options.corpus},
        );
        return 1;
    }

    // This lens is a local, several-minute run and is never part of CI or
    // the release build. When the pinned Apache Tika distribution is
    // absent, record a not-benchmarked result and exit success rather than
    // fail, so an accidental invocation degrades instead of breaking.
    var jar_buf: [512]u8 = undefined;
    const jar_path = std.fmt.bufPrint(&jar_buf, "{s}/{s}", .{ options.tika_dir, options.tika_jar }) catch return 1;
    const has_tika = if (Io.Dir.cwd().statFile(io, jar_path, .{})) |_| true else |_| false;
    if (!has_tika) {
        std.debug.print(
            "server-benchmark: {s} not found; this is a local-only benchmark. " ++
                "Fetch Apache Tika into {s} first (see the book's server chapter). " ++
                "Writing a not-benchmarked record.\n",
            .{ jar_path, options.tika_dir },
        );
        writeNotBenchmarked(io, &options) catch {};
        return 0;
    }

    // Launch both services, each on its own ephemeral loopback port. The
    // startup time through the first successful readiness probe is the
    // first recorded profile.
    var zenfmt_server = Server{
        .name = "zenfmt",
        .convert_path = "/api/v1/convert?to=markdown",
        .ready_path = "/healthz",
    };
    var tika_server = Server{
        .name = "tika",
        .convert_path = "/tika/md",
        .ready_path = "/tika",
    };

    var startup = StartupProfile{};
    startup.zenfmt_ms = try startupMedian(gpa, io, &options, &zenfmt_server, .zenfmt);
    startup.tika_ms = try startupMedian(gpa, io, &options, &tika_server, .tika);

    // The measured instances run for the rest of the benchmark.
    try launch(gpa, io, &options, &zenfmt_server, .zenfmt);
    defer stop(io, &zenfmt_server);
    try launch(gpa, io, &options, &tika_server, .tika);
    defer stop(io, &tika_server);
    try waitReady(gpa, io, &zenfmt_server);
    try waitReady(gpa, io, &tika_server);

    // Warm both services to steady state before any timing. Tika's pipes
    // mode forks a small pool of parser processes and pays several seconds
    // per fork on the first requests; a global warmup pays that once, so
    // the per-file "warm latency" measures steady state rather than the
    // fork ramp, which the throughput and saturation profiles capture
    // instead.
    warmup(gpa, io, &options, &zenfmt_server, names);
    warmup(gpa, io, &options, &tika_server, names);

    // Sequential warm latency per corpus file, plus the peak resident
    // memory of each service while it works.
    var results: std.ArrayList(FileResult) = .empty;
    defer {
        for (results.items) |result| gpa.free(result.name);
        results.deinit(gpa);
    }
    for (names) |name| {
        const result = try benchmarkFile(gpa, io, &options, &zenfmt_server, &tika_server, name);
        try results.append(gpa, result);
        sampleRss(io, &zenfmt_server);
        sampleRss(io, &tika_server);
        std.debug.print("done {s}\n", .{name});
    }

    // Concurrent throughput over the files both services convert.
    var throughput: std.ArrayList(ThroughputResult) = .empty;
    defer throughput.deinit(gpa);
    for (throughput_levels) |level| {
        const t = try throughputAt(gpa, io, &options, &zenfmt_server, &tika_server, names, level);
        try throughput.append(gpa, t);
        sampleRss(io, &zenfmt_server);
        sampleRss(io, &tika_server);
    }

    var machine: std.Io.Writer.Allocating = .init(gpa);
    defer machine.deinit();
    try renderJson(
        &machine.writer,
        &options,
        startup,
        &zenfmt_server,
        &tika_server,
        results.items,
        throughput.items,
    );
    Io.Dir.cwd().writeFile(io, .{ .sub_path = options.out, .data = machine.written() }) catch |err| {
        std.debug.print("server-benchmark: cannot write {s}: {t}\n", .{ options.out, err });
        return 1;
    };
    std.debug.print("server benchmark written to {s}\n", .{options.out});
    return 0;
}

const Kind = enum { zenfmt, tika };

const StartupProfile = struct {
    zenfmt_ms: f64 = 0,
    tika_ms: f64 = 0,
};

/// Median startup time through the first successful readiness probe over
/// `startup_samples` independent process starts.
fn startupMedian(
    gpa: std.mem.Allocator,
    io: Io,
    options: *const Options,
    template: *const Server,
    kind: Kind,
) !f64 {
    var samples: [startup_samples]u64 = undefined;
    var index: usize = 0;
    while (index < startup_samples) : (index += 1) {
        var server = template.*;
        const started = Io.Clock.Timestamp.now(io, .awake);
        try launch(gpa, io, options, &server, kind);
        try waitReady(gpa, io, &server);
        samples[index] = @intCast(@max(started.durationTo(Io.Clock.Timestamp.now(io, .awake)).raw.nanoseconds, 0));
        stop(io, &server);
    }
    std.mem.sort(u64, &samples, {}, std.sort.asc(u64));
    return @as(f64, @floatFromInt(samples[startup_samples / 2])) / std.time.ns_per_ms;
}

/// Binds an ephemeral loopback port, launches the service on it, and
/// records the child. The port is chosen by binding `:0` and reading the
/// assignment back, then releasing it just before the child binds — a
/// small race the loopback interface makes negligible in practice.
fn launch(
    gpa: std.mem.Allocator,
    io: Io,
    options: *const Options,
    server: *Server,
    kind: Kind,
) !void {
    server.port = try freePort(io);
    var port_buf: [8]u8 = undefined;
    const port_text = try std.fmt.bufPrint(&port_buf, "{d}", .{server.port});

    const argv: []const []const u8 = switch (kind) {
        .zenfmt => &.{ options.zenfmt, "serve", "--port", port_text, "--no-ui" },
        .tika => &.{ options.java, "-jar", options.tika_jar, "--port", port_text },
    };
    // Tika runs with its distribution directory as the working directory so
    // its forked parser JVM finds its classpath; zenfmt keeps the runner's.
    const cwd: std.process.Child.Cwd = switch (kind) {
        .zenfmt => .inherit,
        .tika => .{ .path = options.tika_dir },
    };
    _ = gpa;
    server.child = try std.process.spawn(io, .{
        .argv = argv,
        .cwd = cwd,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
        .request_resource_usage_statistics = true,
    });
}

fn stop(io: Io, server: *Server) void {
    // Kill the whole process tree, not just the parent. Tika's pipes mode
    // forks child JVMs for parsing; killing only the parent orphans them,
    // and the orphans interfere with the next instance's fork pool. The
    // children are found before the parent dies, while `pgrep -P` can still
    // see the relationship.
    if (server.child.id) |pid| killTree(io, pid);
    server.child.kill(io);
}

/// Terminates a process's descendants. A bounded breadth-first walk over
/// `pgrep -P` collects the whole tree into a fixed array, then signals every
/// process; no recursion, and a runaway tree stops at the array bound.
fn killTree(io: Io, root: std.process.Child.Id) void {
    const max_tree = 64;
    var pids: [max_tree]std.process.Child.Id = undefined;
    var count: usize = 0;
    pids[0] = root;
    count = 1;
    var cursor: usize = 0;
    while (cursor < count) : (cursor += 1) {
        var pid_buf: [16]u8 = undefined;
        const pid_text = std.fmt.bufPrint(&pid_buf, "{d}", .{pids[cursor]}) catch continue;
        var buf: [4096]u8 = undefined;
        const children = captureCommand(io, &.{ "pgrep", "-P", pid_text }, &buf) orelse continue;
        var it = std.mem.tokenizeAny(u8, children, " \t\r\n");
        while (it.next()) |child_text| {
            if (count == max_tree) break;
            const child_pid = std.fmt.parseInt(std.process.Child.Id, child_text, 10) catch continue;
            pids[count] = child_pid;
            count += 1;
        }
    }
    // Signal descendants (skip index 0, the root, which the caller kills).
    var index: usize = count;
    while (index > 1) {
        index -= 1;
        var pid_buf: [16]u8 = undefined;
        const pid_text = std.fmt.bufPrint(&pid_buf, "{d}", .{pids[index]}) catch continue;
        killPid(io, pid_text);
    }
}

fn killPid(io: Io, pid_text: []const u8) void {
    var child = std.process.spawn(io, .{
        .argv = &.{ "kill", "-TERM", pid_text },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return;
    _ = child.wait(io) catch {};
}

/// Finds a free loopback TCP port by binding `:0` and reading the kernel's
/// assignment.
fn freePort(io: Io) !u16 {
    const address = try Io.net.IpAddress.parse("127.0.0.1", 0);
    var listener = try address.listen(io, .{ .reuse_address = true });
    const port = listener.socket.address.getPort();
    listener.deinit(io);
    return port;
}

/// Polls the readiness probe until it answers 200 or the timeout elapses.
fn waitReady(gpa: std.mem.Allocator, io: Io, server: *Server) !void {
    const started = Io.Clock.Timestamp.now(io, .awake);
    while (true) {
        const status = probe(gpa, io, server.port, server.ready_path) catch 0;
        if (status == 200) return;
        const elapsed = started.durationTo(Io.Clock.Timestamp.now(io, .awake));
        if (elapsed.raw.nanoseconds > readiness_timeout_ms * std.time.ns_per_ms) {
            std.debug.print("server-benchmark: {s} did not become ready\n", .{server.name});
            return error.NotReady;
        }
        try io.sleep(.fromMilliseconds(100), .awake);
    }
}

fn probe(gpa: std.mem.Allocator, io: Io, port: u16, path: []const u8) !u16 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var client: std.http.Client = .{ .allocator = arena, .io = io };
    defer client.deinit();
    var url_buf: [128]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}{s}", .{ port, path });
    const uri = try std.Uri.parse(url);
    var redirect_buf: [1024]u8 = undefined;
    var req = try client.request(.GET, uri, .{ .redirect_behavior = .not_allowed });
    defer req.deinit();
    try req.sendBodiless();
    var response = try req.receiveHead(&redirect_buf);
    var transfer_buf: [4096]u8 = undefined;
    const reader = response.reader(&transfer_buf);
    _ = reader.discardRemaining() catch {};
    return @intFromEnum(response.head.status);
}

/// One conversion request; returns the wall latency and whether the
/// response was a successful, nonempty, valid-UTF-8 Markdown body.
const Sample = struct { wall_ns: u64, ok: bool };

fn convertOnce(
    arena: std.mem.Allocator,
    io: Io,
    client: *std.http.Client,
    port: u16,
    path: []const u8,
    name: []const u8,
    body: []const u8,
) !Sample {
    var url_buf: [128]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}{s}", .{ port, path });
    const uri = try std.Uri.parse(url);
    var redirect_buf: [1024]u8 = undefined;
    const started = Io.Clock.Timestamp.now(io, .awake);
    // The filename lets zenfmt detect formats it cannot content-sniff, the
    // way any real client of its API supplies one; Tika ignores the header
    // and detects from content. No `Accept` header: Tika's Markdown handler
    // does not offer `text/markdown` in content negotiation, and zenfmt's
    // `?to=markdown` already selects the writer.
    var req = try client.request(.PUT, uri, .{
        .redirect_behavior = .not_allowed,
        .extra_headers = &.{.{ .name = "x-zenfmt-name", .value = name }},
    });
    defer req.deinit();
    req.transfer_encoding = .{ .content_length = body.len };
    try req.sendBodyComplete(@constCast(body));
    var response = try req.receiveHead(&redirect_buf);
    var transfer_buf: [8192]u8 = undefined;
    const reader = response.reader(&transfer_buf);
    const markdown = try reader.allocRemaining(arena, .limited(64 * 1024 * 1024));
    const elapsed = started.durationTo(Io.Clock.Timestamp.now(io, .awake));
    // A response counts when it is successful and nonempty. The charset is
    // the product's own choice: zenfmt emits UTF-8, Tika sometimes emits
    // ISO-8859-1, and requiring UTF-8 here would penalise Tika for a
    // conversion it performed. Byte-level correctness against a direct
    // zenfmt call is the native lens's job, not this one.
    const ok = response.head.status == .ok and markdown.len > 0;
    return .{ .wall_ns = @intCast(@max(elapsed.raw.nanoseconds, 0)), .ok = ok };
}

/// Fires a burst of conversions to bring a service's worker pool to steady
/// state; best-effort, ignoring failures. Enough requests to warm Tika's
/// forked parser clients several times over.
fn warmup(gpa: std.mem.Allocator, io: Io, options: *const Options, server: *Server, names: []const []const u8) void {
    var name_buf: [64]u8 = undefined;
    const shared = pickSharedDocument(gpa, io, options, names, &name_buf) catch return;
    defer gpa.free(shared.body);
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var client: std.http.Client = .{ .allocator = arena, .io = io };
    defer client.deinit();
    // The arena is not reset inside the loop: the client holds state
    // allocated from it, and freeing that mid-life corrupts the pool. Ten
    // small responses cost only a few tens of kilobytes.
    var index: usize = 0;
    while (index < 10) : (index += 1) {
        _ = convertOnce(arena, io, &client, server.port, server.convert_path, shared.name, shared.body) catch {};
    }
}

fn benchmarkFile(
    gpa: std.mem.Allocator,
    io: Io,
    options: *const Options,
    zenfmt_server: *Server,
    tika_server: *Server,
    name: []const u8,
) !FileResult {
    const path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ options.corpus, name });
    defer gpa.free(path);
    const body = Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(128 * 1024 * 1024)) catch
        return .{ .name = try gpa.dupe(u8, name), .size = 0, .zenfmt = .{}, .tika = .{} };
    defer gpa.free(body);

    return .{
        .name = try gpa.dupe(u8, name),
        .size = body.len,
        .zenfmt = try warmLatency(gpa, io, zenfmt_server, name, body),
        .tika = try warmLatency(gpa, io, tika_server, name, body),
    };
}

/// One warm-up request then `warm_samples` measured requests on one
/// keep-alive client; returns the median and p95 latency, or `ok = false`
/// when any request fails the correctness gate.
fn warmLatency(gpa: std.mem.Allocator, io: Io, server: *Server, name: []const u8, body: []const u8) !Latency {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var client: std.http.Client = .{ .allocator = arena, .io = io };
    defer client.deinit();

    const first = convertOnce(arena, io, &client, server.port, server.convert_path, name, body) catch
        return .{ .ok = false };
    if (!first.ok) return .{ .ok = false };

    var samples: [warm_samples]u64 = undefined;
    var index: usize = 0;
    while (index < warm_samples) : (index += 1) {
        const sample = convertOnce(arena, io, &client, server.port, server.convert_path, name, body) catch
            return .{ .ok = false };
        if (!sample.ok) return .{ .ok = false };
        samples[index] = sample.wall_ns;
    }
    std.mem.sort(u64, &samples, {}, std.sort.asc(u64));
    const p95_index = (warm_samples * 95) / 100;
    return .{
        .ok = true,
        .wall_ns = samples[warm_samples / 2],
        .p95_ns = samples[@min(p95_index, warm_samples - 1)],
    };
}

/// Concurrent throughput at one level: `throughput_requests` conversions of
/// the first shared corpus file, `level` in flight at once, over
/// `io.concurrent` tasks. Reports documents per second for each service.
fn throughputAt(
    gpa: std.mem.Allocator,
    io: Io,
    options: *const Options,
    zenfmt_server: *Server,
    tika_server: *Server,
    names: []const []const u8,
    level: u32,
) !ThroughputResult {
    // A small, universally supported document keeps the level comparable.
    var name_buf: [64]u8 = undefined;
    const shared = try pickSharedDocument(gpa, io, options, names, &name_buf);
    defer gpa.free(shared.body);
    return .{
        .concurrency = level,
        .zenfmt_docs_per_s = try throughputFor(gpa, io, zenfmt_server, shared.name, shared.body, level),
        .tika_docs_per_s = try throughputFor(gpa, io, tika_server, shared.name, shared.body, level),
    };
}

fn throughputFor(gpa: std.mem.Allocator, io: Io, server: *Server, name: []const u8, body: []const u8, level: u32) !f64 {
    const Task = struct {
        fn run(a: std.mem.Allocator, i: Io, port: u16, path: []const u8, doc_name: []const u8, payload: []const u8, count: u32) void {
            var arena_state = std.heap.ArenaAllocator.init(a);
            defer arena_state.deinit();
            const arena = arena_state.allocator();
            var client: std.http.Client = .{ .allocator = arena, .io = i };
            defer client.deinit();
            var done: u32 = 0;
            while (done < count) : (done += 1) {
                _ = convertOnce(arena, i, &client, port, path, doc_name, payload) catch return;
            }
        }
    };
    const per_worker = @max(1, throughput_requests / level);
    const started = Io.Clock.Timestamp.now(io, .awake);
    var group: Io.Group = .init;
    var worker: u32 = 0;
    while (worker < level) : (worker += 1) {
        group.concurrent(io, Task.run, .{ gpa, io, server.port, server.convert_path, name, body, per_worker }) catch {
            Task.run(gpa, io, server.port, server.convert_path, name, body, per_worker);
        };
    }
    group.await(io) catch {};
    const elapsed = started.durationTo(Io.Clock.Timestamp.now(io, .awake));
    const seconds = @as(f64, @floatFromInt(@max(elapsed.raw.nanoseconds, 1))) / std.time.ns_per_s;
    const total: f64 = @floatFromInt(per_worker * level);
    return total / seconds;
}

const SharedDocument = struct { name: []const u8, body: []u8 };

fn pickSharedDocument(
    gpa: std.mem.Allocator,
    io: Io,
    options: *const Options,
    names: []const []const u8,
    name_buf: []u8,
) !SharedDocument {
    // A DOCX is converted by both services and is small; fall back to the
    // first corpus file when the corpus lacks one.
    var chosen: []const u8 = names[0];
    for (names) |name| {
        if (std.mem.endsWith(u8, name, ".docx")) {
            chosen = name;
            break;
        }
    }
    const copied = name_buf[0..chosen.len];
    @memcpy(copied, chosen);
    const path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ options.corpus, chosen });
    defer gpa.free(path);
    const body = try Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(128 * 1024 * 1024));
    return .{ .name = copied, .body = body };
}

/// Samples the resident memory of a service's whole process tree and keeps
/// the running peak. `ps` reports the parent and, via a second call, its
/// children — Tika forks parser workers whose memory belongs to the total.
fn sampleRss(io: Io, server: *Server) void {
    const pid = server.child.id orelse return;
    var pid_buf: [16]u8 = undefined;
    const pid_text = std.fmt.bufPrint(&pid_buf, "{d}", .{pid}) catch return;
    const total = rssTreeKib(io, pid_text);
    if (total > server.peak_rss_kib) server.peak_rss_kib = total;
}

/// Sums the resident memory of a process and its direct children, in KiB,
/// via `ps`. Best-effort: a failure leaves the peak unchanged.
fn rssTreeKib(io: Io, pid_text: []const u8) u64 {
    var total: u64 = rssOf(io, pid_text);
    // Children (Tika's parser forks). `pgrep -P <pid>` lists them.
    var buf: [4096]u8 = undefined;
    const children = captureCommand(io, &.{ "pgrep", "-P", pid_text }, &buf) orelse return total;
    var lines = std.mem.tokenizeScalar(u8, children, '\n');
    while (lines.next()) |line| {
        const child_pid = std.mem.trim(u8, line, " \t\r");
        if (child_pid.len == 0) continue;
        total += rssOf(io, child_pid);
    }
    return total;
}

fn rssOf(io: Io, pid_text: []const u8) u64 {
    var buf: [256]u8 = undefined;
    const out = captureCommand(io, &.{ "ps", "-o", "rss=", "-p", pid_text }, &buf) orelse return 0;
    const trimmed = std.mem.trim(u8, out, " \t\r\n");
    return std.fmt.parseInt(u64, trimmed, 10) catch 0;
}

/// Runs a short command and captures its stdout into `buf`; null on any
/// failure. Bounded output only (process listings).
fn captureCommand(io: Io, argv: []const []const u8, buf: []u8) ?[]const u8 {
    var child = std.process.spawn(io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .ignore,
    }) catch return null;
    var reader = child.stdout.?.reader(io, buf);
    const len = reader.interface.readSliceShort(buf) catch 0;
    _ = child.wait(io) catch {};
    if (len == 0) return null;
    return buf[0..len];
}

// ------------------------------------------------------------- reporting

/// Writes a not-benchmarked record when the Tika distribution is absent, so
/// a run without the local-only environment succeeds with an explicit
/// reason rather than failing.
fn writeNotBenchmarked(io: Io, options: *const Options) !void {
    var buf: std.Io.Writer.Allocating = .init(std.heap.page_allocator);
    defer buf.deinit();
    try buf.writer.print(
        \\{{"schema":1,"lens":"server","status":"not_benchmarked",
        \\"reason":"Apache Tika distribution absent; the server lens is a local-only benchmark",
        \\"version":"{s}","git_revision":"{s}","tika_version":"{s}"}}
        \\
    ,
        .{ options.version, options.revision, options.tika_version },
    );
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = options.out, .data = buf.written() });
}

fn renderJson(
    writer: *std.Io.Writer,
    options: *const Options,
    startup: StartupProfile,
    zenfmt_server: *const Server,
    tika_server: *const Server,
    results: []const FileResult,
    throughput: []const ThroughputResult,
) !void {
    try writer.print(
        \\{{"schema":1,"lens":"server","version":"{s}","git_revision":"{s}",
    ,
        .{ options.version, options.revision },
    );
    try writer.print(
        \\"tika_version":"{s}","startup":{{"zenfmt_ms":{d:.1},"tika_ms":{d:.1}}},
    ,
        .{ options.tika_version, startup.zenfmt_ms, startup.tika_ms },
    );
    try writer.print(
        \\"peak_rss_mb":{{"zenfmt":{d:.1},"tika":{d:.1}}},"files":[
    ,
        .{
            @as(f64, @floatFromInt(zenfmt_server.peak_rss_kib)) / 1024,
            @as(f64, @floatFromInt(tika_server.peak_rss_kib)) / 1024,
        },
    );
    for (results, 0..) |result, index| {
        for (result.name) |byte| std.debug.assert(byte >= 0x20 and byte != '"' and byte != '\\');
        if (index > 0) try writer.writeAll(",");
        try writer.print(
            \\{{"name":"{s}","size":{d},"zenfmt":{f},"tika":{f}}}
        ,
            .{ result.name, result.size, latencyJson(result.zenfmt), latencyJson(result.tika) },
        );
    }
    try writer.writeAll("],\"throughput\":[");
    for (throughput, 0..) |t, index| {
        if (index > 0) try writer.writeAll(",");
        try writer.print(
            \\{{"concurrency":{d},"zenfmt_docs_per_s":{d:.1},"tika_docs_per_s":{d:.1}}}
        ,
            .{ t.concurrency, t.zenfmt_docs_per_s, t.tika_docs_per_s },
        );
    }
    try writer.writeAll("]}\n");
}

const LatencyJson = struct {
    latency: Latency,
    pub fn format(self: LatencyJson, writer: *std.Io.Writer) !void {
        try writer.print(
            \\{{"ok":{},"wall_ms":{d:.2},"p95_ms":{d:.2}}}
        ,
            .{
                self.latency.ok,
                @as(f64, @floatFromInt(self.latency.wall_ns)) / std.time.ns_per_ms,
                @as(f64, @floatFromInt(self.latency.p95_ns)) / std.time.ns_per_ms,
            },
        );
    }
};

fn latencyJson(latency: Latency) LatencyJson {
    return .{ .latency = latency };
}

// ------------------------------------------------------------- corpus, args

fn corpusFiles(gpa: std.mem.Allocator, io: Io, corpus: []const u8) ![][]const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    defer list.deinit(gpa);
    var dir = Io.Dir.cwd().openDir(io, corpus, .{ .iterate = true }) catch return &.{};
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (entry.name.len == 0 or entry.name[0] == '.') continue;
        if (std.mem.endsWith(u8, entry.name, ".part")) continue;
        if (list.items.len == max_corpus_files) break;
        try list.append(gpa, try gpa.dupe(u8, entry.name));
    }
    std.mem.sort([]const u8, list.items, {}, struct {
        fn lessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
            return std.mem.order(u8, lhs, rhs) == .lt;
        }
    }.lessThan);
    return list.toOwnedSlice(gpa);
}

fn parseArgs(args: std.process.Args, options: *Options) void {
    var iterator = std.process.Args.Iterator.init(args);
    _ = iterator.next();
    while (iterator.next()) |arg| {
        const flags = [_]struct { name: []const u8, slot: *[]const u8 }{
            .{ .name = "--zenfmt", .slot = &options.zenfmt },
            .{ .name = "--java", .slot = &options.java },
            .{ .name = "--tika-dir", .slot = &options.tika_dir },
            .{ .name = "--tika-jar", .slot = &options.tika_jar },
            .{ .name = "--corpus", .slot = &options.corpus },
            .{ .name = "--out", .slot = &options.out },
            .{ .name = "--version", .slot = &options.version },
            .{ .name = "--revision", .slot = &options.revision },
            .{ .name = "--tika-version", .slot = &options.tika_version },
        };
        var matched = false;
        for (flags) |flag| {
            if (std.mem.eql(u8, arg, flag.name)) {
                flag.slot.* = iterator.next() orelse fatal(flag.name);
                matched = true;
            }
        }
        if (!matched) fatal(arg);
    }
}

fn fatal(flag: []const u8) noreturn {
    std.debug.print("server-benchmark: bad or incomplete argument near {s}\n", .{flag});
    std.process.exit(2);
}
