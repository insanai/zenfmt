//! Writes the canonical capability document (ZDS 0015).
//!
//! The document is a comptime string built from the compiled bundle's
//! descriptor tables, so this tool does not compute anything — it exists so
//! the site, the download page, and the book's format tables can read from a
//! file rather than each maintaining a list by hand. Every one of those
//! surfaces would otherwise be a place a format could go missing.

const std = @import("std");
const Io = std.Io;
const capabilities = @import("zenfmt_wasm_capabilities");

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;

    var iterator = std.process.Args.Iterator.init(init.minimal.args);
    defer iterator.deinit();
    _ = iterator.next();

    const out_path = iterator.next() orelse {
        std.debug.print("usage: capabilities <out.json>\n", .{});
        return 2;
    };

    if (std.fs.path.dirname(out_path)) |parent| {
        Io.Dir.cwd().createDirPath(io, parent) catch |err| {
            std.debug.print("capabilities: cannot create {s}: {s}\n", .{
                parent,
                @errorName(err),
            });
            return 2;
        };
    }

    var atomic = Io.Dir.cwd().createFileAtomic(io, out_path, .{ .replace = true }) catch |err| {
        std.debug.print("capabilities: cannot write {s}: {s}\n", .{
            out_path,
            @errorName(err),
        });
        return 2;
    };
    defer atomic.deinit(io);

    try atomic.file.writeStreamingAll(io, capabilities.json);
    try atomic.file.writeStreamingAll(io, "\n");
    try atomic.replace(io);
    return 0;
}
