//! The browser ABI driven the way a host drives it (ZDS 0015).
//!
//! These call the exported functions directly, natively. The browser bundle
//! is the same engine with the filesystem compiled out, not a separate
//! target, so its behaviour can be checked here in milliseconds; what
//! genuinely needs a WebAssembly runtime is that the compiled module
//! instantiates and that the adapter works in a browser, which is a much
//! smaller surface.
//!
//! The emphasis is on what a hostile or confused caller can do. A page can
//! pass any 32-bit number to any of these functions, so every one of them
//! gets a test that does.

const std = @import("std");
const testing = std.testing;
const exports = @import("exports.zig");
const memory = @import("memory.zig");
const result_mod = @import("result.zig");

extern fn zenfmt_abi_version() u32;
extern fn zenfmt_version_ptr() exports.Address;
extern fn zenfmt_version_len() u32;
extern fn zenfmt_revision_ptr() exports.Address;
extern fn zenfmt_revision_len() u32;
extern fn zenfmt_capabilities_ptr() exports.Address;
extern fn zenfmt_capabilities_len() u32;
extern fn zenfmt_alloc(len: u32) exports.Address;
extern fn zenfmt_free(ptr: exports.Address) void;
extern fn zenfmt_convert(
    request_ptr: exports.Address,
    request_len: u32,
    input_ptr: exports.Address,
    input_len: u32,
) u32;
extern fn zenfmt_result_status(handle: u32) u32;
extern fn zenfmt_result_exit_class(handle: u32) u32;
extern fn zenfmt_result_view_ptr(handle: u32, view: u32, index: u32) exports.Address;
extern fn zenfmt_result_view_len(handle: u32, view: u32, index: u32) u32;
extern fn zenfmt_result_resource_count(handle: u32) u32;
extern fn zenfmt_result_free(handle: u32) u32;
extern fn zenfmt_memory_pages() u32;
extern fn zenfmt_high_water_pages() u32;
extern fn zenfmt_live_bytes() u32;
extern fn zenfmt_live_results() u32;

/// Reads a view back out of "linear memory" exactly as a host would: by
/// address and length, with no help from Zig's type system.
fn readView(handle: u32, view: exports.View, index: u32) ?[]const u8 {
    const ptr = zenfmt_result_view_ptr(handle, @intFromEnum(view), index);
    if (ptr == exports.failure) return null;
    const len = zenfmt_result_view_len(handle, @intFromEnum(view), index);
    const base: [*]const u8 = @ptrFromInt(ptr);
    return base[0..len];
}

/// Copies bytes into module-owned memory the way a host does, and returns the
/// address it would pass back in.
fn upload(bytes: []const u8) exports.Address {
    const ptr = zenfmt_alloc(@intCast(bytes.len));
    if (bytes.len == 0) return ptr;
    const base: [*]u8 = @ptrFromInt(ptr);
    @memcpy(base[0..bytes.len], bytes);
    return ptr;
}

const simple_request =
    \\{"schema":1,"name":"note.md"}
;

test "identity reports a version, a revision, and capability JSON" {
    try testing.expectEqual((1 << 16) | 0, zenfmt_abi_version());

    const version_base: [*]const u8 = @ptrFromInt(zenfmt_version_ptr());
    const version = version_base[0..zenfmt_version_len()];
    try testing.expect(version.len > 0);

    const revision_base: [*]const u8 = @ptrFromInt(zenfmt_revision_ptr());
    try testing.expect(revision_base[0..zenfmt_revision_len()].len > 0);

    const caps_base: [*]const u8 = @ptrFromInt(zenfmt_capabilities_ptr());
    const caps = caps_base[0..zenfmt_capabilities_len()];
    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        testing.allocator,
        caps,
        .{},
    );
    defer parsed.deinit();
    try testing.expectEqualStrings(
        "wasm32-freestanding",
        parsed.value.object.get("target").?.string,
    );
}

