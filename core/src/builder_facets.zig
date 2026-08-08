//! Facet row construction, split from the structural tree builder.

const std = @import("std");
const assert = std.debug.assert;
const ast = @import("ast.zig");
const builder = @import("builder.zig");
const facets = @import("facets.zig");

const Error = builder.Error;
const Builder = builder.Builder;
const EntityId = ast.EntityId;

pub fn blockEntity(tree_builder: *Builder, node: u32) Error!EntityId {
    return assignEntity(
        tree_builder,
        &tree_builder.block_entity_map,
        &tree_builder.store.block_entities,
        node,
    );
}

pub fn inlineEntity(tree_builder: *Builder, node: u32) Error!EntityId {
    return assignEntity(
        tree_builder,
        &tree_builder.inline_entity_map,
        &tree_builder.store.inline_entities,
        node,
    );
}

fn assignEntity(
    tree_builder: *Builder,
    map: *std.AutoHashMapUnmanaged(u32, u32),
    rows: *std.ArrayList(ast.EntityRow),
    node: u32,
) Error!EntityId {
    const entry = try map.getOrPut(tree_builder.gpa, node);
    if (entry.found_existing) return @enumFromInt(entry.value_ptr.*);
    const entity_id = tree_builder.next_entity;
    tree_builder.next_entity += 1;
    entry.value_ptr.* = entity_id;
    try rows.append(tree_builder.gpa, .{
        .node = node,
        .entity = @enumFromInt(entity_id),
    });
    return @enumFromInt(entity_id);
}

pub fn attachProvenance(
    tree_builder: *Builder,
    entity: EntityId,
    data: facets.ProvenanceData,
) Error!void {
    assert(data.plugin.len > 0);
    try takeRows(tree_builder, 1);
    try tree_builder.store.provenance_facets.append(tree_builder.gpa, .{
        .entity = entity,
        .plugin = try tree_builder.intern(data.plugin),
        .member = try tree_builder.intern(data.member),
        .byte_start = data.byte_start,
        .byte_len = data.byte_len,
        .confidence = data.confidence,
        .original_geometry = try tree_builder.intern(data.original_geometry),
    });
}

pub fn attachStyle(
    tree_builder: *Builder,
    entity: EntityId,
    data: facets.StyleData,
) Error!void {
    assert(data.name.len > 0 or data.role.len > 0 or
        data.language.len > 0 or data.direction != .inherit or
        data.properties.len > 0);
    try takeRows(tree_builder, 1 + data.properties.len);
    const property_start: u32 = @intCast(
        tree_builder.store.style_properties.items.len,
    );
    try tree_builder.store.style_properties.appendSlice(
        tree_builder.gpa,
        data.properties,
    );
    try tree_builder.store.style_facets.append(tree_builder.gpa, .{
        .entity = entity,
        .name = try tree_builder.intern(data.name),
        .role = try tree_builder.intern(data.role),
        .language = try tree_builder.intern(data.language),
        .direction = data.direction,
        .properties = .{
            .start = property_start,
            .len = @intCast(data.properties.len),
        },
    });
}

pub fn attachLayout(
    tree_builder: *Builder,
    entity: EntityId,
    data: facets.LayoutData,
) Error!void {
    assert(data.width >= 0);
    assert(data.height >= 0);
    try takeRows(tree_builder, 1);
    try tree_builder.store.layout_facets.append(tree_builder.gpa, .{
        .entity = entity,
        .surface = data.surface,
        .surface_index = data.surface_index,
        .x = data.x,
        .y = data.y,
        .width = data.width,
        .height = data.height,
        .z_order = data.z_order,
        .transform = data.transform,
        .column = data.column,
        .reading_after = data.reading_after,
    });
}

pub fn attachGrid(
    tree_builder: *Builder,
    entity: EntityId,
    data: facets.GridData,
) Error!void {
    assert(data.merge_rows >= 1);
    assert(data.merge_cols >= 1);
    assert(data.row_height >= 0);
    assert(data.column_width >= 0);
    try takeRows(tree_builder, 1);
    try tree_builder.store.grid_facets.append(tree_builder.gpa, .{
        .entity = entity,
        .sheet = try tree_builder.intern(data.sheet),
        .row = data.row,
        .col = data.col,
        .value_type = data.value_type,
        .formula = try tree_builder.appendText(data.formula),
        .cached = try tree_builder.appendText(data.cached),
        .merge_rows = data.merge_rows,
        .merge_cols = data.merge_cols,
        .row_height = data.row_height,
        .column_width = data.column_width,
        .row_hidden = data.row_hidden,
        .column_hidden = data.column_hidden,
    });
}

pub fn attachRevision(
    tree_builder: *Builder,
    entity: EntityId,
    data: facets.RevisionData,
) Error!void {
    try takeRows(tree_builder, 1);
    try tree_builder.store.revision_facets.append(tree_builder.gpa, .{
        .entity = entity,
        .kind = data.kind,
        .author = try tree_builder.intern(data.author),
        .timestamp = try tree_builder.appendText(data.timestamp),
        .note = try tree_builder.appendText(data.note),
    });
}

pub fn appendMetadataString(
    tree_builder: *Builder,
    key: []const u8,
    value: []const u8,
) Error!void {
    const key_range = try tree_builder.appendText(key);
    const value_range = try tree_builder.appendText(value);
    const span_index: u32 = @intCast(tree_builder.store.spans.items.len);
    try tree_builder.store.spans.append(tree_builder.gpa, value_range);
    const value_index: u32 = @intCast(
        tree_builder.store.meta_values.items.len,
    );
    try tree_builder.store.meta_values.append(tree_builder.gpa, .{
        .tag = .string,
        .payload = span_index,
    });
    try tree_builder.pending_meta.append(tree_builder.gpa, .{
        .key = key_range,
        .value = @enumFromInt(value_index),
    });
}

fn takeRows(tree_builder: *Builder, count: usize) Error!void {
    if (count > tree_builder.limits.max_facet_rows -
        tree_builder.facet_rows_total)
    {
        return error.LimitExceeded;
    }
    tree_builder.facet_rows_total += @intCast(count);
}
