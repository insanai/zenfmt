//! The secure-mode account store (ZDS 0016, Storage on zaxonlite).
//!
//! Owns the zaxonlite `SharedNode` for the serving phase and provides the
//! account, session, key, and audit operations, plus the zenserve auth
//! `Store` vtable implementation. Writes go through `execPrepared` /
//! `execTransaction`; reads carry non-zero `QueryLimits`, because a network
//! host must never run an unbounded query. A deadline or store error maps
//! to `server.store-unavailable`, never to a hung request.

const std = @import("std");
const assert = std.debug.assert;
const zaxonlite = @import("zaxonlite");
const zenserve = @import("zenserve");

const schema = @import("schema.zig");

const auth = zenserve.auth;
const Value = zaxonlite.prepared.Value;

/// Bounded query limits for every read: a network host runs no unbounded
/// query. Pagination caps rows well below `max_rows`.
const read_limits: zaxonlite.node.QueryLimits = .{
    .max_rows = 1024,
    .max_bytes = 4 * 1024 * 1024,
    .max_vm_steps = 5_000_000,
};

pub const Error = error{
    Unavailable,
    NotFound,
    Conflict,
    LastAdministrator,
};

pub const Store = struct {
    gpa: std.mem.Allocator,
    node: *zaxonlite.SharedNode,

    /// Opens the store: `Node.open` (creating the directory 0o700 and
    /// taking the process lock), migrate, bootstrap if empty, then adopt.
    /// `durability.setSyncMode(.full)` must already have run.
    pub fn open(
        gpa: std.mem.Allocator,
        io: std.Io,
        data_dir: []const u8,
        out_bootstrap: *?Bootstrap,
    ) !Store {
        const node = zaxonlite.Node.open(gpa, io, .{ .directory = data_dir }) catch |err| {
            return err; // NodeLocked and friends surface to the caller.
        };
        errdefer node.close();

        try migrate(node);
        out_bootstrap.* = try bootstrapIfEmpty(gpa, io, node);

        const shared = try zaxonlite.SharedNode.adopt(gpa, node, .{
            .read_connections = 4,
            .write_queue_depth = 32,
            .write_deadline_ms = 5000,
            .read_deadline_ms = 2000,
        });
        return .{ .gpa = gpa, .node = shared };
    }

    pub fn close(store: *Store) void {
        store.node.close();
        store.* = undefined;
    }

    // ---------------------------------------------------- auth vtable

    const vtable: auth.Store.VTable = .{
        .lookupSession = vtLookupSession,
        .lookupKey = vtLookupKey,
        .touchSession = vtTouchSession,
        .revokeSession = vtRevokeSession,
    };

    pub fn authStore(store: *Store) auth.Store {
        return .{ .context = store, .vtable = &vtable };
    }

    fn vtLookupSession(context: *anyopaque, digest: auth.Digest, out: *auth.Session) auth.Store.LookupError!bool {
        const store: *Store = @ptrCast(@alignCast(context));
        return store.lookupSession(digest, out) catch return error.Unavailable;
    }

    fn vtLookupKey(context: *anyopaque, id: []const u8, out: *auth.ApiKey) auth.Store.LookupError!bool {
        const store: *Store = @ptrCast(@alignCast(context));
        return store.lookupKey(id, out) catch return error.Unavailable;
    }

    fn vtTouchSession(context: *anyopaque, digest: auth.Digest, now: i64) auth.Store.LookupError!void {
        const store: *Store = @ptrCast(@alignCast(context));
        store.touchSession(digest, now) catch return error.Unavailable;
    }

    fn vtRevokeSession(context: *anyopaque, digest: auth.Digest) auth.Store.LookupError!void {
        const store: *Store = @ptrCast(@alignCast(context));
        store.revokeSession(digest) catch return error.Unavailable;
    }

    // ---------------------------------------------------- sessions

    fn lookupSession(store: *Store, digest: auth.Digest, out: *auth.Session) !bool {
        var result = store.node.queryPreparedTypedWithLimits(
            store.gpa,
            \\SELECT s.user_id, u.name, u.role, s.absolute_expiry, s.idle_expiry,
            \\       u.disabled, u.must_change_password, s.csrf
            \\FROM sessions s JOIN users u ON u.id = s.user_id
            \\WHERE s.token_sha256 = ?1
        ,
            &.{.{ .blob = &digest }},
            read_limits,
        ) catch return error.Unavailable;
        defer result.deinit();
        if (result.rows.len == 0) return false;
        const row = result.rows[0];
        out.* = .{
            .user_id = intAt(row, 0),
            .name_buf = undefined,
            .name_len = copyName(&out.name_buf, textAt(row, 1)),
            .role = roleOf(textAt(row, 2)),
            .absolute_expiry = intAt(row, 3),
            .idle_expiry = intAt(row, 4),
        };
        out.disabled = intAt(row, 5) != 0;
        out.must_change_password = intAt(row, 6) != 0;
        out.csrf_len = copyCsrf(&out.csrf_buf, textAt(row, 7));
        return true;
    }

    pub fn createSession(
        store: *Store,
        user_id: i64,
        digest: auth.Digest,
        csrf: []const u8,
        peer: []const u8,
        now: i64,
    ) !void {
        _ = store.node.execPrepared(
            \\INSERT INTO sessions
            \\  (token_sha256, user_id, created_at, absolute_expiry, idle_expiry, csrf, peer)
            \\VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
        ,
            &.{
                .{ .blob = &digest },
                .{ .integer = user_id },
                .{ .integer = now },
                .{ .integer = now + session_absolute_ttl },
                .{ .integer = now + session_idle_ttl },
                .{ .text = csrf },
                .{ .text = peer },
            },
        ) catch return error.Unavailable;
    }

    fn touchSession(store: *Store, digest: auth.Digest, now: i64) !void {
        // Idle expiry is touched at most every 5 minutes (ZDS 0016): only
        // extend when the new deadline is at least that far past the old.
        _ = store.node.execPrepared(
            \\UPDATE sessions SET idle_expiry = ?2
            \\WHERE token_sha256 = ?1 AND ?2 - (idle_expiry - ?3) >= ?4
        ,
            &.{
                .{ .blob = &digest },
                .{ .integer = now + session_idle_ttl },
                .{ .integer = session_idle_ttl },
                .{ .integer = idle_touch_interval },
            },
        ) catch return error.Unavailable;
    }

    fn revokeSession(store: *Store, digest: auth.Digest) !void {
        _ = store.node.execPrepared(
            "DELETE FROM sessions WHERE token_sha256 = ?1",
            &.{.{ .blob = &digest }},
        ) catch return error.Unavailable;
    }

    /// Revokes every session of an account except an optional survivor
    /// (the current one, on a password change).
    pub fn revokeUserSessions(store: *Store, user_id: i64, keep: ?auth.Digest) !void {
        if (keep) |digest| {
            _ = store.node.execPrepared(
                "DELETE FROM sessions WHERE user_id = ?1 AND token_sha256 != ?2",
                &.{ .{ .integer = user_id }, .{ .blob = &digest } },
            ) catch return error.Unavailable;
        } else {
            _ = store.node.execPrepared(
                "DELETE FROM sessions WHERE user_id = ?1",
                &.{.{ .integer = user_id }},
            ) catch return error.Unavailable;
        }
    }

    // ---------------------------------------------------- api keys

    fn lookupKey(store: *Store, id: []const u8, out: *auth.ApiKey) !bool {
        var result = store.node.queryPreparedTypedWithLimits(
            store.gpa,
            \\SELECT k.user_id, u.name, u.role, k.secret_sha256, k.disabled, u.disabled
            \\FROM api_keys k JOIN users u ON u.id = k.user_id
            \\WHERE k.id = ?1
        ,
            &.{.{ .text = id }},
            read_limits,
        ) catch return error.Unavailable;
        defer result.deinit();
        if (result.rows.len == 0) return false;
        const row = result.rows[0];
        out.* = .{
            .user_id = intAt(row, 0),
            .name_buf = undefined,
            .name_len = copyName(&out.name_buf, textAt(row, 1)),
            .role = roleOf(textAt(row, 2)),
            .secret_digest = digestAt(row, 3),
            .disabled = intAt(row, 4) != 0 or intAt(row, 5) != 0,
        };
        return true;
    }

    // ------------------------------------------------------ keys

    pub fn createKey(
        store: *Store,
        id: []const u8,
        secret_digest: auth.Digest,
        user_id: i64,
        label: []const u8,
        now: i64,
    ) !void {
        _ = store.node.execPrepared(
            \\INSERT INTO api_keys (id, secret_sha256, user_id, label, created_at)
            \\VALUES (?1, ?2, ?3, ?4, ?5)
        ,
            &.{
                .{ .text = id },
                .{ .blob = &secret_digest },
                .{ .integer = user_id },
                .{ .text = label },
                .{ .integer = now },
            },
        ) catch return error.Unavailable;
    }

    pub const KeySummary = struct {
        id: []const u8,
        label: []const u8,
        disabled: bool,
        created_at: i64,
    };

    pub fn listKeys(store: *Store, arena: std.mem.Allocator, user_id: i64) ![]const KeySummary {
        var result = store.node.queryPreparedTypedWithLimits(
            store.gpa,
            \\SELECT id, label, disabled, created_at FROM api_keys
            \\WHERE user_id = ?1 ORDER BY created_at DESC LIMIT 200
        ,
            &.{.{ .integer = user_id }},
            read_limits,
        ) catch return error.Unavailable;
        defer result.deinit();
        const out = try arena.alloc(KeySummary, result.rows.len);
        for (result.rows, out) |row, *summary| {
            summary.* = .{
                .id = try arena.dupe(u8, textAt(row, 0)),
                .label = try arena.dupe(u8, textAt(row, 1)),
                .disabled = intAt(row, 2) != 0,
                .created_at = intAt(row, 3),
            };
        }
        return out;
    }

    /// Revokes a key. A non-administrator may revoke only their own key;
    /// the WHERE clause enforces ownership, so a foreign id deletes nothing
    /// and reports NotFound.
    pub fn revokeKey(store: *Store, id: []const u8, requester: i64, is_admin: bool) !void {
        const result = if (is_admin)
            store.node.execPrepared(
                "DELETE FROM api_keys WHERE id = ?1",
                &.{.{ .text = id }},
            )
        else
            store.node.execPrepared(
                "DELETE FROM api_keys WHERE id = ?1 AND user_id = ?2",
                &.{ .{ .text = id }, .{ .integer = requester } },
            );
        const exec = result catch return error.Unavailable;
        if (exec.changes == 0) return error.NotFound;
    }

    // ---------------------------------------------------- users

    pub const UserRecord = struct {
        id: i64,
        name: []const u8,
        role: auth.Role,
        password_phc: []const u8,
        must_change_password: bool,
        disabled: bool,
    };

    /// Looks a user up by name for login; the returned slices live in
    /// `arena`.
    pub fn userByName(
        store: *Store,
        arena: std.mem.Allocator,
        name: []const u8,
    ) !?UserRecord {
        var result = store.node.queryPreparedTypedWithLimits(
            store.gpa,
            \\SELECT id, name, role, password_phc, must_change_password, disabled
            \\FROM users WHERE name = ?1
        ,
            &.{.{ .text = name }},
            read_limits,
        ) catch return error.Unavailable;
        defer result.deinit();
        if (result.rows.len == 0) return null;
        const row = result.rows[0];
        return .{
            .id = intAt(row, 0),
            .name = try arena.dupe(u8, textAt(row, 1)),
            .role = roleOf(textAt(row, 2)),
            .password_phc = try arena.dupe(u8, textAt(row, 3)),
            .must_change_password = intAt(row, 4) != 0,
            .disabled = intAt(row, 5) != 0,
        };
    }

    pub fn createUser(
        store: *Store,
        name: []const u8,
        role: auth.Role,
        phc: []const u8,
        must_change: bool,
        now: i64,
    ) !void {
        _ = store.node.execPrepared(
            \\INSERT INTO users
            \\  (name, role, password_phc, must_change_password, created_at, updated_at)
            \\VALUES (?1, ?2, ?3, ?4, ?5, ?5)
        ,
            &.{
                .{ .text = name },
                .{ .text = roleText(role) },
                .{ .text = phc },
                .{ .integer = if (must_change) 1 else 0 },
                .{ .integer = now },
            },
        ) catch |err| return mapWriteError(err);
    }

    pub fn setPassword(
        store: *Store,
        user_id: i64,
        phc: []const u8,
        must_change: bool,
        now: i64,
    ) !void {
        _ = store.node.execPrepared(
            \\UPDATE users SET password_phc = ?2, must_change_password = ?3,
            \\  updated_at = ?4 WHERE id = ?1
        ,
            &.{
                .{ .integer = user_id },
                .{ .text = phc },
                .{ .integer = if (must_change) 1 else 0 },
                .{ .integer = now },
            },
        ) catch return error.Unavailable;
    }

    pub fn setRole(store: *Store, user_id: i64, role: auth.Role, now: i64) !void {
        _ = store.node.execPrepared(
            "UPDATE users SET role = ?2, updated_at = ?3 WHERE id = ?1",
            &.{ .{ .integer = user_id }, .{ .text = roleText(role) }, .{ .integer = now } },
        ) catch return error.Unavailable;
    }

    pub fn setDisabled(store: *Store, user_id: i64, disabled: bool, now: i64) !void {
        _ = store.node.execPrepared(
            "UPDATE users SET disabled = ?2, updated_at = ?3 WHERE id = ?1",
            &.{
                .{ .integer = user_id },
                .{ .integer = if (disabled) 1 else 0 },
                .{ .integer = now },
            },
        ) catch return error.Unavailable;
    }

    pub fn deleteUser(store: *Store, user_id: i64) !void {
        // Sessions and keys cascade on the foreign key.
        _ = store.node.execPrepared(
            "DELETE FROM users WHERE id = ?1",
            &.{.{ .integer = user_id }},
        ) catch return error.Unavailable;
    }

    /// The account table for the admin view; slices live in `arena`.
    pub fn listUsers(store: *Store, arena: std.mem.Allocator) ![]const UserSummary {
        var result = store.node.queryPreparedTypedWithLimits(
            store.gpa,
            \\SELECT name, role, disabled, must_change_password, created_at
            \\FROM users ORDER BY name LIMIT 500
        ,
            &.{},
            read_limits,
        ) catch return error.Unavailable;
        defer result.deinit();
        const out = try arena.alloc(UserSummary, result.rows.len);
        for (result.rows, out) |row, *summary| {
            summary.* = .{
                .name = try arena.dupe(u8, textAt(row, 0)),
                .role = try arena.dupe(u8, textAt(row, 1)),
                .disabled = intAt(row, 2) != 0,
                .must_change_password = intAt(row, 3) != 0,
                .created_at = intAt(row, 4),
            };
        }
        return out;
    }

    /// Recent audit records, newest first; slices live in `arena`.
    pub fn listAudit(store: *Store, arena: std.mem.Allocator, limit: u32) ![]const AuditRecord {
        var result = store.node.queryPreparedTypedWithLimits(
            store.gpa,
            \\SELECT at, actor, action, subject FROM audit
            \\ORDER BY id DESC LIMIT ?1
        ,
            &.{.{ .integer = @intCast(limit) }},
            read_limits,
        ) catch return error.Unavailable;
        defer result.deinit();
        const out = try arena.alloc(AuditRecord, result.rows.len);
        for (result.rows, out) |row, *record| {
            record.* = .{
                .at = intAt(row, 0),
                .actor = try arena.dupe(u8, textAt(row, 1)),
                .action = try arena.dupe(u8, textAt(row, 2)),
                .subject = try arena.dupe(u8, textAt(row, 3)),
            };
        }
        return out;
    }

    /// Counts administrators, for the last-administrator invariant.
    pub fn administratorCount(store: *Store) !i64 {
        var result = store.node.queryPreparedTypedWithLimits(
            store.gpa,
            "SELECT COUNT(*) FROM users WHERE role = 'administrator' AND disabled = 0",
            &.{},
            read_limits,
        ) catch return error.Unavailable;
        defer result.deinit();
        if (result.rows.len == 0) return 0;
        return intAt(result.rows[0], 0);
    }

    // ------------------------------------------------------ audit

    pub fn audit(
        store: *Store,
        action: schema.AuditAction,
        actor: []const u8,
        subject: []const u8,
        detail: []const u8,
        now: i64,
    ) void {
        // Auditing must never fail the operation it records.
        _ = store.node.execPrepared(
            \\INSERT INTO audit (at, actor, action, subject, detail)
            \\VALUES (?1, ?2, ?3, ?4, ?5)
        ,
            &.{
                .{ .integer = now },
                .{ .text = actor },
                .{ .text = action.text() },
                .{ .text = subject },
                .{ .text = detail },
            },
        ) catch {};
    }

    /// Prunes audit rows past the retention bound (ZDS 0016): older than 90
    /// days, and beyond 100 000 rows. Called at startup and daily.
    pub fn pruneAudit(store: *Store, now: i64) void {
        _ = store.node.execPrepared(
            "DELETE FROM audit WHERE at < ?1",
            &.{.{ .integer = now - audit_retention_seconds }},
        ) catch {};
        _ = store.node.execPrepared(
            \\DELETE FROM audit WHERE id NOT IN (
            \\  SELECT id FROM audit ORDER BY id DESC LIMIT ?1
            \\)
        ,
            &.{.{ .integer = audit_retention_rows }},
        ) catch {};
    }
};

