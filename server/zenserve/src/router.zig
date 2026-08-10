//! The zenserve router (ZDS 0016, The zenserve Library).
//!
//! The route table is comptime data, exactly like the CLI flag table and the
//! plugin descriptor tables: literal segments plus at most one `{param}`
//! capture per path, matched by a bounded segment walk with no regular
//! expressions, no dynamic registration, and no allocation. A table with a
//! duplicate method-and-path pair does not compile.

const std = @import("std");
const assert = std.debug.assert;

const context = @import("context.zig");
const auth = @import("auth.zig");

/// The error set a route handler may surface. Everything else a handler can
/// encounter is expressed as a response, not an error.
pub const HandlerError = error{
    OutOfMemory,
    WriteFailed,
    ReadFailed,
    Canceled,
};

/// One route: a method, a path pattern, the minimum role, and the handler.
/// The path is literal segments and at most one `{param}` capture.
pub const Route = struct {
    method: std.http.Method,
    path: []const u8,
    role: auth.Role,
    handler: *const fn (*context.Context) HandlerError!void,
};

/// The outcome of matching a request against the table.
pub const Match = union(enum) {
    found: Found,
    not_found,
    /// The path exists under another method; the response must carry `Allow`.
    method_not_allowed,

    pub const Found = struct {
        index: usize,
        param: ?[]const u8,
    };
};

/// The longest path the matcher considers; beyond it nothing can match.
pub const max_path_bytes = 512;

/// The most segments a route pattern or request path may have.
pub const max_segments = 8;

/// Builds the matcher for a comptime route table.
pub fn Table(comptime routes: []const Route) type {
    comptime checkRoutes(routes);
    return struct {
        pub const table = routes;
        pub const count = routes.len;

        /// One bounded pass over the table; each candidate is a bounded
        /// segment walk. The `target` must already be stripped of any query
        /// string.
        pub fn match(method: std.http.Method, target: []const u8) Match {
            if (target.len > max_path_bytes) return .not_found;
            var param: ?[]const u8 = null;
            var path_exists = false;
            for (routes, 0..) |route, index| {
                if (!pathMatches(route.path, target, &param)) continue;
                path_exists = true;
                if (route.method == method) {
                    return .{ .found = .{ .index = index, .param = param } };
                }
                // `PUT` aliases `POST` for Tika muscle memory (ZDS 0016).
                if (route.method == .POST and method == .PUT) {
                    return .{ .found = .{ .index = index, .param = param } };
                }
            }
            return if (path_exists) .method_not_allowed else .not_found;
        }

        /// Writes the `Allow` header value for a path, e.g. "GET, POST".
        /// Returns the slice of `buf` that was written.
        pub fn allowedMethods(target: []const u8, buf: []u8) []const u8 {
            var len: usize = 0;
            var param: ?[]const u8 = null;
            for (routes) |route| {
                if (!pathMatches(route.path, target, &param)) continue;
                const name = @tagName(route.method);
                if (len + name.len + 2 > buf.len) break;
                if (len != 0) {
                    buf[len] = ',';
                    buf[len + 1] = ' ';
                    len += 2;
                }
                @memcpy(buf[len..][0..name.len], name);
                len += name.len;
            }
            return buf[0..len];
        }
    };
}

/// True when `pattern` matches `target` segment by segment; a `{param}`
/// segment captures into `param`. Both walks are bounded by `max_segments`.
fn pathMatches(pattern: []const u8, target: []const u8, param: *?[]const u8) bool {
    param.* = null;
    var pattern_it = std.mem.tokenizeScalar(u8, pattern, '/');
    var target_it = std.mem.tokenizeScalar(u8, target, '/');
    var segments: usize = 0;
    while (segments < max_segments) : (segments += 1) {
        const pattern_segment = pattern_it.next();
        const target_segment = target_it.next();
        if (pattern_segment == null and target_segment == null) return true;
        const p = pattern_segment orelse return false;
        const t = target_segment orelse return false;
        if (isParam(p)) {
            if (t.len == 0) return false;
            assert(param.* == null);
            param.* = t;
        } else if (!std.mem.eql(u8, p, t)) {
            return false;
        }
    }
    return false;
}

fn isParam(segment: []const u8) bool {
    return segment.len > 2 and segment[0] == '{' and segment[segment.len - 1] == '}';
}

/// Comptime table validation: well-formed patterns, at most one capture, and
/// no duplicate method-and-path pair.
fn checkRoutes(comptime routes: []const Route) void {
    comptime {
        @setEvalBranchQuota(10_000);
        for (routes, 0..) |route, i| {
            if (route.path.len == 0 or route.path[0] != '/') {
                @compileError("zenserve: route path must start with '/': " ++ route.path);
            }
            var params: usize = 0;
            var it = std.mem.tokenizeScalar(u8, route.path, '/');
            var segments: usize = 0;
            while (it.next()) |segment| {
                segments += 1;
                if (isParam(segment)) params += 1;
            }
            if (segments > max_segments) {
                @compileError("zenserve: route path has too many segments: " ++ route.path);
            }
            if (params > 1) {
                @compileError("zenserve: route path has more than one {param}: " ++ route.path);
            }
            for (routes[0..i]) |previous| {
                if (previous.method == route.method and
                    std.mem.eql(u8, previous.path, route.path))
                {
                    @compileError("zenserve: duplicate route: " ++ route.path);
                }
            }
        }
    }
}

