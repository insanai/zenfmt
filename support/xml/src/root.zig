//! `zenfmt_xml`: a pull XML parser (ZDS 0002, The XML layer).
//!
//! Events, not trees: peak memory is proportional to depth, not document
//! size. The security posture is refusal — no DTD processing whatsoever (a
//! DOCTYPE rejects the document, making entity-expansion attacks
//! structurally impossible), no external entities, no I/O of any kind, the
//! five predefined entities and numeric character references only, and a
//! bounded element stack. Namespace prefixes resolve to URIs and elements
//! match on the URI, so a document binding `w:` to something else does not
//! get to impersonate WordprocessingML.

const std = @import("std");
const assert = std.debug.assert;

pub const max_depth_default: u32 = 256;

pub const Name = struct {
    /// Resolved namespace URI; empty when unbound.
    uri: []const u8,
    local: []const u8,

    pub fn is(name: Name, uri: []const u8, local: []const u8) bool {
        return std.mem.eql(u8, name.local, local) and std.mem.eql(u8, name.uri, uri);
    }
};

pub const Attribute = struct {
    name: Name,
    /// Decoded value; lives in the parser's arena.
    value: []const u8,
};

pub const Event = union(enum) {
    element_start: ElementStart,
    element_end: Name,
    /// Decoded character data. Adjacent runs may arrive separately.
    text: []const u8,
    done,
};

pub const ElementStart = struct {
    name: Name,
    attributes: []const Attribute,
    /// True for `<empty/>`; no matching `element_end` follows.
    self_closing: bool,
};

pub const Error = error{
    OutOfMemory,
    /// Structurally broken XML; `diagnose` describes the first problem.
    Malformed,
    /// A DOCTYPE declaration: never processed, always refused.
    DoctypeRefused,
    DepthLimitExceeded,
};

const Binding = struct {
    prefix: []const u8,
    uri: []const u8,
    depth: u32,
};