pub const UserSummary = struct {
    name: []const u8,
    role: []const u8,
    disabled: bool,
    must_change_password: bool,
    created_at: i64,
};

pub const AuditRecord = struct {
    at: i64,
    actor: []const u8,
    action: []const u8,
    subject: []const u8,
};

pub const Bootstrap = struct {
    name: [16]u8,
    name_len: usize,
    password: [24]u8,

    pub fn nameSlice(b: *const Bootstrap) []const u8 {
        return b.name[0..b.name_len];
    }
};

// -------------------------------------------------------- lifecycle

fn migrate(node: *zaxonlite.Node) !void {
    const current = try readSchemaVersion(node);
    if (current > schema.version) return error.SchemaTooNew;
    var index: usize = @intCast(current);
    while (index < schema.migrations.len) : (index += 1) {
        _ = try node.exec(schema.migrations[index]);
    }
    if (current < schema.version) try writeSchemaVersion(node);
}

fn readSchemaVersion(node: *zaxonlite.Node) !i64 {
    // The meta table may not exist yet on a fresh store.
    var result = node.queryPreparedTypedWithLimits(
        node.gpa,
        \\SELECT value FROM meta WHERE key = 'schema_version'
    ,
        &.{},
        read_limits,
    ) catch return 0;
    defer result.deinit();
    if (result.rows.len == 0) return 0;
    const text = textAt(result.rows[0], 0);
    return std.fmt.parseInt(i64, text, 10) catch 0;
}

