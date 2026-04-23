//! Daemon configuration and event loop skeleton.
//!
//! Defines the runtime configuration for the clipboard bridge daemon
//! and the single-iteration poll step that integrates Wayland events
//! with VMware clipboard polling through the bridge state machine.

const std = @import("std");
const platform = @import("platform.zig");
const bridge_state = @import("bridge/state.zig");

// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------

/// Runtime configuration for the clipboard bridge daemon.
pub const Config = struct {
    /// Wayland display name (null = $WAYLAND_DISPLAY default).
    display_name: ?[]const u8 = null,
    /// Whether to synchronize the primary selection (X11 middle-click paste).
    enable_primary: bool = true,
    /// Maximum clipboard payload size in bytes.
    max_clipboard_bytes: usize = (platform.Limits{}).max_clipboard_bytes,
    /// Interval between VMware clipboard polls, in milliseconds.
    vmware_poll_interval_ms: u32 = 250,
};

// ---------------------------------------------------------------------------
// Event loop step
// ---------------------------------------------------------------------------

/// Result of a single event loop iteration.
pub const StepResult = enum {
    /// Continue polling.
    cont,
    /// Wayland connection lost or fatal error; shut down.
    shutdown,
};

/// Execute one iteration of the event loop.
///
/// Generic over a context type that provides poll/dispatch methods,
/// allowing the real daemon to inject Wayland + VMware subsystems
/// while tests inject fakes.
pub fn runStep(comptime Ctx: type, ctx: *Ctx, bridge: *bridge_state.Bridge) StepResult {
    // Poll for Wayland events and VMware clipboard changes.
    const events = ctx.poll() catch return .shutdown;

    for (events) |event| {
        const action = bridge.process(event);
        ctx.execute(action) catch return .shutdown;
    }

    return .cont;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const TestCtx = struct {
    events: []const bridge_state.Event,
    poll_count: usize = 0,
    exec_count: usize = 0,
    should_fail_poll: bool = false,
    should_fail_exec: bool = false,

    const PollError = error{PollFailed};
    const ExecError = error{ExecFailed};

    fn poll(self: *TestCtx) PollError![]const bridge_state.Event {
        if (self.should_fail_poll) return error.PollFailed;
        self.poll_count += 1;
        return self.events;
    }

    fn execute(self: *TestCtx, _: bridge_state.Action) ExecError!void {
        if (self.should_fail_exec) return error.ExecFailed;
        self.exec_count += 1;
    }
};

test "Config defaults match platform limits" {
    const config: Config = .{};
    const limits: platform.Limits = .{};
    try std.testing.expectEqual(limits.max_clipboard_bytes, config.max_clipboard_bytes);
    try std.testing.expect(config.enable_primary);
    try std.testing.expectEqual(@as(u32, 250), config.vmware_poll_interval_ms);
    try std.testing.expect(config.display_name == null);
}

test "runStep processes events" {
    const events = [_]bridge_state.Event{.{
        .origin = .vmware,
        .selection = .clipboard,
        .payload = .{ .text = "test" },
    }};
    var ctx: TestCtx = .{ .events = &events };
    var bridge: bridge_state.Bridge = .{};

    const result = runStep(TestCtx, &ctx, &bridge);
    try std.testing.expectEqual(StepResult.cont, result);
    try std.testing.expectEqual(@as(usize, 1), ctx.poll_count);
    try std.testing.expectEqual(@as(usize, 1), ctx.exec_count);
}

test "runStep returns shutdown on poll failure" {
    var ctx: TestCtx = .{ .events = &.{}, .should_fail_poll = true };
    var bridge: bridge_state.Bridge = .{};

    const result = runStep(TestCtx, &ctx, &bridge);
    try std.testing.expectEqual(StepResult.shutdown, result);
}

test "runStep returns shutdown on exec failure" {
    const events = [_]bridge_state.Event{.{
        .origin = .wayland,
        .selection = .clipboard,
        .payload = .{ .text = "fail" },
    }};
    var ctx: TestCtx = .{ .events = &events, .should_fail_exec = true };
    var bridge: bridge_state.Bridge = .{};

    const result = runStep(TestCtx, &ctx, &bridge);
    try std.testing.expectEqual(StepResult.shutdown, result);
}

test "runStep with empty events is no-op" {
    var ctx: TestCtx = .{ .events = &.{} };
    var bridge: bridge_state.Bridge = .{};

    const result = runStep(TestCtx, &ctx, &bridge);
    try std.testing.expectEqual(StepResult.cont, result);
    try std.testing.expectEqual(@as(usize, 1), ctx.poll_count);
    try std.testing.expectEqual(@as(usize, 0), ctx.exec_count);
}
