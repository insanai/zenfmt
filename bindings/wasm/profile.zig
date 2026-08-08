//! The browser resource-limit profile (ZDS 0015, Browser profile and memory
//! limits).
//!
//! The profile is derived from the engine defaults rather than restated, so a
//! limit added to the engine later inherits its engine value here until this
//! file deliberately lowers it. A restated table would silently omit the new
//! field and leave the browser running an unbounded one.
//!
//! A caller may lower any of these. Raising one is refused with a report
//! rather than clamped: the browser profile is where the browser stops, and a
//! caller who asked for more should be told to use the command-line tool, not
//! given a smaller number than they asked for and left to wonder.

const std = @import("std");
const core = @import("zenfmt_core");

/// The limits a browser conversion runs under.
///
/// Each lowered value is chosen against one worst case: the page holds the
/// input, the module holds its own copy, and the artifact accumulates in the
/// conversion arena, all inside a worker whose linear memory can never
/// shrink. The record derives the aggregate bound these compose to.
pub const browser: core.Limits = limits: {
    var values: core.Limits = .{};
    values.max_input_bytes = 32 * 1024 * 1024;
    values.max_total_uncompressed = 128 * 1024 * 1024;
    values.max_entry_uncompressed = 64 * 1024 * 1024;
    values.max_decoded_text_bytes = 64 * 1024 * 1024;
    values.max_resource_bytes = 32 * 1024 * 1024;
    values.max_output_bytes = 64 * 1024 * 1024;
    values.max_nodes = 2_000_000;
    values.max_facet_rows = 131_072;
    values.max_lowering_work = 8 * 1024 * 1024;
    break :limits values;
};

pub const Field = core.Limits.Field;

/// Applies caller overrides to the browser profile.
///
/// Returns the first field the caller tried to raise, or null on success.
/// Walking the struct fields rather than a name table means a limit added to
/// the engine is override-able here the day it exists.
pub fn apply(
    values: *core.Limits,
    name: []const u8,
    requested: u64,
) ?Field {
    inline for (@typeInfo(core.Limits).@"struct".fields) |field| {
        if (std.mem.eql(u8, field.name, name)) {
            const ceiling: u64 = @field(browser, field.name);
            if (requested > ceiling) return @field(Field, field.name);
            const narrowed = std.math.cast(field.type, requested) orelse
                return @field(Field, field.name);
            @field(values, field.name) = narrowed;
            return null;
        }
    }
    return null;
}

/// Whether `name` is a limit the engine knows. Separated from `apply` so an
/// unknown name and an out-of-range value produce different reports.
pub fn known(name: []const u8) bool {
    inline for (@typeInfo(core.Limits).@"struct".fields) |field| {
        if (std.mem.eql(u8, field.name, name)) return true;
    }
    return false;
}

test "every browser limit is at or below the engine default" {
    const defaults: core.Limits = .{};
    inline for (@typeInfo(core.Limits).@"struct".fields) |field| {
        const browser_value: u64 = @field(browser, field.name);
        const default_value: u64 = @field(defaults, field.name);
        try std.testing.expect(browser_value <= default_value);
    }
}

test "the browser profile is a valid limit configuration" {
    try std.testing.expectEqual(@as(?Field, null), browser.invalidField());
}

test "an override may lower a limit" {
    var values = browser;
    try std.testing.expectEqual(@as(?Field, null), apply(&values, "max_nodes", 1000));
    try std.testing.expectEqual(@as(u32, 1000), values.max_nodes);
}

test "an override may not raise a limit above the browser profile" {
    var values = browser;
    const refused = apply(&values, "max_input_bytes", 64 * 1024 * 1024);
    try std.testing.expectEqual(Field.max_input_bytes, refused.?);
    // And the value is left alone rather than partially applied.
    try std.testing.expectEqual(browser.max_input_bytes, values.max_input_bytes);
}

test "an override wider than the field's type is refused, not truncated" {
    var values = browser;
    // Within the browser ceiling for no field, and far past a u32 field.
    const refused = apply(&values, "max_nodes", std.math.maxInt(u64));
    try std.testing.expectEqual(Field.max_nodes, refused.?);
}

test "unknown limit names are distinguishable from refusals" {
    try std.testing.expect(known("max_nodes"));
    try std.testing.expect(!known("max_unicorns"));
}
