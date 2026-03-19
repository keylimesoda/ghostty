const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const lib = @import("../../lib/main.zig");
const lib_alloc = @import("../../lib/allocator.zig");
const CAllocator = lib_alloc.Allocator;
const colorpkg = @import("../color.zig");
const page = @import("../page.zig");
const size = @import("../size.zig");
const terminal_c = @import("terminal.zig");
const renderpkg = @import("../render.zig");
const Result = @import("result.zig").Result;

const RenderStateWrapper = struct {
    alloc: std.mem.Allocator,
    state: renderpkg.RenderState = .empty,
};

const RowIteratorWrapper = struct {
    alloc: std.mem.Allocator,

    /// The current index (also y value) into the row list.
    y: size.CellCountInt,

    /// These are the raw pointers into the render state data.
    raws: []const page.Row,
    cells: []const std.MultiArrayList(renderpkg.RenderState.Cell),
    dirty: []const bool,
};

/// C: GhosttyRenderState
pub const RenderState = ?*RenderStateWrapper;

/// C: GhosttyRenderStateRowIterator
pub const RowIterator = ?*RowIteratorWrapper;

/// C: GhosttyRenderStateDirty
pub const Dirty = renderpkg.RenderState.Dirty;

/// C: GhosttyRenderStateColors
pub const Colors = extern struct {
    size: usize = @sizeOf(Colors),
    background: colorpkg.RGB.C,
    foreground: colorpkg.RGB.C,
    cursor: colorpkg.RGB.C,
    cursor_has_value: bool,
    palette: [256]colorpkg.RGB.C,
};

pub fn new(
    alloc_: ?*const CAllocator,
    result: *RenderState,
) callconv(.c) Result {
    result.* = new_(alloc_) catch |err| {
        result.* = null;
        return switch (err) {
            error.OutOfMemory => .out_of_memory,
        };
    };

    return .success;
}

fn new_(alloc_: ?*const CAllocator) error{OutOfMemory}!*RenderStateWrapper {
    const alloc = lib_alloc.default(alloc_);
    const ptr = alloc.create(RenderStateWrapper) catch
        return error.OutOfMemory;
    ptr.* = .{ .alloc = alloc };
    return ptr;
}

pub fn update(
    state_: RenderState,
    terminal_: terminal_c.Terminal,
) callconv(.c) Result {
    const state = state_ orelse return .invalid_value;
    const t = terminal_ orelse return .invalid_value;

    state.state.update(state.alloc, t) catch return .out_of_memory;
    return .success;
}

pub fn size_get(
    state_: RenderState,
    out_cols_: ?*size.CellCountInt,
    out_rows_: ?*size.CellCountInt,
) callconv(.c) Result {
    const state = state_ orelse return .invalid_value;
    const out_cols = out_cols_ orelse return .invalid_value;
    const out_rows = out_rows_ orelse return .invalid_value;

    out_cols.* = state.state.cols;
    out_rows.* = state.state.rows;
    return .success;
}

pub fn colors_get(
    state_: RenderState,
    out_colors_: ?*Colors,
) callconv(.c) Result {
    const state = state_ orelse return .invalid_value;
    const out_colors = out_colors_ orelse return .invalid_value;
    const out_size = out_colors.size;
    if (out_size < @sizeOf(usize)) return .invalid_value;

    const colors = state.state.colors;
    if (lib.structSizedFieldFits(
        Colors,
        out_size,
        "background",
    )) {
        out_colors.background = colors.background.cval();
    }

    if (lib.structSizedFieldFits(
        Colors,
        out_size,
        "foreground",
    )) {
        out_colors.foreground = colors.foreground.cval();
    }

    if (colors.cursor) |cursor| {
        if (lib.structSizedFieldFits(
            Colors,
            out_size,
            "cursor",
        )) {
            out_colors.cursor = cursor.cval();
        }
    }

    if (lib.structSizedFieldFits(
        Colors,
        out_size,
        "cursor_has_value",
    )) {
        out_colors.cursor_has_value = colors.cursor != null;
    }

    if (lib.structSizedFieldFits(
        Colors,
        out_size,
        "palette",
    )) {
        const palette_offset = @offsetOf(Colors, "palette");
        if (out_size > palette_offset) {
            const available = out_size - palette_offset;
            const max_entries = @min(colors.palette.len, available / @sizeOf(colorpkg.RGB.C));
            for (0..max_entries) |i| {
                out_colors.palette[i] = colors.palette[i].cval();
            }
        }
    }

    return .success;
}

pub fn dirty_get(
    state_: RenderState,
    out_dirty: *Dirty,
) callconv(.c) Result {
    const state = state_ orelse return .invalid_value;
    out_dirty.* = state.state.dirty;
    return .success;
}

pub fn dirty_set(
    state_: RenderState,
    dirty_: c_int,
) callconv(.c) Result {
    const state = state_ orelse return .invalid_value;
    const dirty = std.meta.intToEnum(Dirty, dirty_) catch
        return .invalid_value;
    state.state.dirty = dirty;
    return .success;
}

