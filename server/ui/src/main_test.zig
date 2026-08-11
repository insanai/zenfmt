const std = @import("std");
const main = @import("main.zig");

const testing = std.testing;

fn testState(arena: std.mem.Allocator) main.State {
    return .{ .gpa = arena };
}

fn initOpen(arena: std.mem.Allocator, state: *main.State) ![]const u8 {
    _ = try main.handleEvent(arena, state,
        \\{"event":"init","path":"/","stored_theme":"system","system_scheme":"light"}
    );
    return main.handleEvent(arena, state,
        \\{"event":"fetch_done","id":3,"status":404,"body":""}
    );
}

test "init renders the converter and discovers capabilities" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var state = testState(arena);

    const commands = try main.handleEvent(arena, &state,
        \\{"event":"init","path":"/","stored_theme":"system","system_scheme":"dark"}
    );
    try testing.expect(std.mem.indexOf(u8, commands, "\"cmd\":\"title\"") != null);
    try testing.expect(std.mem.indexOf(u8, commands, "\"cmd\":\"patch\"") != null);
    try testing.expect(std.mem.indexOf(u8, commands, "/api/v1/session") != null);
    try testing.expect(std.mem.indexOf(u8, commands, "\"theme\":\"dark\"") != null);
    try testing.expectEqual(main.Theme.system, state.stored_theme);
    const open_commands = try main.handleEvent(arena, &state,
        \\{"event":"fetch_done","id":3,"status":404,"body":""}
    );
    try testing.expect(std.mem.indexOf(u8, open_commands, "Drop a document") != null);
    try testing.expect(std.mem.indexOf(u8, open_commands, "/api/v1/formats") != null);
}

test "an explicit theme choice persists and applies" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var state = testState(arena);
    _ = try initOpen(arena, &state);

    const commands = try main.handleEvent(arena, &state,
        \\{"event":"action","name":"theme_dark","fields":{}}
    );
    try testing.expect(std.mem.indexOf(
        u8,
        commands,
        "\"cmd\":\"preference_store\",\"theme\":\"dark\"",
    ) != null);
    try testing.expect(std.mem.indexOf(
        u8,
        commands,
        "\"cmd\":\"theme_apply\",\"theme\":\"dark\"",
    ) != null);
    try testing.expectEqual(main.Theme.dark, state.stored_theme);

    const back = try main.handleEvent(arena, &state,
        \\{"event":"action","name":"theme_system","fields":{}}
    );
    try testing.expect(std.mem.indexOf(
        u8,
        back,
        "\"cmd\":\"theme_apply\",\"theme\":\"light\"",
    ) != null);
}

test "a system scheme change applies only under the system preference" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var state = testState(arena);
    _ = try initOpen(arena, &state);

    const commands = try main.handleEvent(arena, &state,
        \\{"event":"color_scheme_change","scheme":"dark"}
    );
    try testing.expect(std.mem.indexOf(u8, commands, "\"theme\":\"dark\"") != null);

    _ = try main.handleEvent(arena, &state,
        \\{"event":"action","name":"theme_light","fields":{}}
    );
    const pinned = try main.handleEvent(arena, &state,
        \\{"event":"color_scheme_change","scheme":"light"}
    );
    try testing.expect(std.mem.indexOf(u8, pinned, "theme_apply") == null);
}

test "convert without a file explains itself; with a file it fetches" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var state = testState(arena);
    _ = try initOpen(arena, &state);

    const refused = try main.handleEvent(arena, &state,
        \\{"event":"action","name":"convert","fields":{"to":"markdown","strict":"off"}}
    );
    try testing.expect(std.mem.indexOf(u8, refused, "pick or drop a document") != null);
    try testing.expect(std.mem.indexOf(u8, refused, "\"cmd\":\"fetch\"") == null);

    _ = try main.handleEvent(arena, &state,
        \\{"event":"file","name":"report.docx","size":1234}
    );
    const converted = try main.handleEvent(arena, &state,
        \\{"event":"action","name":"convert","fields":{"to":"markdown","strict":"exact"}}
    );
    try testing.expect(std.mem.indexOf(
        u8,
        converted,
        "/api/v1/convert?to=markdown&strict=exact",
    ) != null);
    try testing.expect(std.mem.indexOf(u8, converted, "\"body\":\"file\"") != null);
    try testing.expect(state.busy);
}

