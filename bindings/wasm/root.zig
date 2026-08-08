//! The browser module's root (ZDS 0015).
//!
//! There is no `main`: the artifact is built with no entry point, and the
//! only way in is the ABI. Referencing `abi.zig` here is what makes the
//! compiler analyze and emit those exports.
//!
//! The panic handler traps. On `wasm32-freestanding` that is already the
//! default, but stating it makes the intent explicit and keeps panic
//! formatting machinery — which would otherwise pull message rendering into
//! a module that has nowhere to render to — out of the shipped bytes. A trap
//! is also the right behaviour for the host: the worker dies, the adapter
//! notices, and it reports a trap instead of leaving the page waiting on a
//! module in an unknown state.

const std = @import("std");
const builtin = @import("builtin");

pub const abi = @import("abi.zig");

pub const panic = std.debug.FullPanic(trap);

fn trap(message: []const u8, first_trace_address: ?usize) noreturn {
    _ = message;
    _ = first_trace_address;
    if (builtin.target.cpu.arch.isWasm()) {
        @trap();
    }
    std.process.abort();
}

comptime {
    _ = abi;
}
