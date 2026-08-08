//! The browser ABI's names and constants (ZDS 0015, Low-level ABI).
//!
//! A leaf module with no dependencies, because three separate things must
//! agree on it and none of them should have to import the others: the ABI
//! implementation, the section auditor that checks the built module's export
//! table, and the declaration checker that compares the JavaScript adapter
//! against its type declarations. One list, so they cannot drift.

const std = @import("std");
const builtin = @import("builtin");

/// An offset into the module's linear memory.
///
/// On `wasm32` — the only target this ABI is published for — linear memory is
/// 32-bit, so every offset and length crosses the boundary as a `u32` and a
/// host never has to convert a `BigInt` for a value that cannot exceed 2^32.
/// A native build widens it so the same code can be driven by ordinary Zig
/// tests, where a pointer really is 64 bits.
pub const Address = if (builtin.target.cpu.arch.isWasm()) u32 else usize;

pub const abi_major: u32 = 1;
pub const abi_minor: u32 = 0;

/// Packed as `(major << 16) | minor`, the same shape the Python bridge uses.
pub fn version() u32 {
    return (abi_major << 16) | abi_minor;
}

/// Every buffer the module hands a caller is aligned to this, so a host can
/// place any typed array over it without a further check.
pub const alignment = 16;

/// `zenfmt_result_status` values.
pub const status_success: u32 = 0;
pub const status_failed: u32 = 1;
pub const status_invalid_request: u32 = 2;
/// The handle does not name a live result: stale, already freed, or invented.
pub const status_invalid_handle: u32 = 3;

/// Returned by `zenfmt_alloc` and `zenfmt_convert` on failure. It is the only
/// meaning offset zero ever carries: a zero-length allocation and every
/// zero-length view return a real, nonzero address instead, so a caller never
/// has to inspect a length to tell "empty" from "failed".
pub const failure: Address = 0;

/// Which slice of a result a view call is asking for. `index` is meaningful
/// only for the resource views; a nonzero index anywhere else is an error.
pub const View = enum(u32) {
    artifact = 0,
    artifact_name = 1,
    source_format = 2,
    output_format = 3,
    reports_json = 4,
    manifest_json = 5,
    resource_rel_path = 6,
    resource_bytes = 7,
    resource_digest_hex = 8,

    pub fn indexed(view: View) bool {
        return switch (view) {
            .resource_rel_path, .resource_bytes, .resource_digest_hex => true,
            else => false,
        };
    }

    pub fn from(value: u32) ?View {
        if (value > @intFromEnum(View.resource_digest_hex)) return null;
        return @enumFromInt(value);
    }
};

/// The complete export table of the browser module, in the order the auditor
/// reports them. The module exports these and `memory`, and nothing else.
pub const exported_names = [_][]const u8{
    "zenfmt_abi_version",
    "zenfmt_version_ptr",
    "zenfmt_version_len",
    "zenfmt_revision_ptr",
    "zenfmt_revision_len",
    "zenfmt_capabilities_ptr",
    "zenfmt_capabilities_len",
    "zenfmt_alloc",
    "zenfmt_free",
    "zenfmt_convert",
    "zenfmt_result_status",
    "zenfmt_result_exit_class",
    "zenfmt_result_view_ptr",
    "zenfmt_result_view_len",
    "zenfmt_result_resource_count",
    "zenfmt_result_free",
    "zenfmt_memory_pages",
    "zenfmt_high_water_pages",
    "zenfmt_live_bytes",
    "zenfmt_live_results",
};

/// The memory export, named separately because it is not a function.
pub const exported_memory = "memory";

/// The browser module imports nothing at all. An empty allowlist is a
/// stronger and simpler claim than a curated one, and it is the whole point
/// of building `wasm32-freestanding` rather than against a host interface.
pub const allowed_imports = [_][]const u8{};

/// A WebAssembly page, for translating byte counts into the units the memory
/// accounting exports report.
pub const page_bytes = 64 * 1024;

test "the view enumeration round-trips and rejects anything else" {
    try std.testing.expectEqual(View.artifact, View.from(0).?);
    try std.testing.expectEqual(View.resource_digest_hex, View.from(8).?);
    try std.testing.expectEqual(@as(?View, null), View.from(9));
    try std.testing.expect(View.resource_bytes.indexed());
    try std.testing.expect(!View.artifact.indexed());
}

test "the export list has no duplicates" {
    for (exported_names, 0..) |name, i| {
        for (exported_names[i + 1 ..]) |other| {
            try std.testing.expect(!std.mem.eql(u8, name, other));
        }
    }
}