fn writeSchemaVersion(node: *zaxonlite.Node) !void {
    var buf: [20]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "{d}", .{schema.version}) catch unreachable;
    _ = try node.execPrepared(
        \\INSERT INTO meta (key, value) VALUES ('schema_version', ?1)
        \\ON CONFLICT(key) DO UPDATE SET value = ?1
    ,
        &.{.{ .text = text }},
    );
}

fn bootstrapIfEmpty(
    gpa: std.mem.Allocator,
    io: std.Io,
    node: *zaxonlite.Node,
) !?Bootstrap {
    var count = node.queryPreparedTypedWithLimits(
        gpa,
        "SELECT COUNT(*) FROM users",
        &.{},
        read_limits,
    ) catch return error.Unavailable;
    defer count.deinit();
    if (count.rows.len > 0 and intAt(count.rows[0], 0) > 0) return null;

    var boot: Bootstrap = .{ .name = undefined, .name_len = 5, .password = undefined };
    @memcpy(boot.name[0..5], "admin");
    generatePassword(io, &boot.password);

    var phc_buf: [auth.phc_buf_len]u8 = undefined;
    const phc = try auth.hashPassword(gpa, io, &boot.password, &phc_buf);
    const now = std.Io.Clock.now(.real, io).toSeconds();
    _ = try node.execPrepared(
        \\INSERT INTO users
        \\  (name, role, password_phc, must_change_password, created_at, updated_at)
        \\VALUES ('admin', 'administrator', ?1, 1, ?2, ?2)
    ,
        &.{ .{ .text = phc }, .{ .integer = now } },
    );
    _ = try node.execPrepared(
        \\INSERT INTO audit (at, actor, action, subject, detail)
        \\VALUES (?1, 'system', 'server.bootstrap', 'admin', '{}')
    ,
        &.{.{ .integer = now }},
    );
    return boot;
}

