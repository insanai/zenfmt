//! Structural agreement between the browser adapter and its declarations
//! (ZDS 0015, Distribution shape).
//!
//! This is not a type checker, and does not pretend to be one. A type checker
//! for TypeScript declarations would require the JavaScript toolchain this
//! project deliberately does not have.
//!
//! What it does check is the drift that actually happens: a function renamed
//! in one file and not the other, an export added without a declaration, a
//! declared name that no longer exists, and an ABI constant written into the
//! declarations by hand that no longer matches the Zig definition. Those are
//! the mistakes a release would otherwise ship.
//!
//! It is honest about its limits: a wrong *type* in the declarations passes
//! here. That is stated in the declarations file itself rather than implied.

const std = @import("std");
const Io = std.Io;
const exports = @import("zenfmt_wasm_exports");

const Names = std.ArrayHashMapUnmanaged(
    []const u8,
    void,
    std.array_hash_map.StringContext,
    true,
);

pub fn main(init: std.process.Init) !u8 {
    var arena_instance = std.heap.ArenaAllocator.init(init.gpa);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();
    const io = init.io;

    var iterator = std.process.Args.Iterator.init(init.minimal.args);
    defer iterator.deinit();
    _ = iterator.next();

    const js_path = iterator.next() orelse return usage();
    const dts_path = iterator.next() orelse return usage();

    const js = try read(arena, io, js_path);
    const dts = try read(arena, io, dts_path);

    var implemented: Names = .empty;
    var declared: Names = .empty;
    try collectImplemented(arena, js, &implemented);
    try collectDeclared(arena, dts, &declared);

    var failures: u32 = 0;
    failures += try compare(&implemented, &declared, "implemented but not declared");
    failures += try compare(&declared, &implemented, "declared but not implemented");
    failures += checkAbiConstants(dts);

    if (failures != 0) {
        std.debug.print("dts-check: {d} problem(s)\n", .{failures});
        return 1;
    }
    std.debug.print(
        "dts-check: {d} exported names agree between {s} and {s}\n",
        .{ implemented.count(), js_path, dts_path },
    );
    return 0;
}

fn usage() u8 {
    std.debug.print("usage: dts-check <zenfmt.js> <zenfmt.d.ts>\n", .{});
    return 2;
}

fn read(arena: std.mem.Allocator, io: Io, path: []const u8) ![]const u8 {
    return Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(4 * 1024 * 1024)) catch |err| {
        std.debug.print("dts-check: cannot read {s}: {s}\n", .{ path, @errorName(err) });
        return error.Unreadable;
    };
}

/// `export class NAME`, `export function NAME`, `export async function NAME`,
/// and `export const NAME`.
fn collectImplemented(arena: std.mem.Allocator, source: []const u8, out: *Names) !void {
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (!std.mem.startsWith(u8, trimmed, "export ")) continue;
        var rest = trimmed["export ".len..];
        rest = stripPrefix(rest, "async ");
        const name = if (stripKeyword(rest, "class")) |value|
            value
        else if (stripKeyword(rest, "function")) |value|
            value
        else if (stripKeyword(rest, "const")) |value|
            value
        else
            continue;
        try out.put(arena, try arena.dupe(u8, name), {});
    }
}

/// `export declare class|function|const NAME` and `export interface NAME`.
/// Interfaces are collected too: they are part of the published surface a
/// caller reads, and one deleted from the adapter's result shape should not
/// linger here.
fn collectDeclared(arena: std.mem.Allocator, source: []const u8, out: *Names) !void {
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (!std.mem.startsWith(u8, trimmed, "export ")) continue;
        var rest = trimmed["export ".len..];
        // Interfaces describe shapes rather than runtime values, so they are
        // not expected to exist in the adapter and are not compared.
        if (stripKeyword(rest, "interface") != null) continue;
        rest = stripPrefix(rest, "declare ");
        rest = stripPrefix(rest, "async ");
        const name = if (stripKeyword(rest, "class")) |value|
            value
        else if (stripKeyword(rest, "function")) |value|
            value
        else if (stripKeyword(rest, "const")) |value|
            value
        else
            continue;
        try out.put(arena, try arena.dupe(u8, name), {});
    }
}

fn stripPrefix(text: []const u8, prefix: []const u8) []const u8 {
    if (std.mem.startsWith(u8, text, prefix)) return text[prefix.len..];
    return text;
}

/// The identifier following `keyword `, or null when the line does not start
/// with it.
fn stripKeyword(text: []const u8, keyword: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, text, keyword)) return null;
    if (text.len <= keyword.len or text[keyword.len] != ' ') return null;
    const rest = text[keyword.len + 1 ..];
    var end: usize = 0;
    while (end < rest.len and isIdentifier(rest[end])) end += 1;
    if (end == 0) return null;
    return rest[0..end];
}

fn isIdentifier(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '$';
}

fn compare(from: *Names, to: *Names, problem: []const u8) !u32 {
    var failures: u32 = 0;
    for (from.keys()) |name| {
        if (!to.contains(name)) {
            std.debug.print("dts-check: '{s}' is {s}\n", .{ name, problem });
            failures += 1;
        }
    }
    return failures;
}

/// The declarations restate the ABI's status codes by hand. This is what
/// keeps that copy honest against the Zig definition.
fn checkAbiConstants(dts: []const u8) u32 {
    const expected = [_]struct { name: []const u8, value: u32 }{
        .{ .name = "statusSuccess", .value = exports.status_success },
        .{ .name = "statusFailed", .value = exports.status_failed },
        .{ .name = "statusInvalidRequest", .value = exports.status_invalid_request },
        .{ .name = "statusInvalidHandle", .value = exports.status_invalid_handle },
    };
    var failures: u32 = 0;
    for (expected) |entry| {
        if (std.mem.indexOf(u8, dts, entry.name) == null) {
            std.debug.print(
                "dts-check: the declarations do not mention '{s}'\n",
                .{entry.name},
            );
            failures += 1;
        }
    }
    return failures;
}

const testing = std.testing;

test "exported names are collected from the adapter" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var names: Names = .empty;
    try collectImplemented(arena.allocator(),
        \\export class Converter {
        \\export async function createConverter(options) {
        \\export function readSource(source) {
        \\export const abi = Object.freeze({
        \\  export nothing here
    , &names);
    try testing.expect(names.contains("Converter"));
    try testing.expect(names.contains("createConverter"));
    try testing.expect(names.contains("readSource"));
    try testing.expect(names.contains("abi"));
    try testing.expectEqual(@as(usize, 4), names.count());
}

test "declared names are collected and interfaces are excluded" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var names: Names = .empty;
    try collectDeclared(arena.allocator(),
        \\export declare class Converter {
        \\export declare function createConverter(options: {
        \\export interface Report {
        \\export declare const abi: {
    , &names);
    try testing.expect(names.contains("Converter"));
    try testing.expect(names.contains("createConverter"));
    try testing.expect(names.contains("abi"));
    // An interface is a shape, not a runtime value; the adapter has no such
    // name to agree with.
    try testing.expect(!names.contains("Report"));
}

test "a keyword without an identifier is not a name" {
    try testing.expectEqual(@as(?[]const u8, null), stripKeyword("class", "class"));
    try testing.expectEqual(@as(?[]const u8, null), stripKeyword("class ", "class"));
    try testing.expectEqual(@as(?[]const u8, null), stripKeyword("classy Thing", "class"));
    try testing.expectEqualStrings("Thing", stripKeyword("class Thing {", "class").?);
}
