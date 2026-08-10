//! The zenfmt server (ZDS 0016): module `zenfmt_server`.
//!
//! The application layer where zenfmt, zenserve, zencli, and (in secure
//! mode) zaxonlite meet. The CLI's `serve` subcommand parses its grammar in
//! `serve_command.zig` and calls `run`, which owns the process from bind to
//! drain. zenserve knows nothing about documents; this module is the only
//! place the engine appears behind a port.

const std = @import("std");
const zenfmt = @import("zenfmt");

pub const serve_command = @import("serve_command.zig");
pub const app = @import("app.zig");
pub const store = @import("store/store.zig");
pub const secure = @import("secure.zig");

pub const LogFormat = @import("zenserve").log.Format;

/// The server options, resolved from the serve flag table (or construction
/// by an embedding program). Defaults are the open-mode one-command server.
pub const Options = struct {
    address: []const u8 = "127.0.0.1",
    port: u16 = 8998,
    secure: bool = false,
    data_dir: ?[]const u8 = null,
    behind_proxy: bool = false,
    allow_insecure_network: bool = false,
    max_body_bytes: u64 = 64 * 1024 * 1024,
    connections: u32 = 128,
    conversions: ?u32 = null, // null: logical CPU count
    limits: zenfmt.Limits = .{},
    log_format: LogFormat = .text,
    log_level: std.log.Level = .info,
    ui: bool = true,
    drain_seconds: u32 = 30,
};

/// Runs until SIGINT/SIGTERM; returns the process exit code. Startup
/// failures render Elm-style reports to `err_out` first.
pub fn run(
    gpa: std.mem.Allocator,
    io: std.Io,
    options: Options,
    err_out: *std.Io.Writer,
) u8 {
    return app.run(gpa, io, options, err_out);
}

test {
    std.testing.refAllDecls(@This());
}