pub const Parser = struct {
    arena: std.mem.Allocator,
    bytes: []const u8,
    pos: usize = 0,
    max_depth: u32,
    /// Open element names, for end-tag matching.
    stack: std.ArrayList(Name) = .empty,
    /// Namespace bindings, popped by depth on element end.
    bindings: std.ArrayList(Binding) = .empty,
    attributes: std.ArrayList(Attribute) = .empty,
    /// Set when the parser saw a self-closing element and owes the caller
    /// nothing further for it.
    depth: u32 = 0,

    pub fn init(arena: std.mem.Allocator, bytes: []const u8, max_depth: u32) Parser {
        assert(max_depth >= 1);
        return .{ .arena = arena, .bytes = bytes, .max_depth = max_depth };
    }

    pub fn deinit(p: *Parser) void {
        p.stack.deinit(p.arena);
        p.bindings.deinit(p.arena);
        p.attributes.deinit(p.arena);
        p.* = undefined;
    }

    /// The next event. `text` and attribute values are decoded; markup
    /// declarations other than comments, CDATA, and the XML declaration
    /// are refused.
    pub fn next(p: *Parser) Error!Event {
        while (true) {
            if (p.pos >= p.bytes.len) {
                if (p.depth != 0) return error.Malformed;
                return .done;
            }
            if (p.bytes[p.pos] != '<') {
                return .{ .text = try p.readText() };
            }
            if (p.startsWith("<?")) {
                try p.skipUntil("?>");
                continue;
            }
            if (p.startsWith("<!--")) {
                try p.skipUntil("-->");
                continue;
            }
            if (p.startsWith("<![CDATA[")) {
                return .{ .text = try p.readCdata() };
            }
            if (p.startsWith("<!")) {
                // DOCTYPE and every other declaration: refused, not bounded.
                return error.DoctypeRefused;
            }
            if (p.startsWith("</")) {
                return .{ .element_end = try p.readEndTag() };
            }
            return .{ .element_start = try p.readStartTag() };
        }
    }

    /// Skips everything until the matching end of the current element.
    /// Balanced and bounded; used for elements a reader chooses to ignore.
    pub fn skipElement(p: *Parser) Error!void {
        const target = p.depth;
        assert(target >= 1);
        var guard: usize = 0;
        while (true) {
            guard += 1;
            assert(guard <= p.bytes.len + 1);
            switch (try p.next()) {
                .done => return error.Malformed,
                .element_end => if (p.depth < target) return,
                .element_start, .text => {},
            }
        }
    }

    fn startsWith(p: *Parser, comptime prefix: []const u8) bool {
        if (!std.mem.startsWith(u8, p.bytes[p.pos..], prefix)) return false;
        if (comptime std.mem.eql(u8, prefix, "<!")) return true;
        p.pos += prefix.len;
        return true;
    }

    fn skipUntil(p: *Parser, comptime marker: []const u8) Error!void {
        const index = std.mem.indexOfPos(u8, p.bytes, p.pos, marker) orelse
            return error.Malformed;
        p.pos = index + marker.len;
    }

    fn readCdata(p: *Parser) Error![]const u8 {
        const end = std.mem.indexOfPos(u8, p.bytes, p.pos, "]]>") orelse
            return error.Malformed;
        const content = p.bytes[p.pos..end];
        p.pos = end + 3;
        return content;
    }

    fn readText(p: *Parser) Error![]const u8 {
        const start = p.pos;
        const end = std.mem.indexOfScalarPos(u8, p.bytes, start, '<') orelse p.bytes.len;
        p.pos = end;
        const raw = p.bytes[start..end];
        if (std.mem.indexOfScalar(u8, raw, '&') == null) return raw;
        return try decodeEntities(p.arena, raw);
    }

    fn readEndTag(p: *Parser) Error!Name {
        const end = std.mem.indexOfScalarPos(u8, p.bytes, p.pos, '>') orelse
            return error.Malformed;
        const raw = std.mem.trim(u8, p.bytes[p.pos..end], " \t\r\n");
        p.pos = end + 1;
        if (p.depth == 0) return error.Malformed;

        const expected = p.stack.items[p.stack.items.len - 1];
        p.stack.items.len -= 1;
        p.depth -= 1;
        // Bindings opened by the closed element expire with it.
        while (p.bindings.items.len > 0 and
            p.bindings.items[p.bindings.items.len - 1].depth > p.depth)
        {
            p.bindings.items.len -= 1;
        }

        // The stack already holds the resolved name; matching the raw
        // local part is enough, and the closed element's bindings are
        // gone by now anyway.
        const local = if (std.mem.indexOfScalar(u8, raw, ':')) |colon|
            raw[colon + 1 ..]
        else
            raw;
        if (!std.mem.eql(u8, local, expected.local)) return error.Malformed;
        return expected;
    }

    fn readStartTag(p: *Parser) Error!ElementStart {
        assert(p.bytes[p.pos] == '<');
        p.pos += 1;
        const end = try p.findTagEnd();
        var raw = p.bytes[p.pos..end];
        p.pos = end + 1;
        var self_closing = false;
        if (raw.len > 0 and raw[raw.len - 1] == '/') {
            self_closing = true;
            raw = raw[0 .. raw.len - 1];
        }

        var cursor: usize = 0;
        const raw_name = readNameToken(raw, &cursor) orelse return error.Malformed;

        // First pass: namespace declarations bind before anything resolves.
        const binding_depth = p.depth + 1;
        var scan = cursor;
        p.attributes.clearRetainingCapacity();
        var raw_attrs: [max_attributes]RawAttribute = undefined;
        var raw_attr_count: usize = 0;
        while (true) {
            skipSpace(raw, &scan);
            if (scan >= raw.len) break;
            const attr_name = readNameToken(raw, &scan) orelse return error.Malformed;
            skipSpace(raw, &scan);
            if (scan >= raw.len or raw[scan] != '=') return error.Malformed;
            scan += 1;
            skipSpace(raw, &scan);
            const value_raw = readQuoted(raw, &scan) orelse return error.Malformed;
            const value = if (std.mem.indexOfScalar(u8, value_raw, '&') == null)
                value_raw
            else
                try decodeEntities(p.arena, value_raw);

            if (std.mem.eql(u8, attr_name, "xmlns")) {
                try p.bindings.append(p.arena, .{ .prefix = "", .uri = value, .depth = binding_depth });
            } else if (std.mem.startsWith(u8, attr_name, "xmlns:")) {
                try p.bindings.append(p.arena, .{
                    .prefix = attr_name["xmlns:".len..],
                    .uri = value,
                    .depth = binding_depth,
                });
            } else {
                if (raw_attr_count >= max_attributes) return error.Malformed;
                raw_attrs[raw_attr_count] = .{ .name = attr_name, .value = value };
                raw_attr_count += 1;
            }
        }

        // Second pass: resolve names now that this element's bindings are
        // in scope.
        const name = p.resolve(raw_name) orelse return error.Malformed;
        for (raw_attrs[0..raw_attr_count]) |raw_attr| {
            const resolved = p.resolveAttribute(raw_attr.name) orelse return error.Malformed;
            try p.attributes.append(p.arena, .{ .name = resolved, .value = raw_attr.value });
        }

        if (!self_closing) {
            if (p.depth >= p.max_depth) return error.DepthLimitExceeded;
            try p.stack.append(p.arena, name);
            p.depth += 1;
        } else {
            // Bindings scoped to a self-closing element expire at once.
            while (p.bindings.items.len > 0 and
                p.bindings.items[p.bindings.items.len - 1].depth > p.depth)
            {
                p.bindings.items.len -= 1;
            }
        }

        return .{
            .name = name,
            .attributes = p.attributes.items,
            .self_closing = self_closing,
        };
    }

    const max_attributes = 64;

    const RawAttribute = struct {
        name: []const u8,
        value: []const u8,
    };

    fn findTagEnd(p: *Parser) Error!usize {
        var i = p.pos;
        var quote: u8 = 0;
        while (i < p.bytes.len) : (i += 1) {
            const byte = p.bytes[i];
            if (quote != 0) {
                if (byte == quote) quote = 0;
            } else if (byte == '"' or byte == '\'') {
                quote = byte;
            } else if (byte == '>') {
                return i;
            }
        }
        return error.Malformed;
    }

    fn resolve(p: *Parser, raw: []const u8) ?Name {
        if (std.mem.indexOfScalar(u8, raw, ':')) |colon| {
            const prefix = raw[0..colon];
            const local = raw[colon + 1 ..];
            if (local.len == 0 or prefix.len == 0) return null;
            return .{ .uri = p.lookup(prefix) orelse return null, .local = local };
        }
        return .{ .uri = p.lookup("") orelse "", .local = raw };
    }

    /// Unprefixed attributes have no namespace, per the XML namespaces
    /// specification — the default namespace does not apply to them.
    fn resolveAttribute(p: *Parser, raw: []const u8) ?Name {
        if (std.mem.indexOfScalar(u8, raw, ':')) |colon| {
            const prefix = raw[0..colon];
            const local = raw[colon + 1 ..];
            if (local.len == 0 or prefix.len == 0) return null;
            return .{ .uri = p.lookup(prefix) orelse return null, .local = local };
        }
        return .{ .uri = "", .local = raw };
    }

    fn lookup(p: *Parser, prefix: []const u8) ?[]const u8 {
        if (std.mem.eql(u8, prefix, "xml")) {
            return "http://www.w3.org/XML/1998/namespace";
        }
        var i = p.bindings.items.len;
        while (i > 0) {
            i -= 1;
            if (std.mem.eql(u8, p.bindings.items[i].prefix, prefix)) {
                return p.bindings.items[i].uri;
            }
        }
        return if (prefix.len == 0) "" else null;
    }
};

