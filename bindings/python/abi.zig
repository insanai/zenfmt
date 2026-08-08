//! The zenfmt Python bridge: a private, versioned C ABI over the default
//! bundle (ZDS 0014).
//!
//! The installed `zenfmt` Python package is the only supported consumer.
//! Symbols use the `zenfmt_py_` prefix, fixed-width integers, and
//! pointer-length slices; options cross as one versioned JSON object; the
//! result is an opaque handle whose accessor slices stay valid until the
//! single `zenfmt_py_result_free`. No callback ever enters the embedding
//! language, and no pointer into caller memory survives a call.

const std = @import("std");
const builtin = @import("builtin");
const build_info = @import("zenfmt_build");
const capabilities = @import("capabilities.zig");
const result_mod = @import("result.zig");

pub const abi_major: u32 = 1;
pub const abi_minor: u32 = 0;

/// `path_encoding` values in `RuntimeInfo`.
pub const path_encoding_posix_bytes: u32 = 1;
pub const path_encoding_utf16le: u32 = 2;

pub const Slice = extern struct {
    ptr: ?[*]const u8,
    len: u64,
};

/// A native path: raw bytes on POSIX, UTF-16LE code units on Windows.
/// `len` counts code units, not bytes.
pub const PathSlice = extern struct {
    ptr: ?*const anyopaque,
    len: u64,
};

pub const RuntimeInfo = extern struct {
    abi_major: u32,
    abi_minor: u32,
    pointer_bits: u32,
    path_encoding: u32,
};

pub const Request = extern struct {
    options_json: Slice,
    input_bytes: Slice,
    input_path: PathSlice,
    output_path: PathSlice,
};

pub const ResourceView = extern struct {
    rel_path: Slice,
    bytes: Slice,
    digest_hex: Slice,
};

pub const Result = result_mod.Result;

fn slice(bytes: []const u8) Slice {
    return .{ .ptr = bytes.ptr, .len = bytes.len };
}

export fn zenfmt_py_abi_version() u32 {
    return (abi_major << 16) | abi_minor;
}

export fn zenfmt_py_runtime_info(out: ?*RuntimeInfo) void {
    const info = out orelse return;
    info.* = .{
        .abi_major = abi_major,
        .abi_minor = abi_minor,
        .pointer_bits = @bitSizeOf(usize),
        .path_encoding = if (builtin.os.tag == .windows)
            path_encoding_utf16le
        else
            path_encoding_posix_bytes,
    };
}

export fn zenfmt_py_zenfmt_version(out_len: ?*u64) ?[*]const u8 {
    const len = out_len orelse return null;
    len.* = build_info.version.len;
    return build_info.version.ptr;
}

export fn zenfmt_py_capabilities(out_len: ?*u64) ?[*]const u8 {
    const len = out_len orelse return null;
    len.* = capabilities.json.len;
    return capabilities.json.ptr;
}

export fn zenfmt_py_convert(request: ?*const Request) ?*Result {
    const value = request orelse return null;
    return result_mod.convertThreaded(std.heap.smp_allocator, value);
}

export fn zenfmt_py_result_status(result: ?*const Result) u32 {
    const value = result orelse return result_mod.status_invalid_request;
    return value.status;
}

export fn zenfmt_py_result_exit_class(result: ?*const Result) u32 {
    const value = result orelse return 0;
    return value.exit_class;
}

export fn zenfmt_py_result_reports_json(
    result: ?*const Result,
    out_len: ?*u64,
) ?[*]const u8 {
    const value = result orelse return null;
    const len = out_len orelse return null;
    len.* = value.reports_json.len;
    return value.reports_json.ptr;
}

export fn zenfmt_py_result_manifest_json(
    result: ?*const Result,
    out_len: ?*u64,
) ?[*]const u8 {
    const value = result orelse return null;
    const len = out_len orelse return null;
    if (value.conversion) |*conversion| {
        const manifest_json = conversion.manifest_json orelse return null;
        len.* = manifest_json.len;
        return manifest_json.ptr;
    }
    return null;
}

export fn zenfmt_py_result_source_format(
    result: ?*const Result,
    out_len: ?*u64,
) ?[*]const u8 {
    const value = result orelse return null;
    const len = out_len orelse return null;
    if (value.conversion) |*conversion| {
        const format = conversion.source_format orelse return null;
        len.* = format.len;
        return format.ptr;
    }
    return null;
}

export fn zenfmt_py_result_output_format(
    result: ?*const Result,
    out_len: ?*u64,
) ?[*]const u8 {
    const value = result orelse return null;
    const len = out_len orelse return null;
    if (value.conversion) |*conversion| {
        const format = conversion.output_format orelse return null;
        len.* = format.len;
        return format.ptr;
    }
    return null;
}

export fn zenfmt_py_result_artifact(
    result: ?*const Result,
    out_len: ?*u64,
) ?[*]const u8 {
    const value = result orelse return null;
    const len = out_len orelse return null;
    const ensemble = value.ensemble() orelse return null;
    len.* = ensemble.artifact.len;
    return ensemble.artifact.ptr;
}

export fn zenfmt_py_result_artifact_name(
    result: ?*const Result,
    out_len: ?*u64,
) ?[*]const u8 {
    const value = result orelse return null;
    const len = out_len orelse return null;
    const ensemble = value.ensemble() orelse return null;
    len.* = ensemble.artifact_name.len;
    return ensemble.artifact_name.ptr;
}

export fn zenfmt_py_result_resource_count(result: ?*const Result) u64 {
    const value = result orelse return 0;
    const ensemble = value.ensemble() orelse return 0;
    return ensemble.resources.len;
}

export fn zenfmt_py_result_resource(
    result: ?*const Result,
    index: u64,
    out: ?*ResourceView,
) u32 {
    const value = result orelse return 1;
    const view = out orelse return 1;
    const ensemble = value.ensemble() orelse return 1;
    const i = std.math.cast(usize, index) orelse return 1;
    if (i >= ensemble.resources.len) return 1;
    const resource = &ensemble.resources[i];
    view.* = .{
        .rel_path = slice(resource.rel_path),
        .bytes = slice(resource.bytes),
        .digest_hex = slice(&resource.digest_hex),
    };
    return 0;
}

export fn zenfmt_py_result_free(result: ?*Result) void {
    const value = result orelse return;
    value.destroy();
}

test {
    _ = @import("capabilities.zig");
    _ = @import("request.zig");
    _ = @import("result.zig");
    _ = @import("abi_test.zig");
    _ = @import("fuzz_test.zig");
    _ = @import("oom_test.zig");
}