test "a full conversion cycle produces readable views" {
    defer result_mod.freeAll();
    const request = upload(simple_request);
    const input = upload("# Title\n\nBody text.\n");

    const handle = zenfmt_convert(
        request,
        @intCast(simple_request.len),
        input,
        @intCast("# Title\n\nBody text.\n".len),
    );
    try testing.expect(handle != exports.failure);
    try testing.expectEqual(exports.status_success, zenfmt_result_status(handle));

    const artifact = readView(handle, .artifact, 0).?;
    try testing.expect(std.mem.indexOf(u8, artifact, "# Title") != null);
    try testing.expectEqualStrings("note.md", readView(handle, .artifact_name, 0).?);
    try testing.expectEqualStrings("markdown", readView(handle, .source_format, 0).?);
    try testing.expectEqual(@as(u32, 0), zenfmt_result_resource_count(handle));

    try testing.expectEqual(@as(u32, 0), zenfmt_result_free(handle));
    zenfmt_free(request);
    zenfmt_free(input);
}

test "the module never retains a pointer into caller memory" {
    defer result_mod.freeAll();
    const document = "# Kept\n\nText that must survive.\n";
    const request = upload(simple_request);
    const input = upload(document);

    const handle = zenfmt_convert(
        request,
        @intCast(simple_request.len),
        input,
        @intCast(document.len),
    );
    try testing.expect(handle != exports.failure);

    // Overwrite both caller buffers before reading anything back. If any view
    // aliased them, the artifact or the name would change underneath us —
    // which is exactly the failure this contract exists to rule out.
    const request_base: [*]u8 = @ptrFromInt(request);
    @memset(request_base[0..simple_request.len], 0xaa);
    const input_base: [*]u8 = @ptrFromInt(input);
    @memset(input_base[0..document.len], 0xbb);

    const artifact = readView(handle, .artifact, 0).?;
    try testing.expect(std.mem.indexOf(u8, artifact, "# Kept") != null);
    try testing.expectEqualStrings("note.md", readView(handle, .artifact_name, 0).?);

    try testing.expectEqual(@as(u32, 0), zenfmt_result_free(handle));
    zenfmt_free(request);
    zenfmt_free(input);
}

test "a stale handle is answered, not followed" {
    defer result_mod.freeAll();
    const request = upload(simple_request);
    const handle = zenfmt_convert(request, @intCast(simple_request.len), 0, 0);
    try testing.expectEqual(@as(u32, 0), zenfmt_result_free(handle));

    try testing.expectEqual(
        exports.status_invalid_handle,
        zenfmt_result_status(handle),
    );
    try testing.expectEqual(@as(u32, 0), zenfmt_result_exit_class(handle));
    try testing.expectEqual(
        exports.failure,
        zenfmt_result_view_ptr(handle, 0, 0),
    );
    try testing.expectEqual(@as(u32, 0), zenfmt_result_resource_count(handle));
    // Freeing twice reports the mistake rather than corrupting the table.
    try testing.expectEqual(@as(u32, 1), zenfmt_result_free(handle));
    zenfmt_free(request);
}

test "fabricated handles and view ids are all refused" {
    const fabricated = [_]u32{ 0, 1, 0xdead_beef, std.math.maxInt(u32) };
    for (fabricated) |handle| {
        try testing.expectEqual(
            exports.status_invalid_handle,
            zenfmt_result_status(handle),
        );
        try testing.expectEqual(exports.failure, zenfmt_result_view_ptr(handle, 0, 0));
        try testing.expectEqual(@as(u32, 0), zenfmt_result_view_len(handle, 0, 0));
    }
}

test "an unknown view id resolves to nothing" {
    defer result_mod.freeAll();
    const request = upload(simple_request);
    const handle = zenfmt_convert(request, @intCast(simple_request.len), 0, 0);
    defer zenfmt_free(request);
    defer _ = zenfmt_result_free(handle);

    for ([_]u32{ 9, 100, std.math.maxInt(u32) }) |view| {
        try testing.expectEqual(exports.failure, zenfmt_result_view_ptr(handle, view, 0));
        try testing.expectEqual(@as(u32, 0), zenfmt_result_view_len(handle, view, 0));
    }
}

test "an overflowing region is refused before it is read" {
    // A length that would carry the region past the end of the address space.
    const near_top: exports.Address = std.math.maxInt(exports.Address) - 4;
    try testing.expectEqual(
        @as(u32, exports.failure),
        zenfmt_convert(near_top, 64, 0, 0),
    );
}

test "a zero-length allocation is usable and distinct from failure" {
    const empty = zenfmt_alloc(0);
    try testing.expect(empty != exports.failure);
    // Freeing it is a no-op rather than an error, and freeing zero is safe.
    zenfmt_free(empty);
    zenfmt_free(0);
}

