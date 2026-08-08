//! The standard zenfmt command-line tool: the umbrella CLI with an empty
//! filter pipeline. A project that wants filters compiled in writes its
//! own thin main against the same entry point; see `examples/filters/`.

const std = @import("std");
const zenfmt = @import("zenfmt");
const cli = @import("zenfmt_cli");

pub fn main(init: std.process.Init) !u8 {
    return cli.main(init, &zenfmt.Pipeline.empty);
}
