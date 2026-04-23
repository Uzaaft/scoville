//! Wayland clipboard selection watcher.
//!
//! Monitors `wl_data_device` for clipboard selection changes and produces
//! bridge events when new text content is available.  The compositor sends
//! `data_offer` events (listing MIME types) followed by a `selection` event
//! whenever the clipboard owner changes.  This module attaches listeners to
//! both objects and reads the clipboard content synchronously via a pipe.

const std = @import("std");
const c = @import("c");
const clipboard = @import("clipboard.zig");
const bridge_state = @import("../bridge/state.zig");
const platform = @import("../platform.zig");

const Allocator = std.mem.Allocator;
const fd_t = std.posix.fd_t;

const log = std.log.scoped(.watcher);

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

const MAX_TRACKED_MIMES: usize = 16;

// ---------------------------------------------------------------------------
// Errors
// ---------------------------------------------------------------------------

pub const Error = error{
    DataDeviceCreateFailed,
    ListenerAttachFailed,
};

// ---------------------------------------------------------------------------
// MimeList
// ---------------------------------------------------------------------------

/// Bounded list of MIME type matches observed during a `data_offer` sequence.
/// Tracks which entries from `MIME_PREFERENCE` have been seen so far.
pub const MimeList = struct {
    /// One bit per MIME_PREFERENCE entry, set when that MIME was offered.
    seen: [clipboard.MIME_PREFERENCE.len]bool = .{false} ** clipboard.MIME_PREFERENCE.len,
    count: usize = 0,

    /// Record a MIME type, marking the corresponding preference entry if it
    /// matches.  Extra offers beyond `MAX_TRACKED_MIMES` are silently ignored.
    pub fn track(self: *MimeList, mime: [*c]const u8) void {
        if (self.count >= MAX_TRACKED_MIMES) return;
        self.count += 1;

        const offered = std.mem.span(mime);
        for (&clipboard.MIME_PREFERENCE, 0..) |want, i| {
            if (std.mem.eql(u8, want, offered)) {
                self.seen[i] = true;
                return;
            }
        }
    }

    /// Returns true if at least one preferred MIME was offered.
    pub fn matchesAny(self: *const MimeList) bool {
        for (self.seen) |s| {
            if (s) return true;
        }
        return false;
    }

    /// Returns the highest-priority MIME string that was offered, or null.
    pub fn bestMatch(self: *const MimeList) ?[]const u8 {
        for (&clipboard.MIME_PREFERENCE, 0..) |want, i| {
            if (self.seen[i]) return want;
        }
        return null;
    }

    pub fn reset(self: *MimeList) void {
        self.seen = .{false} ** clipboard.MIME_PREFERENCE.len;
        self.count = 0;
    }
};

// ---------------------------------------------------------------------------
// Watcher
// ---------------------------------------------------------------------------

pub const Watcher = struct {
    data_device: *c.struct_wl_data_device,
    current_offer: ?*c.struct_wl_data_offer = null,
    offered_mimes: MimeList = .{},
    pending_event: ?bridge_state.Event = null,
    allocator: Allocator,

    /// Create a watcher by binding a `wl_data_device` from the manager and
    /// seat, then attaching the device listener.
    pub fn init(
        allocator: Allocator,
        manager: *c.struct_wl_data_device_manager,
        seat: *c.struct_wl_seat,
    ) Error!Watcher {
        const device = c.wl_data_device_manager_get_data_device(manager, seat) orelse
            return error.DataDeviceCreateFailed;

        var self: Watcher = .{
            .data_device = device,
            .allocator = allocator,
        };

        if (c.wl_data_device_add_listener(device, &DATA_DEVICE_LISTENER, @ptrCast(&self)) != 0) {
            return error.ListenerAttachFailed;
        }

        return self;
    }

    /// Release the data device and any in-flight offer.
    pub fn deinit(self: *Watcher) void {
        if (self.current_offer) |offer| {
            c.wl_data_offer_destroy(offer);
            self.current_offer = null;
        }
        freePendingPayload(self);
        c.wl_data_device_destroy(self.data_device);
        self.* = undefined;
    }

    /// Consume and return the pending bridge event, if any.
    pub fn takeEvent(self: *Watcher) ?bridge_state.Event {
        const event = self.pending_event;
        self.pending_event = null;
        return event;
    }

    fn freePendingPayload(self: *Watcher) void {
        if (self.pending_event) |ev| {
            switch (ev.payload) {
                .text => |text| self.allocator.free(text),
                .clear => {},
            }
            self.pending_event = null;
        }
    }
};

// ---------------------------------------------------------------------------
// Data device listener
// ---------------------------------------------------------------------------

const DATA_DEVICE_LISTENER: c.struct_wl_data_device_listener = .{
    .data_offer = &handleDataOffer,
    .selection = &handleSelection,
    .enter = &handleEnter,
    .leave = &handleLeave,
    .motion = &handleMotion,
    .drop = &handleDrop,
};

