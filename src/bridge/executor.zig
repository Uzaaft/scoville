//! Bridge action executor.
//!
//! Wires the pure bridge state machine actions to real VMware and Wayland
//! I/O subsystems. The `Runtime` struct holds pointers to every I/O backend
//! and dispatches each `Action` produced by `state.Bridge.process`.

const std = @import("std");

const state = @import("state.zig");
const poller_mod = @import("../vmware/poller.zig");
const publisher_mod = @import("../wayland/publisher.zig");
const keyboard_mod = @import("../wayland/keyboard.zig");

const log = std.log.scoped(.executor);

// ---------------------------------------------------------------------------
// Errors
// ---------------------------------------------------------------------------

pub const Error = poller_mod.Error || publisher_mod.Error || std.mem.Allocator.Error;

// ---------------------------------------------------------------------------
// Runtime
// ---------------------------------------------------------------------------

/// Dispatches bridge actions to the corresponding VMware or Wayland I/O
/// subsystem. Holds borrowed pointers to all backends; the caller owns
/// their lifetimes.
pub const Runtime = struct {
    poller: *poller_mod.Poller,
    publisher: *publisher_mod.Publisher,
    serial_tracker: *keyboard_mod.SerialTracker,

    /// Execute a single bridge action against the real I/O backends.
    pub fn dispatch(self: *Runtime, action: state.Action) Error!void {
        switch (action) {
            .push_vmware => |data| {
                log.info("sending {d} bytes to vmware host", .{data.text.len});
                try self.poller.sendClipboard(data.text);
            },
            .push_wayland => |data| {
                const serial = self.serial_tracker.lastSerial();
                log.info("publishing {d} bytes to wayland, serial={d}", .{ data.text.len, serial });
                try self.publisher.publish(data.text, serial);
            },
            .clear_wayland => {
                log.info("clearing wayland selection", .{});
                self.publisher.clear();
            },
            .clear_vmware => |sel| {
                log.debug("clear_vmware requested for {s}, not yet implemented", .{@tagName(sel)});
            },
            .none => {},
        }
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "Runtime struct is referenceable" {
    // Compile-time verification that the type is well-formed.
    try std.testing.expect(@sizeOf(Runtime) > 0);
}

test "dispatch handles .none without error" {
    // .none requires no I/O, so dispatch must succeed with any (dangling)
    // pointer values — the pointers are never dereferenced for this variant.
    var runtime: Runtime = .{
        .poller = @ptrFromInt(@alignOf(poller_mod.Poller)),
        .publisher = @ptrFromInt(@alignOf(publisher_mod.Publisher)),
        .serial_tracker = @ptrFromInt(@alignOf(keyboard_mod.SerialTracker)),
    };
    try runtime.dispatch(.{ .none = {} });
}