fn skipSpace(raw: []const u8, cursor: *usize) void {
    while (cursor.* < raw.len) : (cursor.* += 1) {
        switch (raw[cursor.*]) {
            ' ', '\t', '\r', '\n' => {},
            else => return,
        }
    }
}

fn readNameToken(raw: []const u8, cursor: *usize) ?[]const u8 {
    const start = cursor.*;
    while (cursor.* < raw.len) : (cursor.* += 1) {
        switch (raw[cursor.*]) {
            ' ', '\t', '\r', '\n', '=', '/', '>' => break,
            else => {},
        }
    }
    if (cursor.* == start) return null;
    return raw[start..cursor.*];
}

fn readQuoted(raw: []const u8, cursor: *usize) ?[]const u8 {
    if (cursor.* >= raw.len) return null;
    const quote = raw[cursor.*];
    if (quote != '"' and quote != '\'') return null;
    cursor.* += 1;
    const start = cursor.*;
    while (cursor.* < raw.len) : (cursor.* += 1) {
        if (raw[cursor.*] == quote) {
            const value = raw[start..cursor.*];
            cursor.* += 1;
            return value;
        }
    }
    return null;
}

/// The five predefined entities and numeric character references; nothing
/// else exists, because there is no DTD to define anything else.
fn decodeEntities(arena: std.mem.Allocator, raw: []const u8) Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(arena);
    var i: usize = 0;
    while (i < raw.len) {
        if (raw[i] != '&') {
            try out.append(arena, raw[i]);
            i += 1;
            continue;
        }
        const semi = std.mem.indexOfScalarPos(u8, raw[0..@min(raw.len, i + 12)], i, ';') orelse
            return error.Malformed;
        const body = raw[i + 1 .. semi];
        if (std.mem.eql(u8, body, "amp")) {
            try out.append(arena, '&');
        } else if (std.mem.eql(u8, body, "lt")) {
            try out.append(arena, '<');
        } else if (std.mem.eql(u8, body, "gt")) {
            try out.append(arena, '>');
        } else if (std.mem.eql(u8, body, "quot")) {
            try out.append(arena, '"');
        } else if (std.mem.eql(u8, body, "apos")) {
            try out.append(arena, '\'');
        } else if (body.len > 1 and body[0] == '#') {
            const code = if (body[1] == 'x' or body[1] == 'X')
                std.fmt.parseInt(u21, body[2..], 16) catch return error.Malformed
            else
                std.fmt.parseInt(u21, body[1..], 10) catch return error.Malformed;
            if (code == 0 or code > 0x10ffff) return error.Malformed;
            if (code >= 0xd800 and code <= 0xdfff) return error.Malformed;
            var encoded: [4]u8 = undefined;
            const length = std.unicode.utf8Encode(code, &encoded) catch return error.Malformed;
            try out.appendSlice(arena, encoded[0..length]);
        } else {
            return error.Malformed;
        }
        i = semi + 1;
    }
    return out.toOwnedSlice(arena);
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

