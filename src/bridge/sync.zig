//! Clipboard synchronization coordinator.
//!
//! Maps bridge state machine actions to concrete operations on the
//! VMware and Wayland subsystems.  This module defines the Executor
//! interface and provides a dispatcher that routes actions from the
//! state machine to the appropriate side.

const std = @import("std");
const state = @import("state.zig");

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

pub const Error = error{
    PushFailed,
    ClearFailed,
};

/// Interface for executing bridge actions.
///
/// Production code implements this with real RPCI and Wayland calls.
/// Tests inject a recording implementation.
pub fn Executor(comptime Ctx: type) type {
    return struct {
        ctx: *Ctx,
        pushWaylandFn: *const fn (*Ctx, state.Selection, []const u8) Error!void,
        pushVmwareFn: *const fn (*Ctx, state.Selection, []const u8) Error!void,
        clearWaylandFn: *const fn (*Ctx, state.Selection) Error!void,
        clearVmwareFn: *const fn (*Ctx, state.Selection) Error!void,

        const Self = @This();

        /// Dispatch a single action from the bridge state machine.
        pub fn dispatch(self: *const Self, action: state.Action) Error!void {
            switch (action) {
                .push_wayland => |d| try self.pushWaylandFn(self.ctx, d.selection, d.text),
                .push_vmware => |d| try self.pushVmwareFn(self.ctx, d.selection, d.text),
                .clear_wayland => |sel| try self.clearWaylandFn(self.ctx, sel),
                .clear_vmware => |sel| try self.clearVmwareFn(self.ctx, sel),
                .none => {},
            }
        }
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const TestRecord = struct {
    calls: [16]Call = undefined,
    count: usize = 0,

    const Call = struct {
        kind: enum { push_wayland, push_vmware, clear_wayland, clear_vmware },
        selection: state.Selection,
        text: ?[]const u8 = null,
    };

    fn pushWayland(self: *TestRecord, sel: state.Selection, text: []const u8) Error!void {
        self.record(.{ .kind = .push_wayland, .selection = sel, .text = text });
    }
    fn pushVmware(self: *TestRecord, sel: state.Selection, text: []const u8) Error!void {
        self.record(.{ .kind = .push_vmware, .selection = sel, .text = text });
    }
    fn clearWayland(self: *TestRecord, sel: state.Selection) Error!void {
        self.record(.{ .kind = .clear_wayland, .selection = sel });
    }
    fn clearVmware(self: *TestRecord, sel: state.Selection) Error!void {
        self.record(.{ .kind = .clear_vmware, .selection = sel });
    }

    fn record(self: *TestRecord, call: Call) void {
        std.debug.assert(self.count < self.calls.len);
        self.calls[self.count] = call;
        self.count += 1;
    }
};

fn makeTestExecutor(rec: *TestRecord) Executor(TestRecord) {
    return .{
        .ctx = rec,
        .pushWaylandFn = &TestRecord.pushWayland,
        .pushVmwareFn = &TestRecord.pushVmware,
        .clearWaylandFn = &TestRecord.clearWayland,
        .clearVmwareFn = &TestRecord.clearVmware,
    };
}

test "dispatch push_wayland action" {
    var rec: TestRecord = .{};
    const exec = makeTestExecutor(&rec);

    try exec.dispatch(.{ .push_wayland = .{
        .selection = .clipboard,
        .text = "hello",
    } });

    try std.testing.expectEqual(@as(usize, 1), rec.count);
    try std.testing.expectEqual(.push_wayland, rec.calls[0].kind);
    try std.testing.expectEqualStrings("hello", rec.calls[0].text.?);
}

test "dispatch push_vmware action" {
    var rec: TestRecord = .{};
    const exec = makeTestExecutor(&rec);

    try exec.dispatch(.{ .push_vmware = .{
        .selection = .primary,
        .text = "world",
    } });

    try std.testing.expectEqual(@as(usize, 1), rec.count);
    try std.testing.expectEqual(.push_vmware, rec.calls[0].kind);
    try std.testing.expectEqual(state.Selection.primary, rec.calls[0].selection);
}

test "dispatch clear actions" {
    var rec: TestRecord = .{};
    const exec = makeTestExecutor(&rec);

    try exec.dispatch(.{ .clear_wayland = .clipboard });
    try exec.dispatch(.{ .clear_vmware = .primary });

    try std.testing.expectEqual(@as(usize, 2), rec.count);
    try std.testing.expectEqual(.clear_wayland, rec.calls[0].kind);
    try std.testing.expectEqual(.clear_vmware, rec.calls[1].kind);
}

test "dispatch none is no-op" {
    var rec: TestRecord = .{};
    const exec = makeTestExecutor(&rec);

    try exec.dispatch(.{ .none = {} });

    try std.testing.expectEqual(@as(usize, 0), rec.count);
}

test "bridge + executor integration" {
    var bridge: state.Bridge = .{};
    var rec: TestRecord = .{};
    const exec = makeTestExecutor(&rec);

    const action = bridge.process(.{
        .origin = .vmware,
        .selection = .clipboard,
        .payload = .{ .text = "sync" },
    });
    try exec.dispatch(action);

    try std.testing.expectEqual(@as(usize, 1), rec.count);
    try std.testing.expectEqual(.push_wayland, rec.calls[0].kind);
    try std.testing.expectEqualStrings("sync", rec.calls[0].text.?);
}
