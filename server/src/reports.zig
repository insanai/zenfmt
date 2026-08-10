//! Server-origin reports (ZDS 0016, Server report codes).
//!
//! Server failures reuse the engine's report struct with the `server.`
//! prefix, so API callers and the interface render every failure — engine
//! or server — through one contract. Each entry pairs the report with its
//! HTTP status; the docs-drift gate scans this file, so every code below
//! must appear in the book's reference chapter.

const std = @import("std");
const zenfmt = @import("zenfmt");

pub const Entry = struct {
    status: u16,
    report: zenfmt.Report,
};

fn direction(comptime title: []const u8, comptime explanation: []const u8) zenfmt.report.Direction {
    return .{ .title = title, .explanation = explanation };
}

pub const head_too_large: Entry = .{
    .status = 431,
    .report = .{
        .severity = .err,
        .code = "server.head-too-large",
        .title = "THE REQUEST HEAD IS TOO LARGE",
        .problem = "The request head exceeded the connection's fixed 16 KiB buffer.",
        .consequence = "Nothing was converted.",
        .exit_class = .usage,
        .directions = &.{direction("Shrink the head", "Send fewer or shorter headers.")},
    },
};

pub const body_too_large: Entry = .{
    .status = 413,
    .report = .{
        .severity = .err,
        .code = "server.body-too-large",
        .title = "THE DOCUMENT IS TOO LARGE",
        .problem = "The request body exceeds the server's body cap.",
        .consequence = "Nothing was converted.",
        .exit_class = .limit,
        .directions = &.{direction(
            "Send a smaller document",
            "Convert a smaller file, or ask the operator to raise --max-body.",
        )},
    },
};

pub const unsupported_media: Entry = .{
    .status = 415,
    .report = .{
        .severity = .err,
        .code = "server.unsupported-media",
        .title = "I CANNOT ACCEPT THIS REQUEST SHAPE",
        .problem = "The request carries a content type or multipart shape " ++
            "this route does not accept.",
        .consequence = "Nothing was converted.",
        .exit_class = .usage,
        .directions = &.{direction(
            "Send the document directly",
            "Send the document bytes as the request body, or as a single " ++
                "`file` part of a multipart/form-data request.",
        )},
    },
};

pub const missing_input: Entry = .{
    .status = 400,
    .report = .{
        .severity = .err,
        .code = "server.missing-input",
        .title = "THE REQUEST HAS NO DOCUMENT",
        .problem = "The request body is empty where a document was required.",
        .consequence = "Nothing was converted.",
        .exit_class = .usage,
        .directions = &.{direction(
            "Send the document",
            "PUT or POST the document bytes to /api/v1/convert.",
        )},
    },
};

pub const invalid_query: Entry = .{
    .status = 400,
    .report = .{
        .severity = .err,
        .code = "server.invalid-query",
        .title = "I CANNOT UNDERSTAND A QUERY PARAMETER",
        .problem = "A query parameter carries a value the route does not " ++
            "recognize.",
        .consequence = "Nothing was converted.",
        .exit_class = .usage,
        .directions = &.{direction(
            "Check the parameter",
            "`?to=` and `?from=` take format identifiers from " ++
                "/api/v1/formats; `?strict=` takes content, structure, " ++
                "or exact.",
        )},
    },
};

pub const invalid_request: Entry = .{
    .status = 400,
    .report = .{
        .severity = .err,
        .code = "server.invalid-request",
        .title = "I CANNOT UNDERSTAND THIS REQUEST",
        .problem = "The request body is malformed or contains a value this " ++
            "route does not accept.",
        .consequence = "No account or credential was changed.",
        .exit_class = .usage,
        .directions = &.{direction(
            "Check the request",
            "Send valid JSON and use the documented field names, account " ++
                "names, roles, and lengths.",
        )},
    },
};

