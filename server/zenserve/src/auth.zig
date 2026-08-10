//! Authentication core (ZDS 0016, Authentication core).
//!
//! zenserve owns the mechanism; the application owns the storage. This file
//! defines the ordered role lattice, Argon2id password hashing behind PHC
//! strings, opaque 256-bit tokens stored only as SHA-256 digests, printable
//! API key ids, bearer credential parsing, and the `Store` vtable boundary
//! that the application implements over its own store. Nothing here touches
//! a network or a database; every mechanism is testable in isolation.

const std = @import("std");
const assert = std.debug.assert;
const argon2 = std.crypto.pwhash.argon2;
const Sha256 = std.crypto.hash.sha2.Sha256;

/// The principal's role. The values are ordered so a route check is one
/// comparison: `role.atLeast(required)`.
pub const Role = enum(u8) {
    anonymous = 0,
    user = 1,
    administrator = 2,

    /// Returns whether `role` meets or exceeds `required` in the order
    /// anonymous < user < administrator.
    pub fn atLeast(role: Role, required: Role) bool {
        return @intFromEnum(role) >= @intFromEnum(required);
    }
};

/// Opaque tokens are 256-bit values; they travel once and are stored only
/// as SHA-256 digests.
pub const token_bytes = 32;

/// The lowercase hex spelling of a token: two characters per byte.
pub const token_hex_len = token_bytes * 2;

/// The SHA-256 digest of a token or presented secret. Comparisons over
/// digests are constant-time (`digestEql`).
pub const Digest = [Sha256.digest_length]u8;

/// The random half of a printable key id before base32 encoding.
pub const key_id_bytes = 16;

/// Argon2id parameters: exactly `std.crypto.pwhash.argon2.Params.owasp_2id`
/// (t = 2, m = 19 MiB, p = 1), the OWASP interactive profile. PHC encoding
/// carries the parameters with each hash, so raising them later needs no
/// migration; this constant is the single citation point.
pub const password_params = argon2.Params.owasp_2id;

/// Enough room for an Argon2id PHC string with the pinned parameters: the
/// longest shape is `$argon2id$v=19$m=...,t=...,p=...$<salt>$<hash>` at
/// roughly 100 bytes; std defines no constant for it, so 128 is the bound.
pub const phc_buf_len = 128;

/// Hashes `password` with Argon2id under `password_params` and returns the
/// PHC-encoded string, a slice of `out`. The allocator serves argon2's
/// working memory (19 MiB) and is released before returning.
pub fn hashPassword(
    gpa: std.mem.Allocator,
    io: std.Io,
    password: []const u8,
    out: *[phc_buf_len]u8,
) ![]const u8 {
    assert(password.len > 0);
    return argon2.strHash(password, .{
        .allocator = gpa,
        .params = password_params,
        .mode = .argon2id,
    }, out, io);
}

/// Verifies `password` against the PHC string `phc`. Returns false on a
/// mismatch, a malformed hash, or an allocation failure; the caller cannot
/// distinguish the cases, and login paths equalize timing by verifying
/// against `dummy_phc` when no account matches.
pub fn verifyPassword(
    gpa: std.mem.Allocator,
    io: std.Io,
    phc: []const u8,
    password: []const u8,
) bool {
    argon2.strVerify(phc, password, .{ .allocator = gpa }, io) catch return false;
    return true;
}

/// A fixed, valid Argon2id PHC string for the password "zenfmt-dummy",
/// hashed once under `password_params` and pasted here so login paths can
/// burn the full verification cost when no account matches. Real inputs
/// never verify against it; the password itself never travels anywhere.
pub const dummy_phc: []const u8 =
    "$argon2id$v=19$m=19456,t=2,p=1$2FzXZS4BieRfl2263KTPlHxudVXdLLBSSgCZANFXuqY$B3DdVi62vF8ZMqcaxor4xYO2QBCl1P/edpLgnorZQFc";

