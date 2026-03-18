const std = @import("std");
const testing = std.testing;
const lib_alloc = @import("../../lib/allocator.zig");
const CAllocator = lib_alloc.Allocator;
const terminal_c = @import("terminal.zig");
const renderpkg = @import("../render.zig");
const Result = @import("result.zig").Result;

const RenderStateWrapper = struct {
    alloc: std.mem.Allocator,
    state: renderpkg.RenderState = .empty,
};

/// C: GhosttyRenderState
pub const RenderState = ?*RenderStateWrapper;

/// C: GhosttyRenderStateDirty
pub const Dirty = renderpkg.RenderState.Dirty;

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
}
