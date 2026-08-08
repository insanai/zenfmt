//! The host-authority boundary (ZDS 0015, Engine separation required for
//! WASM).
//!
//! A bundle is built in one of two modes. A `.host` bundle may open files,
//! read an adjacent manifest, and publish an artifact atomically — everything
//! the CLI and the Python bridge need. A `.pure` bundle converts caller-owned
//! bytes into a caller-owned artifact and has no filesystem authority at all.
//!
//! The distinction is comptime, and that is the point. A runtime flag would
//! leave the path branches in the compiled module: Zig would still analyze
//! them, `std.Io.Dir.cwd()` would still be reached, and — on
//! `wasm32-freestanding`, where that function does not exist — the module
//! would not build. More importantly, the browser module's security claim is
//! that filesystem code is *not present*, which only a comptime elimination
//! can support and an import audit can then verify. A runtime check would
//! merely promise not to call it.
//!
//! Document semantics do not branch on the mode. Only the host adapters do.

const std = @import("std");

pub const Mode = enum {
    /// Paths, adjacent manifests, and atomic publication are available.
    host,
    /// Byte conversion only; no filesystem authority is compiled in.
    pure,
};

/// The stand-in a `.pure` bundle carries where a `.host` bundle carries a
/// host value. Zero-sized, so a pure conversion passes nothing at run time
/// and the parameter costs no register.
pub const Absent = struct {};

/// `std.Io` for a host bundle, nothing for a pure one.
pub fn Io(comptime mode: Mode) type {
    return switch (mode) {
        .host => std.Io,
        .pure => Absent,
    };
}

/// The in-flight atomic file a host bundle publishes through.
pub fn Atomic(comptime mode: Mode) type {
    return switch (mode) {
        .host => std.Io.File.Atomic,
        .pure => Absent,
    };
}

/// The value a pure bundle passes wherever a host bundle passes its `Io`.
pub const absent: Absent = .{};

test "a pure bundle carries no host value" {
    try std.testing.expectEqual(@as(usize, 0), @sizeOf(Io(.pure)));
    try std.testing.expectEqual(@as(usize, 0), @sizeOf(Atomic(.pure)));
    try std.testing.expectEqual(std.Io, Io(.host));
}