/// A 256-bit opaque token: session tokens and API key secrets share this
/// shape. The raw bytes travel to the client exactly once, hex-encoded;
/// the server retains only the digest.
pub const Token = struct {
    bytes: [token_bytes]u8,

    /// Draws a fresh token from the Io interface's cryptographically
    /// secure generator.
    pub fn generate(io: std.Io) Token {
        var token: Token = undefined;
        io.random(&token.bytes);
        return token;
    }

    /// Returns the SHA-256 digest under which the token is stored.
    pub fn digest(token: Token) Digest {
        var out: Digest = undefined;
        Sha256.hash(&token.bytes, &out, .{});
        return out;
    }

    /// Writes the lowercase hex spelling into `out` and returns it.
    pub fn encode(token: Token, out: *[token_hex_len]u8) []const u8 {
        const alphabet = "0123456789abcdef";
        for (token.bytes, 0..) |byte, i| {
            out[i * 2] = alphabet[byte >> 4];
            out[i * 2 + 1] = alphabet[byte & 0x0f];
        }
        return out;
    }

    /// Parses a hex spelling back into a token. The length must be exactly
    /// `token_hex_len` and every character a hex digit (either case);
    /// anything else returns null.
    pub fn decode(text: []const u8) ?Token {
        if (text.len != token_hex_len) return null;
        var token: Token = undefined;
        for (0..token_bytes) |i| {
            const high = hexDigit(text[i * 2]) orelse return null;
            const low = hexDigit(text[i * 2 + 1]) orelse return null;
            token.bytes[i] = high << 4 | low;
        }
        return token;
    }
};

/// Returns the value of one hex digit in either case, or null.
fn hexDigit(char: u8) ?u8 {
    return switch (char) {
        '0'...'9' => char - '0',
        'a'...'f' => char - 'a' + 10,
        'A'...'F' => char - 'A' + 10,
        else => null,
    };
}

/// Constant-time digest comparison; the only permitted way to compare a
/// presented secret against a stored one.
pub fn digestEql(a: Digest, b: Digest) bool {
    return std.crypto.timing_safe.eql(Digest, a, b);
}

/// Returns the SHA-256 digest of an arbitrary presented secret text.
pub fn digestOf(text: []const u8) Digest {
    var out: Digest = undefined;
    Sha256.hash(text, &out, .{});
    return out;
}

/// The RFC 4648 base32 alphabet, lowercased; key ids use it unpadded.
const base32_alphabet = "abcdefghijklmnopqrstuvwxyz234567";

/// A printable API key id: "zfk_" followed by 26 lowercase base32
/// characters encoding 16 random bytes. The id is the public half of a
/// bearer credential; it selects the row, it authenticates nothing.
pub const KeyId = struct {
    text: [30]u8,

    const prefix = "zfk_";

    /// Draws a fresh id from the Io interface's secure generator.
    pub fn generate(io: std.Io) KeyId {
        var raw: [key_id_bytes]u8 = undefined;
        io.random(&raw);
        var id: KeyId = undefined;
        @memcpy(id.text[0..prefix.len], prefix);
        var accumulator: u16 = 0;
        var bits: u4 = 0;
        var written: usize = prefix.len;
        for (raw) |byte| {
            accumulator = accumulator << 8 | byte;
            bits += 8;
            while (bits >= 5) {
                bits -= 5;
                id.text[written] = base32_alphabet[(accumulator >> bits) & 0x1f];
                written += 1;
            }
        }
        assert(bits == 3);
        id.text[written] = base32_alphabet[@as(u5, @truncate(accumulator << (5 - bits)))];
        written += 1;
        assert(written == id.text.len);
        return id;
    }

    /// Returns the printable id text.
    pub fn slice(id: *const KeyId) []const u8 {
        return &id.text;
    }

    /// Returns whether `text` is shaped like a key id: the prefix plus 26
    /// characters of the lowercase base32 alphabet, nothing else.
    pub fn valid(text: []const u8) bool {
        if (text.len != 30) return false;
        if (!std.mem.startsWith(u8, text, prefix)) return false;
        for (text[prefix.len..]) |char| {
            if (std.mem.indexOfScalar(u8, base32_alphabet, char) == null) return false;
        }
        return true;
    }
};

/// A parsed bearer credential: the public id selects the key row and the
/// secret digest is compared in constant time against the stored digest.
pub const BearerKey = struct {
    id: []const u8,
    secret_digest: Digest,
};

/// Parses `zfk_<id>.<secret-hex>` from an Authorization Bearer value. The
/// id half must be a valid key id and the secret half a full token in hex;
/// any other shape returns null. The returned id borrows from `text`.
pub fn parseBearerKey(text: []const u8) ?BearerKey {
    const dot = std.mem.indexOfScalar(u8, text, '.') orelse return null;
    const id = text[0..dot];
    if (!KeyId.valid(id)) return null;
    const token = Token.decode(text[dot + 1 ..]) orelse return null;
    return .{ .id = id, .secret_digest = token.digest() };
}

