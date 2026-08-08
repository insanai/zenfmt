//! Typed plugin preservation boundary (ZDS 0013, Core Contract Repairs).
//!
//! Reader-owned JSON is bounded, parsed, and canonicalized once. Contexts
//! receive only their selected namespace entry; unknown namespaces remain
//! opaque and round-trip in bytewise id order.

const std = @import("std");
const assert = std.debug.assert;
const ast = @import("ast.zig");
const json = @import("json.zig");
const limits_mod = @import("limits.zig");
const manifest = @import("manifest.zig");
const plugin = @import("plugin.zig");

pub const Error = error{
    OutOfMemory,
    TooLarge,
    InvalidJson,
    VersionMismatch,
};

pub fn canonicalize(
    arena: std.mem.Allocator,
    descriptor: plugin.ReaderDescriptor,
    own: ?plugin.ReadContext.OwnPluginData,
    limits: limits_mod.Limits,
) Error!?plugin.ReadContext.OwnPluginData {
    const value = own orelse return null;
    if (descriptor.data_version == 0 or value.version != descriptor.data_version) {
        return error.VersionMismatch;
    }
    if (value.data.len > limits.max_plugin_data_bytes) return error.TooLarge;
    const parsed = json.parse(
        arena,
        value.data,
        limits.max_plugin_data_bytes,
        limits.max_manifest_depth,
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidJson,
    };
    var stream = json.WriteStream.init(arena);
    defer stream.deinit();
    json.writeValue(&stream, parsed) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidJson,
    };
    const canonical = stream.toOwnedSlice() catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidJson,
    };
    if (canonical.len > limits.max_plugin_data_bytes) return error.TooLarge;
    return .{ .version = value.version, .data = canonical };
}

pub fn merge(
    arena: std.mem.Allocator,
    carried: []const manifest.PluginEntry,
    reader_id: []const u8,
    own: ?plugin.ReadContext.OwnPluginData,
) error{OutOfMemory}![]const manifest.PluginEntry {
    var merged: std.ArrayList(manifest.PluginEntry) = .empty;
    for (carried) |carried_entry| {
        if (own != null and std.mem.eql(u8, carried_entry.id, reader_id)) continue;
        try merged.append(arena, carried_entry);
    }
    if (own) |value| {
        try merged.append(arena, .{
            .id = reader_id,
            .version = value.version,
            .data = value.data,
        });
    }
    std.mem.sort(manifest.PluginEntry, merged.items, {}, entryLessThan);
    return merged.items;
}

pub fn carry(
    arena: std.mem.Allocator,
    store: *ast.Store,
    loaded: ?manifest.Loaded,
) error{OutOfMemory}!ast.PluginDataRange {
    const value = loaded orelse return .empty;
    const start: u32 = @intCast(store.plugin_namespaces.items.len);
    for (value.plugins) |plugin_entry| {
        const id_start: u32 = @intCast(store.text.items.len);
        try store.text.appendSlice(arena, plugin_entry.id);
        const json_start: u32 = @intCast(store.raw.items.len);
        try store.raw.appendSlice(arena, plugin_entry.data);
        try store.plugin_namespaces.append(arena, .{
            .id = .{ .start = id_start, .len = @intCast(plugin_entry.id.len) },
            .version = @intCast(@max(plugin_entry.version, 0)),
            .json = .{ .start = json_start, .len = @intCast(plugin_entry.data.len) },
        });
    }
    assert(value.plugins.len <= std.math.maxInt(u32));
    return .{ .start = start, .len = @intCast(value.plugins.len) };
}

pub fn entry(
    loaded: ?manifest.Loaded,
    plugin_id: []const u8,
    data_version: u32,
) ?manifest.PluginEntry {
    if (data_version == 0) return null;
    const value = loaded orelse return null;
    for (value.plugins) |plugin_entry| {
        if (!std.mem.eql(u8, plugin_entry.id, plugin_id)) continue;
        if (plugin_entry.version != data_version) return null;
        return plugin_entry;
    }
    return null;
}

fn entryLessThan(
    _: void,
    lhs: manifest.PluginEntry,
    rhs: manifest.PluginEntry,
) bool {
    return std.mem.order(u8, lhs.id, rhs.id) == .lt;
}