test "a success envelope becomes the result card; reports render verbatim" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var state = testState(arena);
    _ = try initOpen(arena, &state);
    _ = try main.handleEvent(arena, &state,
        \\{"event":"file","name":"report.docx","size":1234}
    );
    _ = try main.handleEvent(arena, &state,
        \\{"event":"action","name":"convert","fields":{"to":"markdown","strict":"off"}}
    );

    const body =
        \\{"status":"success","artifact":"# Hi","artifact_name":"report.md",
        \\"reports":[{"severity":"warning","code":"docx.comment-dropped",
        \\"title":"A COMMENT WAS DROPPED",
        \\"problem":"The comment has no Markdown form.",
        \\"consequence":"The comment is gone.","directions":[{
        \\"title":"What you can do",
        \\"explanation":"Nothing; comments have no home in Markdown."}]}],
        \\"exit_class":"conversion"}
    ;
    const envelope = try std.json.Stringify.valueAlloc(arena, .{
        .event = "fetch_done",
        .id = 2,
        .status = 200,
        .body = body,
    }, .{});
    const commands = try main.handleEvent(arena, &state, envelope);
    try testing.expect(!state.busy);
    try testing.expect(state.result != null);
    try testing.expectEqualStrings("report.md", state.result.?.artifact_name);
    try testing.expect(std.mem.indexOf(u8, commands, "report.md") != null);
    try testing.expect(std.mem.indexOf(u8, commands, "docx.comment-dropped") != null);
    try testing.expect(std.mem.indexOf(u8, commands, "A COMMENT WAS DROPPED") != null);

    const download = try main.handleEvent(arena, &state,
        \\{"event":"action","name":"download","fields":{}}
    );
    try testing.expect(std.mem.indexOf(u8, download, "\"cmd\":\"download\"") != null);
}

test "hostile strings in the envelope are escaped by construction" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var state = testState(arena);
    _ = try initOpen(arena, &state);
    _ = try main.handleEvent(arena, &state,
        \\{"event":"file","name":"x.docx","size":1}
    );
    _ = try main.handleEvent(arena, &state,
        \\{"event":"action","name":"convert","fields":{}}
    );
    const body =
        \\{"status":"failed","reports":[{"severity":"error",
        \\"code":"server.invalid-query","title":"<script>alert(1)</script>",
        \\"problem":"<img src=x>","consequence":"c","directions":[]}],
        \\"exit_class":"usage"}
    ;
    const event = try std.json.Stringify.valueAlloc(arena, .{
        .event = "fetch_done",
        .id = 2,
        .status = 400,
        .body = body,
    }, .{});
    const commands = try main.handleEvent(arena, &state, event);
    try testing.expect(std.mem.indexOf(u8, commands, "<script>") == null);
    try testing.expect(std.mem.indexOf(u8, commands, "&lt;script&gt;") != null);
}

test "a successful artifact response remains usable without an envelope" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var state = testState(arena);
    _ = try initOpen(arena, &state);
    _ = try main.handleEvent(arena, &state,
        \\{"event":"file","name":"brief.pdf","size":4096}
    );
    _ = try main.handleEvent(arena, &state,
        \\{"event":"action","name":"convert","fields":{"to":"markdown"}}
    );

    const commands = try main.handleEvent(arena, &state,
        \\{"event":"fetch_done","id":2,"status":200,
        \\ "content_type":"text/markdown; charset=utf-8","body":"# Brief"}
    );
    try testing.expect(state.result != null);
    try testing.expectEqualStrings("brief.md", state.result.?.artifact_name);
    try testing.expectEqualStrings("# Brief", state.result.?.artifact);
    try testing.expect(std.mem.indexOf(u8, commands, "brief.md") != null);
}

test "API docs stay public when secure mode has no session" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var state = testState(arena);

    _ = try main.handleEvent(arena, &state,
        \\{"event":"init","path":"/docs","stored_theme":"system",
        \\ "system_scheme":"light"}
    );
    const commands = try main.handleEvent(arena, &state,
        \\{"event":"fetch_done","id":3,"status":401,"body":""}
    );
    try testing.expectEqualStrings("/docs", state.path);
    try testing.expect(std.mem.indexOf(u8, commands, "API reference") != null);
    try testing.expect(std.mem.indexOf(u8, commands, "navigate") == null);
}