/// A session descriptor as the store returns it; the token digest is the
/// lookup key and never lives here.
pub const Session = struct {
    user_id: i64,
    name_buf: [64]u8,
    name_len: u8,
    role: Role,
    absolute_expiry: i64,
    idle_expiry: i64,
    /// The owning account's state, joined at lookup so a disabled or
    /// must-change account is enforced without a second query.
    disabled: bool = false,
    must_change_password: bool = false,
    /// The per-session CSRF token, returned to the ui module after login.
    csrf_buf: [64]u8 = undefined,
    csrf_len: u8 = 0,

    /// Returns the account name.
    pub fn name(session: *const Session) []const u8 {
        assert(session.name_len <= session.name_buf.len);
        return session.name_buf[0..session.name_len];
    }

    /// Returns the CSRF token.
    pub fn csrf(session: *const Session) []const u8 {
        assert(session.csrf_len <= session.csrf_buf.len);
        return session.csrf_buf[0..session.csrf_len];
    }
};

/// An API key descriptor as the store returns it; `secret_digest` is
/// compared in constant time against the presented secret's digest.
pub const ApiKey = struct {
    user_id: i64,
    name_buf: [64]u8,
    name_len: u8,
    role: Role,
    secret_digest: Digest,
    disabled: bool,

    /// Returns the key's display name.
    pub fn name(key: *const ApiKey) []const u8 {
        assert(key.name_len <= key.name_buf.len);
        return key.name_buf[0..key.name_len];
    }
};

/// The storage boundary. The application implements this vtable over its
/// store; zenserve calls through it and stays storage-free. Lookups write
/// into caller-owned descriptors and return whether a row existed.
pub const Store = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const LookupError = error{Unavailable};

    pub const VTable = struct {
        lookupSession: *const fn (context: *anyopaque, digest: Digest, out: *Session) LookupError!bool,
        lookupKey: *const fn (context: *anyopaque, id: []const u8, out: *ApiKey) LookupError!bool,
        touchSession: *const fn (context: *anyopaque, digest: Digest, now: i64) LookupError!void,
        revokeSession: *const fn (context: *anyopaque, digest: Digest) LookupError!void,
    };

    /// Looks up a session by token digest; returns whether it existed.
    pub fn lookupSession(store: Store, digest: Digest, out: *Session) LookupError!bool {
        return store.vtable.lookupSession(store.context, digest, out);
    }

    /// Looks up an API key by public id; returns whether it existed.
    pub fn lookupKey(store: Store, id: []const u8, out: *ApiKey) LookupError!bool {
        return store.vtable.lookupKey(store.context, id, out);
    }

    /// Advances a session's idle expiry after successful use.
    pub fn touchSession(store: Store, digest: Digest, now: i64) LookupError!void {
        return store.vtable.touchSession(store.context, digest, now);
    }

    /// Revokes a session by token digest.
    pub fn revokeSession(store: Store, digest: Digest) LookupError!void {
        return store.vtable.revokeSession(store.context, digest);
    }
};

test "Role.atLeast full matrix" {
    try std.testing.expect(Role.anonymous.atLeast(.anonymous));
    try std.testing.expect(!Role.anonymous.atLeast(.user));
    try std.testing.expect(!Role.anonymous.atLeast(.administrator));
    try std.testing.expect(Role.user.atLeast(.anonymous));
    try std.testing.expect(Role.user.atLeast(.user));
    try std.testing.expect(!Role.user.atLeast(.administrator));
    try std.testing.expect(Role.administrator.atLeast(.anonymous));
    try std.testing.expect(Role.administrator.atLeast(.user));
    try std.testing.expect(Role.administrator.atLeast(.administrator));
}

test "token round-trip through hex encode and decode" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const token = Token.generate(io);
    var hex: [token_hex_len]u8 = undefined;
    const text = token.encode(&hex);
    try std.testing.expectEqual(@as(usize, token_hex_len), text.len);
    for (text) |char| try std.testing.expect(hexDigit(char) != null);

    const back = Token.decode(text) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualSlices(u8, &token.bytes, &back.bytes);

    var upper: [token_hex_len]u8 = undefined;
    const upper_text = std.ascii.upperString(&upper, text);
    const from_upper = Token.decode(upper_text) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualSlices(u8, &token.bytes, &from_upper.bytes);
}

