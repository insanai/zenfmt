//! The embedded web interface (ZDS 0016, The Web Interface).
//!
//! Four artifacts, embedded at compile time and served from memory: the
//! static shell, the fixed glue, the generated stylesheet, and the ui
//! module compiled to WebAssembly. Asset names carry content hashes and
//! are immutable; the shell is rendered once at startup with those names
//! resolved. Nothing at request time reads a filesystem, so path
//! traversal has no target.

const std = @import("std");
const assert = std.debug.assert;
const zenserve = @import("zenserve");

const app_mod = @import("app.zig");
const reports = @import("reports.zig");

const Context = zenserve.Context;
const HandlerError = zenserve.HandlerError;

const shell_template = @embedFile("ui_shell");
const glue_js = @embedFile("ui_glue");
const stylesheet = @embedFile("ui_css");
const ui_wasm = @embedFile("ui_wasm");

/// The record's exact content security policy: `'wasm-unsafe-eval'` is the
/// price of instantiating WebAssembly and permits no JavaScript eval.
pub const content_security_policy =
    "default-src 'self'; script-src 'self' 'wasm-unsafe-eval'; " ++
    "style-src 'self'; img-src 'self' data:; connect-src 'self'; " ++
    "frame-ancestors 'none'";

const hash_hex_len = 16;

const AssetName = struct {
    buf: [64]u8,
    len: usize,

    fn slice(name: *const AssetName) []const u8 {
        return name.buf[0..name.len];
    }
};

/// The rendered shell and the hash-suffixed asset names, computed once at
/// startup.
pub const Assets = struct {
    shell_html: []const u8,
    css_name: AssetName,
    js_name: AssetName,
    wasm_name: AssetName,

    pub fn init(gpa: std.mem.Allocator) !Assets {
        var assets: Assets = .{
            .shell_html = &.{},
            .css_name = assetName("zenfmt-ui-", ".css", stylesheet),
            .js_name = assetName("zenfmt-ui-", ".js", glue_js),
            .wasm_name = assetName("zenfmt-ui-", ".wasm", ui_wasm),
        };
        assets.shell_html = try renderShell(gpa, &assets);
        return assets;
    }

    pub fn deinit(assets: *Assets, gpa: std.mem.Allocator) void {
        gpa.free(assets.shell_html);
        assets.* = undefined;
    }

    /// The asset bytes and content type for a hash-suffixed name, or null.
    pub fn lookup(assets: *const Assets, name: []const u8) ?struct {
        bytes: []const u8,
        content_type: []const u8,
    } {
        if (std.mem.eql(u8, name, assets.css_name.slice())) {
            return .{ .bytes = stylesheet, .content_type = "text/css; charset=utf-8" };
        }
        if (std.mem.eql(u8, name, assets.js_name.slice())) {
            return .{ .bytes = glue_js, .content_type = "text/javascript; charset=utf-8" };
        }
        if (std.mem.eql(u8, name, assets.wasm_name.slice())) {
            return .{ .bytes = ui_wasm, .content_type = "application/wasm" };
        }
        return null;
    }
};

fn assetName(prefix: []const u8, suffix: []const u8, bytes: []const u8) AssetName {
    var name: AssetName = .{ .buf = undefined, .len = 0 };
    const digest = std.hash.Wyhash.hash(0, bytes);
    var hex: [hash_hex_len]u8 = undefined;
    const alphabet = "0123456789abcdef";
    var value = digest;
    var i: usize = hash_hex_len;
    while (i > 0) {
        i -= 1;
        hex[i] = alphabet[@intCast(value & 0xf)];
        value >>= 4;
    }
    assert(prefix.len + hex.len + suffix.len <= name.buf.len);
    @memcpy(name.buf[0..prefix.len], prefix);
    @memcpy(name.buf[prefix.len..][0..hex.len], &hex);
    @memcpy(name.buf[prefix.len + hex.len ..][0..suffix.len], suffix);
    name.len = prefix.len + hex.len + suffix.len;
    return name;
}

