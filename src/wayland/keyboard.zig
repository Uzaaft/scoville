//! Keyboard serial tracker for Wayland clipboard operations.
//!
//! Wayland requires a valid keyboard enter serial to call
//! wl_data_device.set_selection.  This module listens for
//! wl_keyboard.enter events and records the most recent serial,
//! making it available for clipboard publish requests.

const std = @import("std");
const c = @import("c");

// ---------------------------------------------------------------------------
// Serial tracker
// ---------------------------------------------------------------------------

/// Tracks the most recent keyboard enter serial from the compositor.
///
/// The serial is required by wl_data_device.set_selection to prove
/// that the client holds keyboard focus.  A zero value means no
/// keyboard enter has been received yet.
pub const SerialTracker = struct {
    serial: u32,
    keyboard: ?*c.struct_wl_keyboard,

    /// Obtain the seat's keyboard and attach the listener that
    /// records enter serials.  Returns null when the seat has no
    /// keyboard capability.
    pub fn init(seat: *c.struct_wl_seat) ?SerialTracker {
        const keyboard = c.wl_seat_get_keyboard(seat) orelse return null;

        var tracker: SerialTracker = .{
            .serial = 0,
            .keyboard = keyboard,
        };

        _ = c.wl_keyboard_add_listener(keyboard, &KEYBOARD_LISTENER, @ptrCast(&tracker));

        return tracker;
    }

    /// Release the keyboard object back to the compositor.
    pub fn deinit(self: *SerialTracker) void {
        if (self.keyboard) |kb| {
            c.wl_keyboard_destroy(kb);
            self.keyboard = null;
        }
    }

    /// Return the last keyboard enter serial, or 0 if none received.
    pub fn lastSerial(self: *const SerialTracker) u32 {
        return self.serial;
    }
};

// ---------------------------------------------------------------------------
// Keyboard listener
// ---------------------------------------------------------------------------

fn handleEnter(
    data: ?*anyopaque,
    _: ?*c.struct_wl_keyboard,
    serial: u32,
    _: ?*c.struct_wl_surface,
    _: ?*c.struct_wl_array,
) callconv(.c) void {
    const tracker: *SerialTracker = @ptrCast(@alignCast(data));
    tracker.serial = serial;
    log.debug("keyboard enter, serial={d}", .{serial});
}

const log = std.log.scoped(.keyboard);

fn handleLeave(
    _: ?*anyopaque,
    _: ?*c.struct_wl_keyboard,
    _: u32,
    _: ?*c.struct_wl_surface,
) callconv(.c) void {}

fn handleKeymap(
    _: ?*anyopaque,
    _: ?*c.struct_wl_keyboard,
    _: u32,
    _: i32,
    _: u32,
) callconv(.c) void {}

fn handleKey(
    _: ?*anyopaque,
    _: ?*c.struct_wl_keyboard,
    _: u32,
    _: u32,
    _: u32,
    _: u32,
) callconv(.c) void {}

fn handleModifiers(
    _: ?*anyopaque,
    _: ?*c.struct_wl_keyboard,
    _: u32,
    _: u32,
    _: u32,
    _: u32,
    _: u32,
) callconv(.c) void {}

fn handleRepeatInfo(
    _: ?*anyopaque,
    _: ?*c.struct_wl_keyboard,
    _: i32,
    _: i32,
) callconv(.c) void {}

const KEYBOARD_LISTENER: c.struct_wl_keyboard_listener = .{
    .keymap = &handleKeymap,
    .enter = &handleEnter,
    .leave = &handleLeave,
    .key = &handleKey,
    .modifiers = &handleModifiers,
    .repeat_info = &handleRepeatInfo,
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "initial serial is zero" {
    const tracker: SerialTracker = .{
        .serial = 0,
        .keyboard = null,
    };
    try std.testing.expectEqual(@as(u32, 0), tracker.serial);
}