fn generatePassword(io: std.Io, out: *[24]u8) void {
    const alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789";
    var raw: [24]u8 = undefined;
    io.random(&raw);
    for (out, raw) |*slot, byte| slot.* = alphabet[byte % alphabet.len];
}

// ---------------------------------------------------------- helpers

const session_absolute_ttl: i64 = 24 * 60 * 60;
const session_idle_ttl: i64 = 2 * 60 * 60;
const idle_touch_interval: i64 = 5 * 60;
const audit_retention_seconds: i64 = 90 * 24 * 60 * 60;
const audit_retention_rows: i64 = 100_000;

fn intAt(row: []const Value, index: usize) i64 {
    return switch (row[index]) {
        .integer => |value| value,
        .real => |value| @intFromFloat(value),
        .text => |text| std.fmt.parseInt(i64, text, 10) catch 0,
        else => 0,
    };
}

fn textAt(row: []const Value, index: usize) []const u8 {
    return switch (row[index]) {
        .text => |text| text,
        .blob => |blob| blob,
        else => "",
    };
}

fn digestAt(row: []const Value, index: usize) auth.Digest {
    var digest: auth.Digest = undefined;
    const cell = switch (row[index]) {
        .blob => |blob| blob,
        .text => |text| text,
        else => return digest,
    };
    const len = @min(cell.len, digest.len);
    @memcpy(digest[0..len], cell[0..len]);
    return digest;
}