pub const unknown_route: Entry = .{
    .status = 404,
    .report = .{
        .severity = .err,
        .code = "server.unknown-route",
        .title = "THIS PATH DOES NOT EXIST",
        .problem = "No route matches the request path.",
        .consequence = "Nothing happened.",
        .exit_class = .usage,
        .directions = &.{direction(
            "See the API",
            "The conversion API lives under /api/v1; GET /api/v1/formats lists the capabilities.",
        )},
    },
};

pub const method_not_allowed: Entry = .{
    .status = 405,
    .report = .{
        .severity = .err,
        .code = "server.method-not-allowed",
        .title = "THIS METHOD DOES NOT APPLY HERE",
        .problem = "The path exists, but not under this request method.",
        .consequence = "Nothing happened.",
        .exit_class = .usage,
        .directions = &.{direction(
            "Use an allowed method",
            "The Allow response header enumerates the methods this path accepts.",
        )},
    },
};

pub const unauthorized: Entry = .{
    .status = 401,
    .report = .{
        .severity = .err,
        .code = "server.unauthorized",
        .title = "THIS ROUTE NEEDS A SIGNED-IN CALLER",
        .problem = "The request carries no usable session or API key.",
        .consequence = "Nothing happened.",
        .exit_class = .usage,
        .directions = &.{direction(
            "Authenticate",
            "Log in for a session cookie, or send an API key as " ++
                "`Authorization: Bearer zfk_<id>.<secret>`.",
        )},
    },
};

pub const invalid_credentials: Entry = .{
    .status = 401,
    .report = .{
        .severity = .err,
        .code = "server.invalid-credentials",
        .title = "THE NAME OR PASSWORD IS WRONG",
        .problem = "The name and password do not match an active account.",
        .consequence = "No session was created.",
        .exit_class = .usage,
        .directions = &.{direction(
            "Try again",
            "Check the name and password; an administrator can reset a lost password.",
        )},
    },
};

pub const forbidden: Entry = .{
    .status = 403,
    .report = .{
        .severity = .err,
        .code = "server.forbidden",
        .title = "THIS ROUTE NEEDS MORE THAN YOUR ROLE",
        .problem = "The caller's role is below the route's requirement, or " ++
            "an ownership rule was violated.",
        .consequence = "Nothing happened.",
        .exit_class = .usage,
        .directions = &.{direction(
            "Ask an administrator",
            "An administrator can perform this action or raise the account's role.",
        )},
    },
};

pub const password_change_required: Entry = .{
    .status = 403,
    .report = .{
        .severity = .err,
        .code = "server.password-change-required",
        .title = "THE ONE-TIME PASSWORD MUST BE CHANGED FIRST",
        .problem = "The account carries a one-time password, so only the " ++
            "password-change route is permitted.",
        .consequence = "Nothing else happened.",
        .exit_class = .usage,
        .directions = &.{direction(
            "Change the password",
            "POST the new password to /api/v1/session/password, then retry.",
        )},
    },
};

pub const last_administrator: Entry = .{
    .status = 409,
    .report = .{
        .severity = .err,
        .code = "server.last-administrator",
        .title = "THE LAST ADMINISTRATOR MUST REMAIN",
        .problem = "This change would delete, demote, or disable the only remaining administrator.",
        .consequence = "The account is unchanged.",
        .exit_class = .usage,
        .directions = &.{direction(
            "Add another administrator first",
            "Create or promote a second administrator, then retry.",
        )},
    },
};

pub const rate_limited: Entry = .{
    .status = 429,
    .report = .{
        .severity = .err,
        .code = "server.rate-limited",
        .title = "TOO MANY REQUESTS",
        .problem = "The caller's rate bucket is exhausted.",
        .consequence = "The request was not processed.",
        .exit_class = .limit,
        .directions = &.{direction(
            "Slow down",
            "Retry after the interval in the Retry-After header.",
        )},
    },
};

