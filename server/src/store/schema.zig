//! The secure-mode storage schema (ZDS 0016, Storage on zaxonlite).
//!
//! Version 1, applied by numbered migrations recorded in `meta`. Each
//! migration is one statement run on the pre-adopt `Node`; a store whose
//! `schema_version` is newer than this binary refuses to start.

const std = @import("std");

/// The current schema version this binary understands.
pub const version: i64 = 1;

/// The ordered migrations. Each entry is applied once, in order, on a store
/// whose recorded version is below its index+1.
pub const migrations = [_][:0]const u8{
    // 1: the initial schema.
    \\CREATE TABLE meta (
    \\  key   TEXT PRIMARY KEY,
    \\  value TEXT NOT NULL
    \\) STRICT;
    \\CREATE TABLE users (
    \\  id                   INTEGER PRIMARY KEY,
    \\  name                 TEXT NOT NULL UNIQUE,
    \\  role                 TEXT NOT NULL
    \\                         CHECK (role IN ('administrator', 'user')),
    \\  password_phc         TEXT NOT NULL,
    \\  must_change_password INTEGER NOT NULL DEFAULT 0,
    \\  disabled             INTEGER NOT NULL DEFAULT 0,
    \\  created_at           INTEGER NOT NULL,
    \\  updated_at           INTEGER NOT NULL
    \\) STRICT;
    \\CREATE TABLE sessions (
    \\  token_sha256    BLOB PRIMARY KEY,
    \\  user_id         INTEGER NOT NULL
    \\                    REFERENCES users(id) ON DELETE CASCADE,
    \\  created_at      INTEGER NOT NULL,
    \\  absolute_expiry INTEGER NOT NULL,
    \\  idle_expiry     INTEGER NOT NULL,
    \\  csrf            TEXT NOT NULL,
    \\  peer            TEXT NOT NULL
    \\) STRICT;
    \\CREATE TABLE api_keys (
    \\  id            TEXT PRIMARY KEY,
    \\  secret_sha256 BLOB NOT NULL,
    \\  user_id       INTEGER NOT NULL
    \\                  REFERENCES users(id) ON DELETE CASCADE,
    \\  label         TEXT NOT NULL,
    \\  disabled      INTEGER NOT NULL DEFAULT 0,
    \\  created_at    INTEGER NOT NULL,
    \\  last_used_at  INTEGER
    \\) STRICT;
    \\CREATE TABLE audit (
    \\  id      INTEGER PRIMARY KEY,
    \\  at      INTEGER NOT NULL,
    \\  actor   TEXT NOT NULL,
    \\  action  TEXT NOT NULL,
    \\  subject TEXT NOT NULL,
    \\  detail  TEXT NOT NULL
    \\) STRICT;
    \\CREATE INDEX audit_at ON audit(at);
    ,
};

comptime {
    std.debug.assert(migrations.len == version);
}

/// The closed audit verb set (ZDS 0016). Recording a verb outside this set
/// is a programming error.
pub const AuditAction = enum {
    @"user.create",
    @"user.role",
    @"user.disable",
    @"user.enable",
    @"user.delete",
    @"user.password-reset",
    @"session.login",
    @"session.login-failed",
    @"session.logout",
    @"session.password-change",
    @"key.create",
    @"key.revoke",
    @"server.start",
    @"server.stop",
    @"server.bootstrap",

    pub fn text(action: AuditAction) []const u8 {
        return @tagName(action);
    }
};

test "there is one migration per schema version" {
    try std.testing.expectEqual(@as(usize, @intCast(version)), migrations.len);
}
