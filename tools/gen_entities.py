#!/usr/bin/env python3
"""Generates formats/html/src/entities.zig from the WHATWG entity registry.

Usage:
    curl -sL https://html.spec.whatwg.org/entities.json -o /tmp/entities.json
    python3 tools/gen_entities.py /tmp/entities.json > formats/html/src/entities.zig

The output is deterministic: entries are sorted bytewise by name, and every
value is spelled with explicit \\u{...} escapes, so regenerating from the
same registry snapshot reproduces the file byte-for-byte.
"""

import json
import sys


def zig_string(codepoints: list[int]) -> str:
    parts = []
    for cp in codepoints:
        if cp == 0x22:
            parts.append('\\"')
        elif cp == 0x5C:
            parts.append("\\\\")
        elif 0x20 <= cp < 0x7F:
            parts.append(chr(cp))
        else:
            parts.append(f"\\u{{{cp:x}}}")
    return '"' + "".join(parts) + '"'


def main() -> None:
    with open(sys.argv[1]) as handle:
        registry = json.load(handle)

    named = {}
    legacy = {}
    for key, value in registry.items():
        assert key.startswith("&")
        if key.endswith(";"):
            named[key[1:-1]] = value["codepoints"]
        else:
            legacy[key[1:]] = value["codepoints"]

    print("//! GENERATED FILE — do not edit by hand.")
    print("//!")
    print("//! WHATWG named character references, from")
    print("//! https://html.spec.whatwg.org/entities.json.")
    print("//! Regenerate with tools/gen_entities.py (see its header for the")
    print("//! exact command); output is deterministic for a given snapshot.")
    print()
    print("pub const Entity = struct { name: []const u8, value: []const u8 };")
    print()
    print("/// Semicolon-terminated references, sorted bytewise by name.")
    print("pub const named = [_]Entity{")
    for name in sorted(named):
        print(f"    .{{ .name = {zig_string([ord(c) for c in name])}, "
              f".value = {zig_string(named[name])} }},")
    print("};")
    print()
    print("/// The legacy subset that may appear without a trailing semicolon,")
    print("/// sorted bytewise by name. Longest name: "
          f"{max(len(k) for k in legacy)} bytes.")
    print("pub const legacy = [_]Entity{")
    for name in sorted(legacy):
        print(f"    .{{ .name = {zig_string([ord(c) for c in name])}, "
              f".value = {zig_string(legacy[name])} }},")
    print("};")
    print()
    print("""const std = @import("std");

fn find(table: []const Entity, name: []const u8) ?[]const u8 {
    var low: usize = 0;
    var high: usize = table.len;
    while (low < high) {
        const mid = low + (high - low) / 2;
        switch (std.mem.order(u8, table[mid].name, name)) {
            .lt => low = mid + 1,
            .gt => high = mid,
            .eq => return table[mid].value,
        }
    }
    return null;
}

/// Resolves a semicolon-terminated named reference (name given without
/// the `&` and `;`).
pub fn lookup(name: []const u8) ?[]const u8 {
    return find(&named, name);
}

/// Resolves a legacy reference that appeared without its semicolon.
pub fn lookupLegacy(name: []const u8) ?[]const u8 {
    return find(&legacy, name);
}

test "table is sorted and lookup finds boundary entries" {
    for (named[0 .. named.len - 1], named[1..]) |a, b| {
        try std.testing.expect(std.mem.order(u8, a.name, b.name) == .lt);
    }
    try std.testing.expectEqualStrings(named[0].value, lookup(named[0].name).?);
    const last = named[named.len - 1];
    try std.testing.expectEqualStrings(last.value, lookup(last.name).?);
    try std.testing.expect(lookup("nosuchentity") == null);
}""")


if __name__ == "__main__":
    main()