test "token decode rejects bad lengths and non-hex" {
    try std.testing.expectEqual(@as(?Token, null), Token.decode(""));
    try std.testing.expectEqual(@as(?Token, null), Token.decode("abc"));
    try std.testing.expectEqual(@as(?Token, null), Token.decode("ab" ** 31));
    try std.testing.expectEqual(@as(?Token, null), Token.decode("ab" ** 33));
    const non_hex = "zz" ++ ("ab" ** 31);
    try std.testing.expectEqual(@as(?Token, null), Token.decode(non_hex));
}

test "digest equality is exact and inequality is detected" {
    const a = digestOf("alpha");
    const b = digestOf("alpha");
    const c = digestOf("beta");
    try std.testing.expect(digestEql(a, b));
    try std.testing.expect(!digestEql(a, c));

    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const token = Token.generate(io);
    var hex: [token_hex_len]u8 = undefined;
    _ = token.encode(&hex);
    const decoded = Token.decode(&hex).?;
    try std.testing.expect(digestEql(token.digest(), decoded.digest()));
}

test "key id format and validity" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const id = KeyId.generate(io);
    const text = id.slice();
    try std.testing.expectEqual(@as(usize, 30), text.len);
    try std.testing.expect(std.mem.startsWith(u8, text, "zfk_"));
    try std.testing.expect(KeyId.valid(text));

    try std.testing.expect(!KeyId.valid(""));
    try std.testing.expect(!KeyId.valid("zfk_"));
    try std.testing.expect(!KeyId.valid("zfk_" ++ "a" ** 25));
    try std.testing.expect(!KeyId.valid("zfk_" ++ "a" ** 27));
    try std.testing.expect(!KeyId.valid("zzz_" ++ "a" ** 26));
    try std.testing.expect(!KeyId.valid("zfk_" ++ "A" ** 26));
    try std.testing.expect(!KeyId.valid("zfk_" ++ "a" ** 25 ++ "0"));
    try std.testing.expect(KeyId.valid("zfk_" ++ "a" ** 25 ++ "7"));
}

test "bearer parsing accepts the documented shape and nothing else" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const id = KeyId.generate(io);
    const token = Token.generate(io);
    var hex: [token_hex_len]u8 = undefined;
    _ = token.encode(&hex);

    var credential: [30 + 1 + token_hex_len]u8 = undefined;
    @memcpy(credential[0..30], id.slice());
    credential[30] = '.';
    @memcpy(credential[31..], &hex);

    const parsed = parseBearerKey(&credential) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings(id.slice(), parsed.id);
    try std.testing.expect(digestEql(token.digest(), parsed.secret_digest));

    // Missing dot.
    var no_dot = credential;
    no_dot[30] = '_';
    try std.testing.expect(parseBearerKey(&no_dot) == null);
    // Bad prefix.
    var bad_prefix = credential;
    bad_prefix[0] = 'x';
    try std.testing.expect(parseBearerKey(&bad_prefix) == null);
    // Bad secret hex.
    var bad_hex = credential;
    bad_hex[31] = 'g';
    try std.testing.expect(parseBearerKey(&bad_hex) == null);
    // Truncated secret.
    try std.testing.expect(parseBearerKey(credential[0 .. credential.len - 1]) == null);
    try std.testing.expect(parseBearerKey("") == null);
}

test "password hash and verify round-trip" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = std.testing.allocator;

    var buffer: [phc_buf_len]u8 = undefined;
    const phc = try hashPassword(gpa, io, "correct horse battery", &buffer);
    try std.testing.expect(std.mem.startsWith(u8, phc, "$argon2id$"));
    try std.testing.expect(verifyPassword(gpa, io, phc, "correct horse battery"));
    try std.testing.expect(!verifyPassword(gpa, io, phc, "wrong password"));
    try std.testing.expect(!verifyPassword(gpa, io, "", "correct horse battery"));
    try std.testing.expect(!verifyPassword(gpa, io, "$argon2id$nonsense", "correct horse battery"));
}

test "dummy_phc verifies only its embedded password" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = std.testing.allocator;

    try std.testing.expect(verifyPassword(gpa, io, dummy_phc, "zenfmt-dummy"));
    try std.testing.expect(!verifyPassword(gpa, io, dummy_phc, "x"));
    try std.testing.expect(!verifyPassword(gpa, io, dummy_phc, ""));
    // The pinned parameters travel inside the string.
    try std.testing.expect(std.mem.indexOf(u8, dummy_phc, "m=19456,t=2,p=1") != null);
}
