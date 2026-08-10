//! zenserve — the service kernel (ZDS 0016, The zenserve Library).
//!
//! Everything a bounded Zig service needs to answer HTTP, observe itself,
//! and authenticate principals — and nothing about documents. The library
//! imports only the standard library; the zenfmt server application is its
//! first consumer, and it is written to be reusable by the next service.
//!
//! The pieces, one file per concern:
//!
//! - `kernel`: listener, connection slots, service tasks, deadlines via the
//!   watchdog, keep-alive, refusals, graceful drain;
//! - `router`: the comptime route table and bounded matcher;
//! - `context`: the per-request context and response helpers;
//! - `report`: server-origin report codes, statuses, and envelopes;
//! - `log`: structured logfmt/JSON lines with a closed field set;
//! - `metrics`: the comptime registry with Prometheus text exposition;
//! - `health`: liveness and readiness checks;
//! - `auth`: roles, Argon2id password hashing, opaque tokens, the store
//!   boundary;
//! - `ratelimit`: fixed-size token buckets with LRU eviction;
//! - `multipart`: the bounded streaming multipart/form-data parser;
//! - `sse`: the bounded event ring and subscriber cursors.
//!
//! The middleware chain of ZDS 0016 is deliberately not a data structure:
//! the application composes the fixed order (request id, timing, principal,
//! role, rate, handler, metrics, log) as straight-line code in its `handle`
//! function, which is just as fixed at compile time and simpler to read
//! than a list of function pointers.

pub const kernel = @import("kernel.zig");
pub const router = @import("router.zig");
pub const context = @import("context.zig");
pub const report = @import("report.zig");
pub const log = @import("log.zig");
pub const metrics = @import("metrics.zig");
pub const health = @import("health.zig");
pub const auth = @import("auth.zig");
pub const ratelimit = @import("ratelimit.zig");
pub const multipart = @import("multipart.zig");
pub const sse = @import("sse.zig");

pub const Kernel = kernel.Kernel;
pub const Context = context.Context;
pub const Principal = context.Principal;
pub const Route = router.Route;
pub const HandlerError = router.HandlerError;
pub const Role = auth.Role;

test {
    @import("std").testing.refAllDecls(@This());
}