/// Replaces the shell's `{{CSS}}`, `{{JS}}`, and `{{WASM}}` placeholders
/// with the immutable asset paths.
fn renderShell(gpa: std.mem.Allocator, assets: *const Assets) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    var rest: []const u8 = shell_template;
    while (std.mem.indexOf(u8, rest, "{{")) |start| {
        try out.writer.writeAll(rest[0..start]);
        const end = std.mem.indexOf(u8, rest[start..], "}}") orelse return error.BadShell;
        const key = rest[start + 2 .. start + end];
        const name = if (std.mem.eql(u8, key, "CSS"))
            assets.css_name.slice()
        else if (std.mem.eql(u8, key, "JS"))
            assets.js_name.slice()
        else if (std.mem.eql(u8, key, "WASM"))
            assets.wasm_name.slice()
        else
            return error.BadShell;
        try out.writer.writeAll("/assets/");
        try out.writer.writeAll(name);
        rest = rest[start + end + 2 ..];
    }
    try out.writer.writeAll(rest);
    return out.toOwnedSlice();
}

// ------------------------------------------------------------- handlers

pub fn shellHandler(ctx: *Context) HandlerError!void {
    const app = ctx.appAs(app_mod.App);
    if (!app.options.ui) {
        return app_mod.respondEntry(ctx, reports.unknown_route, &.{});
    }
    try ctx.respondBytes(.ok, &.{
        .{ .name = "content-type", .value = "text/html; charset=utf-8" },
        .{ .name = "content-security-policy", .value = content_security_policy },
        .{ .name = "cache-control", .value = "no-cache" },
    }, app.assets.shell_html);
}

pub fn assetHandler(ctx: *Context) HandlerError!void {
    const app = ctx.appAs(app_mod.App);
    if (!app.options.ui) {
        return app_mod.respondEntry(ctx, reports.unknown_route, &.{});
    }
    const name = ctx.param orelse {
        return app_mod.respondEntry(ctx, reports.unknown_route, &.{});
    };
    const asset = app.assets.lookup(name) orelse {
        return app_mod.respondEntry(ctx, reports.unknown_route, &.{});
    };
    try ctx.respondBytes(.ok, &.{
        .{ .name = "content-type", .value = asset.content_type },
        .{ .name = "cache-control", .value = "public, max-age=31536000, immutable" },
    }, asset.bytes);
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

test "the embedded stylesheet matches the manifest digest" {
    // MANIFEST.md pins this digest; a stylesheet regeneration is a
    // reviewed diff of file plus digest, never a silent swap.
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(stylesheet, &digest, .{});
    var hex: [64]u8 = undefined;
    for (digest, 0..) |byte, i| {
        const alphabet = "0123456789abcdef";
        hex[i * 2] = alphabet[byte >> 4];
        hex[i * 2 + 1] = alphabet[byte & 0xf];
    }
    try testing.expectEqualStrings(
        "47cd982f46d31034f114e5c6c43a30dcec6e27e1dbb692c2f99038f83086629a",
        &hex,
    );
}

test "asset names are stable, distinct, and well-formed" {
    var assets = try Assets.init(testing.allocator);
    defer assets.deinit(testing.allocator);
    const css = assets.css_name.slice();
    const js = assets.js_name.slice();
    const wasm = assets.wasm_name.slice();
    try testing.expect(std.mem.startsWith(u8, css, "zenfmt-ui-"));
    try testing.expect(std.mem.endsWith(u8, css, ".css"));
    try testing.expect(std.mem.endsWith(u8, js, ".js"));
    try testing.expect(std.mem.endsWith(u8, wasm, ".wasm"));
    try testing.expect(!std.mem.eql(u8, css, js));
}

test "the rendered shell references every asset and keeps the noscript page" {
    var assets = try Assets.init(testing.allocator);
    defer assets.deinit(testing.allocator);
    const html = assets.shell_html;
    try testing.expect(std.mem.indexOf(u8, html, "{{") == null);
    try testing.expect(std.mem.indexOf(u8, html, assets.css_name.slice()) != null);
    try testing.expect(std.mem.indexOf(u8, html, assets.js_name.slice()) != null);
    try testing.expect(std.mem.indexOf(u8, html, assets.wasm_name.slice()) != null);
    try testing.expect(std.mem.indexOf(u8, html, "<noscript>") != null);
    try testing.expect(std.mem.indexOf(u8, html, "curl -s -T") != null);
}

test "lookup answers exactly the three assets" {
    var assets = try Assets.init(testing.allocator);
    defer assets.deinit(testing.allocator);
    try testing.expect(assets.lookup(assets.css_name.slice()) != null);
    try testing.expect(assets.lookup(assets.wasm_name.slice()) != null);
    try testing.expect(assets.lookup("nope.css") == null);
    try testing.expectEqualStrings(
        "application/wasm",
        assets.lookup(assets.wasm_name.slice()).?.content_type,
    );
}