fn handleDataOffer(
    data: ?*anyopaque,
    _: ?*c.struct_wl_data_device,
    offer: ?*c.struct_wl_data_offer,
) callconv(.c) void {
    const self: *Watcher = @ptrCast(@alignCast(data));
    const new_offer = offer orelse return;

    if (self.current_offer) |old| {
        c.wl_data_offer_destroy(old);
    }

    self.current_offer = new_offer;
    self.offered_mimes.reset();
    log.debug("new data offer received", .{});

    _ = c.wl_data_offer_add_listener(new_offer, &OFFER_LISTENER, data);
}

fn handleSelection(
    data: ?*anyopaque,
    _: ?*c.struct_wl_data_device,
    offer: ?*c.struct_wl_data_offer,
) callconv(.c) void {
    const self: *Watcher = @ptrCast(@alignCast(data));

    // Free any previously unconsumed event payload.
    self.freePendingPayload();

    if (offer == null) {
        log.debug("selection cleared", .{});
        self.pending_event = .{
            .origin = .wayland,
            .selection = .clipboard,
            .payload = .clear,
        };
        return;
    }

    receiveSelection(self);
}

/// Read clipboard text from the current offer via a pipe and store a
/// pending bridge event.  Split from `handleSelection` to stay within
/// the function size limit.
fn receiveSelection(self: *Watcher) void {
    const best = self.offered_mimes.bestMatch() orelse {
        log.debug("no matching MIME type in offer", .{});
        return;
    };
    log.debug("receiving selection, mime={s}", .{best});

    var fds: [2]fd_t = undefined;
    if (std.c.pipe(&fds) != 0) {
        log.err("pipe creation failed for clipboard receive", .{});
        return;
    }
    const read_fd = fds[0];
    const write_fd = fds[1];

    const offer = self.current_offer orelse {
        _ = std.c.close(read_fd);
        _ = std.c.close(write_fd);
        return;
    };

    c.wl_data_offer_receive(offer, best.ptr, write_fd);
    _ = std.c.close(write_fd);

    const limits: platform.Limits = .{};
    const text = clipboard.readFdAlloc(self.allocator, read_fd, limits.max_clipboard_bytes) catch |err| {
        log.err("clipboard read failed: {}", .{err});
        _ = std.c.close(read_fd);
        return;
    };
    _ = std.c.close(read_fd);

    if (text.len == 0) {
        self.allocator.free(text);
        return;
    }

    log.info("received {d} bytes from wayland clipboard", .{text.len});
    self.pending_event = .{
        .origin = .wayland,
        .selection = .clipboard,
        .payload = .{ .text = text },
    };
}

fn handleEnter(
    _: ?*anyopaque,
    _: ?*c.struct_wl_data_device,
    _: u32,
    _: ?*c.struct_wl_surface,
    _: i32,
    _: i32,
    _: ?*c.struct_wl_data_offer,
) callconv(.c) void {}

fn handleLeave(
    _: ?*anyopaque,
    _: ?*c.struct_wl_data_device,
) callconv(.c) void {}

fn handleMotion(
    _: ?*anyopaque,
    _: ?*c.struct_wl_data_device,
    _: u32,
    _: i32,
    _: i32,
) callconv(.c) void {}

fn handleDrop(
    _: ?*anyopaque,
    _: ?*c.struct_wl_data_device,
) callconv(.c) void {}

// ---------------------------------------------------------------------------
// Offer listener
// ---------------------------------------------------------------------------

const OFFER_LISTENER: c.struct_wl_data_offer_listener = .{
    .offer = &handleOfferMime,
};

fn handleOfferMime(
    data: ?*anyopaque,
    _: ?*c.struct_wl_data_offer,
    mime_type: [*c]const u8,
) callconv(.c) void {
    const self: *Watcher = @ptrCast(@alignCast(data));
    self.offered_mimes.track(mime_type);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "MimeList tracks preferred MIMEs" {
    var list: MimeList = .{};
    list.track("image/png");
    list.track("text/plain");

    try std.testing.expect(list.matchesAny());
    try std.testing.expectEqualStrings("text/plain", list.bestMatch().?);
}

test "MimeList bestMatch returns highest priority" {
    var list: MimeList = .{};
    list.track("STRING");
    list.track("text/plain;charset=utf-8");

    // text/plain;charset=utf-8 has higher priority than STRING
    try std.testing.expectEqualStrings("text/plain;charset=utf-8", list.bestMatch().?);
}

test "MimeList returns null when no match" {
    var list: MimeList = .{};
    list.track("image/png");
    list.track("application/json");

    try std.testing.expect(!list.matchesAny());
    try std.testing.expect(list.bestMatch() == null);
}

test "MimeList respects capacity limit" {
    var list: MimeList = .{};
    for (0..MAX_TRACKED_MIMES + 4) |i| {
        _ = i;
        list.track("text/html");
    }
    try std.testing.expectEqual(MAX_TRACKED_MIMES, list.count);
}

test "MimeList reset clears state" {
    var list: MimeList = .{};
    list.track("text/plain");
    try std.testing.expect(list.matchesAny());

    list.reset();
    try std.testing.expect(!list.matchesAny());
    try std.testing.expectEqual(@as(usize, 0), list.count);
}