/// Strips the query string (and fragment) from a request target.
pub fn pathOf(target: []const u8) []const u8 {
    const question = std.mem.indexOfScalar(u8, target, '?') orelse target.len;
    return target[0..question];
}

/// The raw query string of a request target, without the leading `?`.
pub fn queryOf(target: []const u8) []const u8 {
    const question = std.mem.indexOfScalar(u8, target, '?') orelse return "";
    return target[question + 1 ..];
}

/// Iterates `name=value` pairs of a query string; bounded by the caller's
/// loop over a bounded target. Values are returned undecoded; zenserve
/// routes use plain token values only.
pub const QueryIterator = struct {
    remaining: []const u8,

    pub const Pair = struct { name: []const u8, value: []const u8 };

    pub fn init(query: []const u8) QueryIterator {
        return .{ .remaining = query };
    }

    pub fn next(it: *QueryIterator) ?Pair {
        while (it.remaining.len > 0) {
            const amp = std.mem.indexOfScalar(u8, it.remaining, '&') orelse it.remaining.len;
            const piece = it.remaining[0..amp];
            it.remaining = if (amp == it.remaining.len) "" else it.remaining[amp + 1 ..];
            if (piece.len == 0) continue;
            const equals = std.mem.indexOfScalar(u8, piece, '=') orelse piece.len;
            const value = if (equals == piece.len) "" else piece[equals + 1 ..];
            return .{ .name = piece[0..equals], .value = value };
        }
        return null;
    }
};

// ---------------------------------------------------------------- tests

const testing = std.testing;

fn testHandler(_: *context.Context) HandlerError!void {}

const test_routes = [_]Route{
    .{ .method = .POST, .path = "/api/v1/convert", .role = .user, .handler = testHandler },
    .{ .method = .GET, .path = "/api/v1/formats", .role = .user, .handler = testHandler },
    .{ .method = .GET, .path = "/api/v1/keys", .role = .user, .handler = testHandler },
    .{ .method = .POST, .path = "/api/v1/keys", .role = .user, .handler = testHandler },
    .{ .method = .DELETE, .path = "/api/v1/keys/{id}", .role = .user, .handler = testHandler },
    .{ .method = .GET, .path = "/healthz", .role = .anonymous, .handler = testHandler },
    .{ .method = .GET, .path = "/", .role = .anonymous, .handler = testHandler },
};

const TestTable = Table(&test_routes);

test "literal routes match by method and path" {
    const found = TestTable.match(.GET, "/api/v1/formats").found;
    try testing.expectEqual(@as(usize, 1), found.index);
    try testing.expectEqual(@as(?[]const u8, null), found.param);

    try testing.expectEqual(Match.not_found, TestTable.match(.GET, "/api/v1/nope"));
    try testing.expectEqual(Match.method_not_allowed, TestTable.match(.DELETE, "/api/v1/formats"));
}

test "PUT aliases POST" {
    const found = TestTable.match(.PUT, "/api/v1/convert").found;
    try testing.expectEqual(@as(usize, 0), found.index);
}

test "a {param} segment captures and must be non-empty" {
    const found = TestTable.match(.DELETE, "/api/v1/keys/zfk_abc").found;
    try testing.expectEqual(@as(usize, 4), found.index);
    try testing.expectEqualStrings("zfk_abc", found.param.?);

    // The segment walk collapses empty segments, so a trailing slash names
    // the collection route, where DELETE is not offered.
    try testing.expectEqual(Match.method_not_allowed, TestTable.match(.DELETE, "/api/v1/keys/"));
}

test "the root route matches only the root" {
    const found = TestTable.match(.GET, "/").found;
    try testing.expectEqual(@as(usize, 6), found.index);
    try testing.expectEqual(Match.not_found, TestTable.match(.GET, "/nope"));
}

test "allowedMethods enumerates every method on the path" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("GET, POST", TestTable.allowedMethods("/api/v1/keys", &buf));
    try testing.expectEqualStrings("GET", TestTable.allowedMethods("/healthz", &buf));
}

test "an oversized target cannot match" {
    const long = "/" ++ "a" ** max_path_bytes;
    try testing.expectEqual(Match.not_found, TestTable.match(.GET, long));
}

test "pathOf and queryOf split the target" {
    try testing.expectEqualStrings("/api/v1/convert", pathOf("/api/v1/convert?to=markdown"));
    try testing.expectEqualStrings("to=markdown&strict=exact", queryOf("/api/v1/convert?to=markdown&strict=exact"));
    try testing.expectEqualStrings("/x", pathOf("/x"));
    try testing.expectEqualStrings("", queryOf("/x"));
}

test "QueryIterator yields pairs and skips empty pieces" {
    var it = QueryIterator.init("to=markdown&&strict&limit=max_depth=8");
    const first = it.next().?;
    try testing.expectEqualStrings("to", first.name);
    try testing.expectEqualStrings("markdown", first.value);
    const second = it.next().?;
    try testing.expectEqualStrings("strict", second.name);
    try testing.expectEqualStrings("", second.value);
    const third = it.next().?;
    try testing.expectEqualStrings("limit", third.name);
    try testing.expectEqualStrings("max_depth=8", third.value);
    try testing.expectEqual(@as(?QueryIterator.Pair, null), it.next());
}
