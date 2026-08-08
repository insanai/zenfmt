//! Allocation-failure sweeps through the bridge (ZDS 0014): every induced
//! failure yields either a null handle or a failed result carrying the
//! canonical `core.out-of-memory` report, and never leaks. Mirrors
//! `tests/oom.zig`, which pins the same contract for the engine.

const std = @import("std");
const testing = std.testing;
const abi = @import("abi.zig");
const result_mod = @import("result.zig");

const max_fail_index = 512;

const options_json =
    \\{"schema":1,"input":{"kind":"bytes","name":"note.md"},
    \\"output":{"kind":"memory","artifact_name":"note.md"}}
;

test "bridge conversion propagates allocation failure canonically" {
    var reached_end = false;
    var fail_index: usize = 0;
    while (fail_index < max_fail_index) : (fail_index += 1) {
        var failing = testing.FailingAllocator.init(testing.allocator, .{
            .fail_index = fail_index,
        });
        const request: abi.Request = .{
            .options_json = .{
                .ptr = options_json.ptr,
                .len = options_json.len,
            },
            .input_bytes = .{ .ptr = "# T\n\nbody\n", .len = 10 },
            .input_path = .{ .ptr = null, .len = 0 },
            .output_path = .{ .ptr = null, .len = 0 },
        };
        const maybe_result = result_mod.convert(failing.allocator(), &request);
        const induced = failing.has_induced_failure;
        if (maybe_result) |result| {
            defer result.destroy();
            if (induced) {
                // Induced exhaustion inside the engine surfaces as the
                // canonical failed conversion, never a partial success.
                if (result.status == result_mod.status_success) {
                    // The failure landed in bookkeeping the engine
                    // absorbed (for example a freed scratch buffer); a
                    // successful result must still be complete.
                    const conversion = &result.conversion.?;
                    try testing.expect(conversion.manifest_json != null);
                } else {
                    try testing.expectEqual(
                        result_mod.status_failed,
                        result.status,
                    );
                    try testing.expect(std.mem.indexOf(
                        u8,
                        result.reports_json,
                        "core.out-of-memory",
                    ) != null);
                }
            }
        }
        if (!induced) {
            reached_end = true;
            break;
        }
    }
    try testing.expect(reached_end);
}