fn roleOf(text: []const u8) auth.Role {
    if (std.mem.eql(u8, text, "administrator")) return .administrator;
    return .user;
}

fn roleText(role: auth.Role) []const u8 {
    return switch (role) {
        .administrator => "administrator",
        else => "user",
    };
}

fn copyName(buf: *[64]u8, name: []const u8) u8 {
    const len: u8 = @intCast(@min(name.len, buf.len));
    @memcpy(buf[0..len], name[0..len]);
    return len;
}

fn copyCsrf(buf: *[64]u8, csrf: []const u8) u8 {
    const len: u8 = @intCast(@min(csrf.len, buf.len));
    @memcpy(buf[0..len], csrf[0..len]);
    return len;
}

fn mapWriteError(err: anytype) Error {
    // A UNIQUE violation on `users.name` surfaces as a generic write
    // failure; the caller has already checked existence, so treat any
    // constraint failure as a conflict and everything else as unavailable.
    return switch (err) {
        error.ConstraintViolation, error.SqliteConstraint => error.Conflict,
        else => error.Unavailable,
    };
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

test "open, bootstrap, restart, and look the admin up" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(io, &path_buf);
    const dir = path_buf[0..dir_len];

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var bootstrap: ?Bootstrap = null;
    var store = try Store.open(testing.allocator, io, dir, &bootstrap);
    try testing.expect(bootstrap != null);
    try testing.expectEqualStrings("admin", bootstrap.?.nameSlice());

    const admin = (try store.userByName(arena, "admin")).?;
    try testing.expectEqual(auth.Role.administrator, admin.role);
    try testing.expect(admin.must_change_password);
    try testing.expect(auth.verifyPassword(arena, io, admin.password_phc, &bootstrap.?.password));
    try testing.expectEqual(@as(i64, 1), try store.administratorCount());
    store.close();

    // Restart: no second bootstrap, admin persists.
    var second_boot: ?Bootstrap = null;
    var reopened = try Store.open(testing.allocator, io, dir, &second_boot);
    defer reopened.close();
    try testing.expect(second_boot == null);
    try testing.expect((try reopened.userByName(arena, "admin")) != null);
}

test "a newer schema version refuses to open" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(io, &path_buf);
    const dir = path_buf[0..dir_len];

    // Open once, then bump the recorded version past the binary's.
    {
        var boot: ?Bootstrap = null;
        var store = try Store.open(testing.allocator, io, dir, &boot);
        _ = store.node.execPrepared(
            "UPDATE meta SET value = '999' WHERE key = 'schema_version'",
            &.{},
        ) catch {};
        store.close();
    }
    var boot: ?Bootstrap = null;
    try testing.expectError(error.SchemaTooNew, Store.open(testing.allocator, io, dir, &boot));
}
