//! ReleaseFast validation for sparse entities, facets, and resources.

const ast = @import("ast.zig");
const facets = @import("facets.zig");
const limits_mod = @import("limits.zig");

pub fn validate(
    doc: *const ast.Document,
    limits: limits_mod.Limits,
) error{InvalidDocument}!void {
    const store = doc.store;
    try validateEntityRows(
        store.block_entities.items,
        doc.block_entities,
        @intCast(store.blocks.len),
    );
    try validateEntityRows(
        store.inline_entities.items,
        doc.inline_entities,
        @intCast(store.inlines.len),
    );
    try validateEntityIndex(doc);
    try validateFacets(store, limits);
    try validateResources(store, limits);
}

fn validateEntityIndex(doc: *const ast.Document) error{InvalidDocument}!void {
    const store = doc.store;
    const range = doc.entity_index;
    if (range.end() > store.entity_index.items.len) return error.InvalidDocument;
    if (range.len != doc.block_entities.len + doc.inline_entities.len) {
        return error.InvalidDocument;
    }
    var previous: ?u32 = null;
    for (store.entity_index.items[range.start..range.end()]) |reference| {
        if (!referenceInSnapshot(reference, doc)) return error.InvalidDocument;
        const row = entityRow(store, reference);
        if (previous) |entity| {
            if (row.entity.raw() <= entity) return error.InvalidDocument;
        }
        if (!entityHasFacet(store, row.entity)) return error.InvalidDocument;
        previous = row.entity.raw();
    }
}

fn referenceInSnapshot(
    reference: ast.EntityReference,
    doc: *const ast.Document,
) bool {
    const row = reference.row();
    const range = if (reference.isInline()) doc.inline_entities else doc.block_entities;
    return row >= range.start and row < range.end();
}

fn entityRow(store: *const ast.Store, reference: ast.EntityReference) ast.EntityRow {
    return if (reference.isInline())
        store.inline_entities.items[reference.row()]
    else
        store.block_entities.items[reference.row()];
}

fn entityHasFacet(store: *const ast.Store, entity: ast.EntityId) bool {
    return facets.find(facets.Provenance, store.provenance_facets.items, entity) != null or
        facets.find(facets.Style, store.style_facets.items, entity) != null or
        facets.find(facets.Layout, store.layout_facets.items, entity) != null or
        facets.find(facets.Grid, store.grid_facets.items, entity) != null or
        facets.findAll(facets.Revision, store.revision_facets.items, entity).len > 0;
}

fn validateEntityRows(
    rows: []const ast.EntityRow,
    range: ast.EntityRange,
    node_count: u32,
) error{InvalidDocument}!void {
    if (range.end() > rows.len) return error.InvalidDocument;
    var previous: ?u32 = null;
    for (rows[range.start..range.end()]) |row| {
        if (row.node >= node_count) return error.InvalidDocument;
        if (previous) |node| {
            if (row.node <= node) return error.InvalidDocument;
        }
        previous = row.node;
    }
}

fn validateFacets(
    store: *const ast.Store,
    limits: limits_mod.Limits,
) error{InvalidDocument}!void {
    const count = store.provenance_facets.items.len +
        store.style_facets.items.len + store.style_properties.items.len +
        store.layout_facets.items.len + store.grid_facets.items.len +
        store.revision_facets.items.len;
    if (count > limits.max_facet_rows) return error.InvalidDocument;
    try validateFacetTable(facets.Provenance, store.provenance_facets.items, store, false);
    try validateFacetTable(facets.Style, store.style_facets.items, store, false);
    try validateFacetTable(facets.Layout, store.layout_facets.items, store, false);
    try validateFacetTable(facets.Grid, store.grid_facets.items, store, false);
    try validateFacetTable(facets.Revision, store.revision_facets.items, store, true);
    for (store.grid_facets.items) |row| {
        if (row.merge_rows < 1 or row.merge_cols < 1) return error.InvalidDocument;
        if (row.row_height < 0 or row.column_width < 0) return error.InvalidDocument;
    }
    for (store.style_facets.items) |row| {
        if (row.properties.start + row.properties.len > store.style_properties.items.len) {
            return error.InvalidDocument;
        }
    }
}

fn validateFacetTable(
    comptime Row: type,
    rows: []const Row,
    store: *const ast.Store,
    multi_valued: bool,
) error{InvalidDocument}!void {
    var previous: ?u32 = null;
    for (rows) |row| {
        if (previous) |entity| {
            if (multi_valued and row.entity.raw() < entity) return error.InvalidDocument;
            if (!multi_valued and row.entity.raw() <= entity) return error.InvalidDocument;
        }
        previous = row.entity.raw();
        inline for (@typeInfo(Row).@"struct".fields) |field| {
            if (field.type == ast.ByteRange and
                @field(row, field.name).end() > store.text.items.len)
            {
                return error.InvalidDocument;
            }
        }
    }
}

fn validateResources(
    store: *const ast.Store,
    limits: limits_mod.Limits,
) error{InvalidDocument}!void {
    if (store.resources.items.len > limits.max_resources) return error.InvalidDocument;
    if (store.resource_bytes.items.len > limits.max_resource_bytes) {
        return error.InvalidDocument;
    }
    for (store.resources.items) |resource| {
        if (resource.source.end() > store.text.items.len or
            resource.mime.end() > store.text.items.len or
            resource.alt.end() > store.text.items.len or
            resource.bytes.end() > store.resource_bytes.items.len)
        {
            return error.InvalidDocument;
        }
        if (resource.source.len == 0 or resource.mime.len == 0) {
            return error.InvalidDocument;
        }
        switch (resource.kind) {
            .embedded => if (resource.bytes.len == 0) return error.InvalidDocument,
            .external => if (resource.bytes.len != 0) return error.InvalidDocument,
        }
    }
}
