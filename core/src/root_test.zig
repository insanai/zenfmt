//! Test discovery for core modules kept out of the public root's line budget.

test {
    _ = @import("ast.zig");
    _ = @import("payload.zig");
    _ = @import("metadata.zig");
    _ = @import("builder.zig");
    _ = @import("limits.zig");
    _ = @import("report.zig");
    _ = @import("json.zig");
    _ = @import("manifest.zig");
    _ = @import("plugin.zig");
    _ = @import("pipeline.zig");
    _ = @import("transform.zig");
    _ = @import("detect.zig");
    _ = @import("schema.zig");
    _ = @import("facets.zig");
    _ = @import("lowering.zig");
    _ = @import("filters.zig");
}
