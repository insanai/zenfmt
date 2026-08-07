//! The resource store (ZDS 0013, Sparse Facets): extracted binary content
//! carried alongside the document. Generalizes the v1 media pool: each
//! entry records its source name, MIME type, bytes in the binary pool, a
//! BLAKE3 digest computed at registration, and optional accessibility
//! text. On path output the engine writes each resource beside the
//! artifact and lists it, digest and all, in the manifest.

const std = @import("std");
const ast = @import("ast.zig");
const manifest = @import("manifest.zig");

pub const ResourceId = enum(u32) {
    _,

    pub fn raw(id: ResourceId) u32 {
        return @intFromEnum(id);
    }
};

pub const Resource = struct {
    /// The source name a reader saw: an archive part, an object id, a URL.
    /// Image targets matching this name are rewritten on path output.
    source: ast.ByteRange,
    mime: ast.ByteRange,
    /// Content bytes in `Store.resource_bytes`; binary, never in the UTF-8
    /// text pool.
    bytes: ast.ByteRange,
    /// BLAKE3-256 of the content, computed once at registration; the
    /// manifest reuses it instead of hashing again at commit.
    digest_hex: manifest.DigestHex,
    /// Accessibility text, when the source carries any.
    alt: ast.ByteRange,
};