pub fn row_iterator_new(
    alloc_: ?*const CAllocator,
    state_: RenderState,
    out_iterator_: ?*RowIterator,
) callconv(.c) Result {
    const state = state_ orelse return .invalid_value;
    const out_iterator = out_iterator_ orelse return .invalid_value;
    const alloc = lib_alloc.default(alloc_);

    out_iterator.* = row_iterator_new_(
        alloc,
        state,
    ) catch |err| {
        out_iterator.* = null;
        switch (err) {
            error.OutOfMemory => return .out_of_memory,
        }
    };

    return .success;
}

fn row_iterator_new_(
    alloc: Allocator,
    state: *RenderStateWrapper,
) !*RowIteratorWrapper {
    const it = try alloc.create(RowIteratorWrapper);
    errdefer alloc.destroy(it);

    const row_data = state.state.row_data.slice();
    it.* = .{
        .alloc = alloc,
        .y = 0,
        .raws = row_data.items(.raw),
        .cells = row_data.items(.cells),
        .dirty = row_data.items(.dirty),
    };

    return it;
}

pub fn row_iterator_free(iterator_: RowIterator) callconv(.c) void {
    const iterator = iterator_ orelse return;
    const alloc = iterator.alloc;
    alloc.destroy(iterator);
}

pub fn free(state_: RenderState) callconv(.c) void {
    const state = state_ orelse return;
    const alloc = state.alloc;
    state.state.deinit(alloc);
    alloc.destroy(state);
}

test "render: new/free" {
    var state: RenderState = null;
    try testing.expectEqual(Result.success, new(
        &lib_alloc.test_allocator,
        &state,
    ));
    try testing.expect(state != null);
    free(state);
}

test "render: free null" {
    free(null);
}

test "render: update invalid value" {
    var state: RenderState = null;
    try testing.expectEqual(Result.success, new(
        &lib_alloc.test_allocator,
        &state,
    ));
    defer free(state);

    try testing.expectEqual(Result.invalid_value, update(null, null));
    try testing.expectEqual(Result.invalid_value, update(state, null));
}

test "render: size get invalid value" {
    var state: RenderState = null;
    try testing.expectEqual(Result.success, new(
        &lib_alloc.test_allocator,
        &state,
    ));
    defer free(state);

    var cols: size.CellCountInt = 0;
    var rows: size.CellCountInt = 0;
    try testing.expectEqual(Result.invalid_value, size_get(
        null,
        &cols,
        &rows,
    ));
    try testing.expectEqual(Result.invalid_value, size_get(
        state,
        null,
        &rows,
    ));
    try testing.expectEqual(Result.invalid_value, size_get(
        state,
        &cols,
        null,
    ));
}

test "render: colors get invalid value" {
    var state: RenderState = null;
    try testing.expectEqual(Result.success, new(
        &lib_alloc.test_allocator,
        &state,
    ));
    defer free(state);

    var colors: Colors = std.mem.zeroes(Colors);
    colors.size = @sizeOf(Colors);

    try testing.expectEqual(Result.invalid_value, colors_get(null, &colors));
    try testing.expectEqual(Result.invalid_value, colors_get(state, null));

    colors.size = @sizeOf(usize) - 1;
    try testing.expectEqual(Result.invalid_value, colors_get(state, &colors));
}

test "render: dirty get/set invalid value" {
    var state: RenderState = null;
    try testing.expectEqual(Result.success, new(
        &lib_alloc.test_allocator,
        &state,
    ));
    defer free(state);

    var dirty: Dirty = .false;
    try testing.expectEqual(Result.invalid_value, dirty_get(null, &dirty));
    try testing.expectEqual(Result.invalid_value, dirty_set(
        null,
        @intFromEnum(Dirty.full),
    ));
}

test "render: dirty get/set" {
    var state: RenderState = null;
    try testing.expectEqual(Result.success, new(
        &lib_alloc.test_allocator,
        &state,
    ));
    defer free(state);

    var dirty: Dirty = undefined;
    try testing.expectEqual(Result.success, dirty_get(state, &dirty));
    try testing.expectEqual(Dirty.false, dirty);

    try testing.expectEqual(Result.success, dirty_set(
        state,
        @intFromEnum(Dirty.partial),
    ));
    try testing.expectEqual(Result.success, dirty_get(state, &dirty));
    try testing.expectEqual(Dirty.partial, dirty);

    try testing.expectEqual(Result.success, dirty_set(
        state,
        @intFromEnum(Dirty.full),
    ));
    try testing.expectEqual(Result.success, dirty_get(state, &dirty));
    try testing.expectEqual(Dirty.full, dirty);
}

test "render: dirty set invalid enum value" {
    var state: RenderState = null;
    try testing.expectEqual(Result.success, new(
        &lib_alloc.test_allocator,
        &state,
    ));
    defer free(state);

    try testing.expectEqual(Result.invalid_value, dirty_set(state, 99));
}

