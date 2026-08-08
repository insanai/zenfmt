//! The browser ABI: every exported function and nothing else (ZDS 0015).
//!
//! JavaScript sees 32-bit offsets and lengths in linear memory, never Zig
//! layout. Offsets and lengths are `u32` because linear memory on `wasm32`
//! *is* 32-bit: a wider type would only force `BigInt` conversions across the
//! boundary for values that cannot exceed what a `u32` holds.
//!
//! Every function here is total. There is no argument a host can pass that
//! produces undefined behaviour: an unknown view, a stale handle, an
//! out-of-range index, and an address the module did not allocate all have
//! defined, testable answers. That is deliberate — the caller is page script,
//! and page script is the least trustworthy caller zenfmt has.
//!
//! Offset zero means allocation failure and nothing else. Empty results
//! return a real, module-owned address with length zero.

const std = @import("std");
const build_info = @import("zenfmt_build");
const capabilities = @import("capabilities.zig");
const exports = @import("exports.zig");
const memory = @import("memory.zig");
const result_mod = @import("result.zig");
const views = @import("views.zig");

// ------------------------------------------------------------- identity

export fn zenfmt_abi_version() u32 {
    return exports.version();
}

export fn zenfmt_version_ptr() exports.Address {
    return address(build_info.version);
}

export fn zenfmt_version_len() u32 {
    return @intCast(build_info.version.len);
}

export fn zenfmt_revision_ptr() exports.Address {
    return address(build_info.revision);
}

export fn zenfmt_revision_len() u32 {
    return @intCast(build_info.revision.len);
}

export fn zenfmt_capabilities_ptr() exports.Address {
    return address(capabilities.json);
}

export fn zenfmt_capabilities_len() u32 {
    return @intCast(capabilities.json.len);
}

// ----------------------------------------------------------- allocation

export fn zenfmt_alloc(len: u32) exports.Address {
    return memory.alloc(len);
}

export fn zenfmt_free(ptr: exports.Address) void {
    memory.free(ptr);
}

// ----------------------------------------------------------- conversion

/// Converts synchronously and returns an opaque result handle. Zero means
/// only that no result could be constructed; a document that fails to convert
/// is a real handle whose reports say why.
export fn zenfmt_convert(
    request_ptr: exports.Address,
    request_len: u32,
    input_ptr: exports.Address,
    input_len: u32,
) u32 {
    const request = slice(request_ptr, request_len) orelse return exports.failure;
    const input = slice(input_ptr, input_len) orelse return exports.failure;
    return result_mod.convert(request, input);
}

// --------------------------------------------------------------- status

export fn zenfmt_result_status(handle: u32) u32 {
    const result = result_mod.lookup(handle) orelse
        return exports.status_invalid_handle;
    return result.status;
}

export fn zenfmt_result_exit_class(handle: u32) u32 {
    const result = result_mod.lookup(handle) orelse return 0;
    return result.exit_class;
}

// ---------------------------------------------------------------- views

export fn zenfmt_result_view_ptr(handle: u32, view: u32, index: u32) exports.Address {
    const bytes = viewBytes(handle, view, index) orelse return exports.failure;
    if (bytes.len == 0) return memory.emptyAddress();
    return address(bytes);
}

export fn zenfmt_result_view_len(handle: u32, view: u32, index: u32) u32 {
    const bytes = viewBytes(handle, view, index) orelse return 0;
    return @intCast(bytes.len);
}

export fn zenfmt_result_resource_count(handle: u32) u32 {
    const result = result_mod.lookup(handle) orelse return 0;
    return views.resourceCount(result);
}

// ---------------------------------------------------------- destruction

export fn zenfmt_result_free(handle: u32) u32 {
    return result_mod.free(handle);
}

// ----------------------------------------------------------- accounting

export fn zenfmt_memory_pages() u32 {
    return memory.memoryPages();
}

export fn zenfmt_high_water_pages() u32 {
    return memory.highWaterPages();
}

export fn zenfmt_live_bytes() u32 {
    return memory.liveBytes();
}

export fn zenfmt_live_results() u32 {
    return result_mod.liveCount();
}

// ------------------------------------------------------------- internals

fn address(bytes: []const u8) exports.Address {
    return @intCast(@intFromPtr(bytes.ptr));
}

/// A caller-supplied region, validated before anything reads it. A zero
/// length is a legitimate empty slice; a null base with a nonzero length, or
/// a region whose end overflows, is not.
fn slice(ptr: exports.Address, len: u32) ?[]const u8 {
    if (len == 0) return &.{};
    if (ptr == exports.failure) return null;
    const end = @addWithOverflow(ptr, len);
    if (end[1] != 0) return null;
    const base: [*]const u8 = @ptrFromInt(ptr);
    return base[0..len];
}

fn viewBytes(handle: u32, view: u32, index: u32) ?[]const u8 {
    const result = result_mod.lookup(handle) orelse return null;
    const which = exports.View.from(view) orelse return null;
    return views.resolve(result, which, index);
}

comptime {
    // The auditor and the declaration checker both read `exports.zig`, and
    // this is what keeps that list honest: a function exported here without
    // being listed there, or listed without existing, is a compile error
    // rather than something the audit discovers later.
    for (exports.exported_names) |name| {
        if (!@hasDecl(@This(), name)) {
            @compileError("exports.zig names '" ++ name ++ "', which this module does not export");
        }
    }
}

test {
    _ = @import("capabilities.zig");
    _ = @import("exports.zig");
    _ = @import("memory.zig");
    _ = @import("profile.zig");
    _ = @import("reports.zig");
    _ = @import("request.zig");
    _ = @import("result.zig");
    _ = @import("views.zig");
    _ = @import("abi_test.zig");
}
