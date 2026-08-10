//! Holds a build artifact to a byte budget (ZDS 0016): exits nonzero with
//! a readable message when `<path>` exceeds `<max-bytes>`.

const std = @import("std");

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var args: std.ArrayList([]const u8) = .empty;
    var iterator = try std.process.Args.Iterator.initAllocator(init.minimal.args, arena);
    defer iterator.deinit();
    while (iterator.next()) |arg| try args.append(arena, try arena.dupe(u8, arg));

    var stderr_buffer: [1024]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writerStreaming(io, &stderr_buffer);
    const err_out = &stderr_writer.interface;
    defer err_out.flush() catch {};

    if (args.items.len != 3) {
        try err_out.writeAll("usage: size-check <path> <max-bytes>\n");
        return 2;
    }
    const path = args.items[1];
    const budget = std.fmt.parseInt(u64, args.items[2], 10) catch {
        try err_out.writeAll("size-check: max-bytes must be an integer\n");
        return 2;
    };

    const stat = try std.Io.Dir.cwd().statFile(io, path, .{});
    if (stat.size > budget) {
        try err_out.print(
            "size-check: {s} is {d} bytes, over the {d}-byte budget by {d}\n",
            .{ path, stat.size, budget, stat.size - budget },
        );
        return 1;
    }
    try err_out.print(
        "size-check: {s} is {d} bytes ({d}% of the {d}-byte budget)\n",
        .{ path, stat.size, stat.size * 100 / budget, budget },
    );
    return 0;
}