test "render: row iterator new invalid value" {
    var state: RenderState = null;
    try testing.expectEqual(Result.success, new(
        &lib_alloc.test_allocator,
        &state,
    ));
    defer free(state);

    var iterator: RowIterator = null;
    try testing.expectEqual(Result.invalid_value, row_iterator_new(
        &lib_alloc.test_allocator,
        null,
        &iterator,
    ));
    try testing.expectEqual(Result.invalid_value, row_iterator_new(
        &lib_alloc.test_allocator,
        state,
        null,
    ));
}

test "render: row iterator new/free" {
    var terminal: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib_alloc.test_allocator,
        &terminal,
        .{
            .cols = 80,
            .rows = 24,
            .max_scrollback = 10_000,
        },
    ));
    defer terminal_c.free(terminal);

    var state: RenderState = null;
    try testing.expectEqual(Result.success, new(
        &lib_alloc.test_allocator,
        &state,
    ));
    defer free(state);

    try testing.expectEqual(Result.success, update(state, terminal));

    var iterator: RowIterator = null;
    try testing.expectEqual(Result.success, row_iterator_new(
        &lib_alloc.test_allocator,
        state,
        &iterator,
    ));
    defer row_iterator_free(iterator);

    try testing.expect(iterator != null);
    const iterator_ptr = iterator.?;
    const row_data = state.?.state.row_data.slice();

    try testing.expectEqual(@as(size.CellCountInt, 0), iterator_ptr.y);
    try testing.expectEqual(row_data.items(.raw).len, iterator_ptr.raws.len);
    try testing.expectEqual(row_data.items(.cells).len, iterator_ptr.cells.len);
    try testing.expectEqual(row_data.items(.dirty).len, iterator_ptr.dirty.len);
}

test "render: row iterator free null" {
    row_iterator_free(null);
}

test "render: update" {
    var terminal: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib_alloc.test_allocator,
        &terminal,
        .{
            .cols = 80,
            .rows = 24,
            .max_scrollback = 10_000,
        },
    ));
    defer terminal_c.free(terminal);

    var state: RenderState = null;
    try testing.expectEqual(Result.success, new(
        &lib_alloc.test_allocator,
        &state,
    ));
    defer free(state);

    try testing.expectEqual(Result.success, update(state, terminal));

    terminal_c.vt_write(terminal, "hello", 5);
    try testing.expectEqual(Result.success, update(state, terminal));

    var cols: size.CellCountInt = 0;
    var rows: size.CellCountInt = 0;
    try testing.expectEqual(Result.success, size_get(
        state,
        &cols,
        &rows,
    ));
    try testing.expectEqual(@as(size.CellCountInt, 80), cols);
    try testing.expectEqual(@as(size.CellCountInt, 24), rows);
}

test "render: colors get" {
    var terminal: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib_alloc.test_allocator,
        &terminal,
        .{
            .cols = 80,
            .rows = 24,
            .max_scrollback = 10_000,
        },
    ));
    defer terminal_c.free(terminal);

    var state: RenderState = null;
    try testing.expectEqual(Result.success, new(
        &lib_alloc.test_allocator,
        &state,
    ));
    defer free(state);

    try testing.expectEqual(Result.success, update(state, terminal));

    var colors: Colors = std.mem.zeroes(Colors);
    colors.size = @sizeOf(Colors);
    try testing.expectEqual(Result.success, colors_get(state, &colors));

    const state_colors = &state.?.state.colors;
    try testing.expectEqual(state_colors.background.cval(), colors.background);
    try testing.expectEqual(state_colors.foreground.cval(), colors.foreground);

    if (state_colors.cursor) |cursor| {
        try testing.expect(colors.cursor_has_value);
        try testing.expectEqual(cursor.cval(), colors.cursor);
    } else {
        try testing.expect(!colors.cursor_has_value);
    }

    for (state_colors.palette, colors.palette) |expected, actual| {
        try testing.expectEqual(expected.cval(), actual);
    }
}

test "render: colors get supports truncated sized struct" {
    var terminal: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib_alloc.test_allocator,
        &terminal,
        .{
            .cols = 80,
            .rows = 24,
            .max_scrollback = 10_000,
        },
    ));
    defer terminal_c.free(terminal);

    var state: RenderState = null;
    try testing.expectEqual(Result.success, new(
        &lib_alloc.test_allocator,
        &state,
    ));
    defer free(state);

    try testing.expectEqual(Result.success, update(state, terminal));

    var colors: Colors = std.mem.zeroes(Colors);
    const sentinel: colorpkg.RGB.C = .{ .r = 0xAA, .g = 0xBB, .b = 0xCC };
    for (&colors.palette) |*entry| entry.* = sentinel;

    colors.size = @offsetOf(Colors, "palette") + @sizeOf(colorpkg.RGB.C) * 2;
    try testing.expectEqual(Result.success, colors_get(state, &colors));

    const state_colors = &state.?.state.colors;
    try testing.expectEqual(state_colors.palette[0].cval(), colors.palette[0]);
    try testing.expectEqual(state_colors.palette[1].cval(), colors.palette[1]);
    try testing.expectEqual(sentinel, colors.palette[2]);
}
