//! Compile-time validation for plugin bundles.

const std = @import("std");
const plugin = @import("plugin.zig");

pub fn descriptorArray(
    comptime T: type,
    comptime tuple: anytype,
) [tuple.len]T {
    var array: [tuple.len]T = undefined;
    for (0..tuple.len) |index| array[index] = tuple[index];
    return array;
}

pub fn validate(
    comptime readers: []const plugin.ReaderDescriptor,
    comptime writers: []const plugin.WriterDescriptor,
) void {
    @setEvalBranchQuota(1_000_000);
    if (writers.len == 0) {
        @compileError("a bundle needs at least one writer: add a writer " ++
            "descriptor; the first writer is the default output format.");
    }
    validateReaders(readers);
    validateWriters(writers);
    validateSharedNamespaces(readers, writers);
}

fn validateReaders(comptime readers: []const plugin.ReaderDescriptor) void {
    for (readers, 0..) |left, index| {
        for (readers[index + 1 ..]) |right| {
            if (std.mem.eql(u8, left.format, right.format)) {
                @compileError("two readers claim format `" ++ left.format ++
                    "`: remove one descriptor so routing is unambiguous.");
            }
            for (left.extensions) |left_extension| {
                for (right.extensions) |right_extension| {
                    if (!std.mem.eql(u8, left_extension, right_extension)) continue;
                    @compileError("readers `" ++ left.format ++ "` and `" ++
                        right.format ++ "` both claim extension `." ++
                        left_extension ++ "`: remove it from one descriptor.");
                }
            }
        }
    }
}

fn validateWriters(comptime writers: []const plugin.WriterDescriptor) void {
    for (writers, 0..) |left, index| {
        for (writers[index + 1 ..]) |right| {
            if (std.mem.eql(u8, left.format, right.format)) {
                @compileError("two writers claim format `" ++ left.format ++
                    "`: remove one descriptor so target routing is unique.");
            }
        }
    }
}

fn validateSharedNamespaces(
    comptime readers: []const plugin.ReaderDescriptor,
    comptime writers: []const plugin.WriterDescriptor,
) void {
    for (readers) |reader| {
        for (writers) |writer| {
            if (!std.mem.eql(u8, reader.format, writer.format)) continue;
            if (std.mem.eql(u8, reader.id, writer.id)) continue;
            @compileError("the reader and writer for `" ++ reader.format ++
                "` use different plugin ids (`" ++ reader.id ++ "` and `" ++
                writer.id ++ "`): give both the same preservation namespace.");
        }
    }
}