pub const busy: Entry = .{
    .status = 503,
    .report = .{
        .severity = .err,
        .code = "server.busy",
        .title = "THE SERVER IS AT CAPACITY",
        .problem = "Every conversion slot is in use.",
        .consequence = "Nothing was converted.",
        .exit_class = .conversion,
        .directions = &.{direction(
            "Retry shortly",
            "Retry after the interval in the Retry-After header.",
        )},
    },
};

pub const limit_override_forbidden: Entry = .{
    .status = 403,
    .report = .{
        .severity = .err,
        .code = "server.limit-override-forbidden",
        .title = "LIMIT OVERRIDES NEED AN ADMINISTRATOR",
        .problem = "The `?limit=` parameter is accepted from administrators only.",
        .consequence = "Nothing was converted.",
        .exit_class = .usage,
        .directions = &.{direction(
            "Drop the parameter",
            "Convert under the server's limits, or authenticate as an administrator.",
        )},
    },
};

pub const store_unavailable: Entry = .{
    .status = 503,
    .report = .{
        .severity = .err,
        .code = "server.store-unavailable",
        .title = "THE STORE DID NOT ANSWER IN TIME",
        .problem = "A read or write against the account store failed or timed out.",
        .consequence = "The request was not processed.",
        .exit_class = .conversion,
        .directions = &.{direction(
            "Retry shortly",
            "The operator can check the store's health under /api/v1/status.",
        )},
    },
};

pub const shutting_down: Entry = .{
    .status = 503,
    .report = .{
        .severity = .err,
        .code = "server.shutting-down",
        .title = "THE SERVER IS SHUTTING DOWN",
        .problem = "The request arrived after the drain began.",
        .consequence = "The request was not processed.",
        .exit_class = .conversion,
        .directions = &.{direction(
            "Retry elsewhere",
            "Retry against a healthy instance.",
        )},
    },
};

pub const out_of_memory: Entry = .{
    .status = 500,
    .report = .{
        .severity = .err,
        .code = "server.out-of-memory",
        .title = "THE SERVER IS OUT OF MEMORY",
        .problem = "The server exhausted its memory budget while handling the request.",
        .consequence = "The request was abandoned; no artifact was produced.",
        .exit_class = .conversion,
        .directions = &.{direction(
            "Retry",
            "Retry the request; if the failure repeats, reduce the request size.",
        )},
    },
};

/// The startup warning for a non-loopback bind in open mode. Not an HTTP
/// response: rendered Elm-style to stderr before the listener accepts.
pub const open_network_bind: zenfmt.Report = .{
    .severity = .warning,
    .code = "server.open-network-bind",
    .title = "OPEN MODE IS REACHABLE FROM THE NETWORK",
    .problem = "Open mode is bound to a non-loopback address, so every " ++
        "network peer can convert documents anonymously.",
    .consequence = "The server still starts.",
    .exit_class = .conversion,
    .directions = &.{direction(
        "Restrict access",
        "Run with --secure --data-dir PATH for accounts, or bind 127.0.0.1 " ++
            "behind a firewall or reverse proxy.",
    )},
};

// ---------------------------------------------------------------- tests

const testing = std.testing;

test "every entry carries the server prefix and a direction" {
    inline for (.{
        head_too_large,           body_too_large,     unsupported_media,
        missing_input,            invalid_query,      invalid_request,
        unknown_route,            method_not_allowed, unauthorized,
        invalid_credentials,      forbidden,          password_change_required,
        last_administrator,       rate_limited,       busy,
        limit_override_forbidden, store_unavailable,  shutting_down,
        out_of_memory,
    }) |entry| {
        try testing.expect(std.mem.startsWith(u8, entry.report.code, "server."));
        try testing.expect(entry.status >= 400 and entry.status <= 599);
        try testing.expect(entry.report.directions.len >= 1);
        try testing.expect(entry.report.problem.len > 0);
        try testing.expect(entry.report.consequence.len > 0);
    }
    try testing.expectEqual(zenfmt.report.Severity.warning, open_network_bind.severity);
}