test "elements, attributes, and namespaces resolve to URIs" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var parser = Parser.init(
        arena_state.allocator(),
        "<w:doc xmlns:w=\"http://w\" w:val=\"a&amp;b\"><w:p/>text</w:doc>",
        16,
    );

    const start = (try parser.next()).element_start;
    try testing.expect(start.name.is("http://w", "doc"));
    try testing.expectEqual(@as(usize, 1), start.attributes.len);
    try testing.expect(start.attributes[0].name.is("http://w", "val"));
    try testing.expectEqualStrings("a&b", start.attributes[0].value);

    const child = (try parser.next()).element_start;
    try testing.expect(child.self_closing);
    try testing.expect(child.name.is("http://w", "p"));

    try testing.expectEqualStrings("text", (try parser.next()).text);
    _ = (try parser.next()).element_end;
    try testing.expectEqual(Event.done, try parser.next());
}

test "a DOCTYPE is refused outright" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var parser = Parser.init(
        arena_state.allocator(),
        "<!DOCTYPE lolz [<!ENTITY lol \"lol\">]><r>&lol;</r>",
        16,
    );
    try testing.expectError(error.DoctypeRefused, parser.next());
}

test "depth beyond the limit is refused" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var parser = Parser.init(arena_state.allocator(), "<a><a><a><a>", 3);
    _ = try parser.next();
    _ = try parser.next();
    _ = try parser.next();
    try testing.expectError(error.DepthLimitExceeded, parser.next());
}

test "mismatched or unclosed tags are malformed" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var parser = Parser.init(arena_state.allocator(), "<a><b></a></b>", 16);
    _ = try parser.next();
    _ = try parser.next();
    try testing.expectError(error.Malformed, parser.next());

    var unclosed = Parser.init(arena_state.allocator(), "<a>text", 16);
    _ = try unclosed.next();
    _ = try unclosed.next();
    try testing.expectError(error.Malformed, unclosed.next());
}

test "cdata and numeric references decode" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var parser = Parser.init(
        arena_state.allocator(),
        "<r><![CDATA[<raw&stuff>]]>&#x41;&#66;</r>",
        16,
    );
    _ = try parser.next();
    try testing.expectEqualStrings("<raw&stuff>", (try parser.next()).text);
    try testing.expectEqualStrings("AB", (try parser.next()).text);
    _ = try parser.next();
}