test "an empty document converts and its artifact view is empty, not absent" {
    defer result_mod.freeAll();
    const request = upload(simple_request);
    const handle = zenfmt_convert(request, @intCast(simple_request.len), 0, 0);
    defer zenfmt_free(request);
    defer _ = zenfmt_result_free(handle);

    try testing.expectEqual(exports.status_success, zenfmt_result_status(handle));
    const ptr = zenfmt_result_view_ptr(handle, @intFromEnum(exports.View.artifact), 0);
    // Present but empty: a real address with zero length, so a host never has
    // to inspect a length to tell "empty" from "missing".
    try testing.expect(ptr != exports.failure);
    try testing.expectEqual(
        @as(u32, 0),
        zenfmt_result_view_len(handle, @intFromEnum(exports.View.artifact), 0),
    );
}

test "a malformed request is a result with an explanation, not a null handle" {
    defer result_mod.freeAll();
    const bad = "not json at all";
    const request = upload(bad);
    const handle = zenfmt_convert(request, @intCast(bad.len), 0, 0);
    defer zenfmt_free(request);
    defer _ = zenfmt_result_free(handle);

    try testing.expect(handle != exports.failure);
    try testing.expectEqual(
        exports.status_invalid_request,
        zenfmt_result_status(handle),
    );
    const reports = readView(handle, .reports_json, 0).?;
    try testing.expect(std.mem.indexOf(u8, reports, "browser.malformed-request") != null);
}

test "an unconvertible document fails with reports and no artifact" {
    defer result_mod.freeAll();
    const document = "\x00\x01\x02 not a document \xff";
    const request = upload(simple_request);
    const input = upload(document);
    const handle = zenfmt_convert(
        request,
        @intCast(simple_request.len),
        input,
        @intCast(document.len),
    );
    defer zenfmt_free(request);
    defer zenfmt_free(input);
    defer _ = zenfmt_result_free(handle);

    try testing.expectEqual(exports.status_failed, zenfmt_result_status(handle));
    try testing.expect(readView(handle, .artifact, 0) == null);
    try testing.expect(readView(handle, .reports_json, 0).?.len > 2);
}

test "the accounting exports return to baseline across many cycles" {
    defer result_mod.freeAll();
    const before = zenfmt_live_bytes();
    try testing.expectEqual(@as(u32, 0), zenfmt_live_results());

    for (0..250) |_| {
        const request = upload(simple_request);
        const input = upload("# Title\n\nSome body text to convert.\n");
        const handle = zenfmt_convert(
            request,
            @intCast(simple_request.len),
            input,
            @intCast("# Title\n\nSome body text to convert.\n".len),
        );
        try testing.expectEqual(@as(u32, 1), zenfmt_live_results());
        try testing.expectEqual(@as(u32, 0), zenfmt_result_free(handle));
        zenfmt_free(request);
        zenfmt_free(input);
    }

    try testing.expectEqual(before, zenfmt_live_bytes());
    try testing.expectEqual(@as(u32, 0), zenfmt_live_results());
    // The high-water mark only ever rises, which is what makes it useful to a
    // host deciding when to recycle its worker.
    try testing.expect(zenfmt_high_water_pages() >= zenfmt_memory_pages());
}

test "a document above the browser profile is refused as a limit failure" {
    defer result_mod.freeAll();
    const profile = @import("profile.zig");
    const oversize = profile.browser.max_input_bytes + 1;
    // Allocating 32 MiB to prove a refusal would be wasteful; lowering the
    // limit for one request exercises the same path honestly.
    const request =
        \\{"schema":1,"name":"note.md","limits":{"max_input_bytes":8}}
    ;
    const request_ptr = upload(request);
    const document = "# This document is longer than eight bytes\n";
    const input = upload(document);
    const handle = zenfmt_convert(
        request_ptr,
        @intCast(request.len),
        input,
        @intCast(document.len),
    );
    defer zenfmt_free(request_ptr);
    defer zenfmt_free(input);
    defer _ = zenfmt_result_free(handle);

    try testing.expect(oversize > 0);
    try testing.expectEqual(exports.status_failed, zenfmt_result_status(handle));
    const reports = readView(handle, .reports_json, 0).?;
    try testing.expect(std.mem.indexOf(u8, reports, "input-too-large") != null);
}
