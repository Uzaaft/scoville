//! Wayland clipboard publish path.
//!
//! Manages a wl_data_source to publish text to the Wayland clipboard.
//! Creates a data source, offers MIME types, and handles compositor
//! callbacks (send, cancelled) to fulfil clipboard requests from other
//! Wayland clients.

const std = @import("std");
const c = @import("c");
const source = @import("source.zig");
const clipboard = @import("clipboard.zig");

const Allocator = std.mem.Allocator;
const fd_t = std.posix.fd_t;

// ---------------------------------------------------------------------------
// Errors
// ---------------------------------------------------------------------------

pub const Error = error{
    CreateSourceFailed,
    GetDataDeviceFailed,
    ListenerFailed,
};

// ---------------------------------------------------------------------------
// Publisher
// ---------------------------------------------------------------------------

/// Publishes text to the Wayland clipboard by managing wl_data_source
/// lifecycle and responding to compositor send/cancel events.
pub const Publisher = struct {
    data_device: *c.struct_wl_data_device,
    manager: *c.struct_wl_data_device_manager,
    current_source: ?*c.struct_wl_data_source,
    text: ?[]const u8,
    allocator: Allocator,

    /// Obtain the data device from the manager and seat, returning a
    /// ready-to-use Publisher with no active source.
    pub fn init(
        allocator: Allocator,
        manager: *c.struct_wl_data_device_manager,
        seat: *c.struct_wl_seat,
    ) Error!Publisher {
        const device = c.wl_data_device_manager_get_data_device(manager, seat) orelse
            return error.GetDataDeviceFailed;
        return .{
            .data_device = device,
            .manager = manager,
            .current_source = null,
            .text = null,
            .allocator = allocator,
        };
    }

    /// Release the current data source and any owned text allocation.
    pub fn deinit(self: *Publisher) void {
        self.destroyCurrentSource();
    }

    /// Publish `text` to the Wayland clipboard with the given keyboard
    /// serial. Replaces any previously active data source.
    pub fn publish(
        self: *Publisher,
        text: []const u8,
        serial: u32,
    ) (Allocator.Error || Error)!void {
        self.destroyCurrentSource();

        const owned = try self.allocator.dupe(u8, text);
        errdefer self.allocator.free(owned);

        const new_source = c.wl_data_device_manager_create_data_source(self.manager) orelse
            return error.CreateSourceFailed;
        errdefer c.wl_data_source_destroy(new_source);

        for (&clipboard.MIME_PREFERENCE) |mime| {
            c.wl_data_source_offer(new_source, mime.ptr);
        }

        if (c.wl_data_source_add_listener(new_source, &DATA_SOURCE_LISTENER, self) != 0)
            return error.ListenerFailed;

        c.wl_data_device_set_selection(self.data_device, new_source, serial);

        self.current_source = new_source;
        self.text = owned;
    }

    /// Destroy the active data source and clear the compositor selection.
    pub fn clear(self: *Publisher) void {
        self.destroyCurrentSource();
        c.wl_data_device_set_selection(self.data_device, null, 0);
    }

    // -- private helpers --

    fn destroyCurrentSource(self: *Publisher) void {
        if (self.current_source) |src| c.wl_data_source_destroy(src);
        self.current_source = null;
        if (self.text) |t| self.allocator.free(t);
        self.text = null;
    }
};

// ---------------------------------------------------------------------------
// Data source listener
// ---------------------------------------------------------------------------

/// Compositor callback: another client requested the clipboard contents.
/// Write our stored text to the provided fd, then close it.
fn handleSend(
    data: ?*anyopaque,
    _: ?*c.struct_wl_data_source,
    _: [*c]const u8,
    fd: i32,
) callconv(.c) void {
    const self: *Publisher = @ptrCast(@alignCast(data));
    if (self.text) |text| {
        source.writeSendData(fd, text) catch {};
    }
    _ = std.c.close(fd);
}

/// Compositor callback: another source took ownership of the clipboard.
/// Clean up our source and text since they are no longer active.
fn handleCancelled(
    data: ?*anyopaque,
    _: ?*c.struct_wl_data_source,
) callconv(.c) void {
    const self: *Publisher = @ptrCast(@alignCast(data));
    if (self.text) |t| self.allocator.free(t);
    self.text = null;
    // The compositor has already invalidated the source; just null it out.
    self.current_source = null;
}

/// Compositor callback: target MIME type chosen. No action needed.
fn handleTarget(
    _: ?*anyopaque,
    _: ?*c.struct_wl_data_source,
    _: [*c]const u8,
) callconv(.c) void {}

const DATA_SOURCE_LISTENER: c.struct_wl_data_source_listener = .{
    .target = &handleTarget,
    .send = &handleSend,
    .cancelled = &handleCancelled,
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "Publisher struct zero-initializable with sentinel values" {
    const publisher: Publisher = .{
        .data_device = @ptrFromInt(0xDEAD0001),
        .manager = @ptrFromInt(0xDEAD0002),
        .current_source = null,
        .text = null,
        .allocator = std.testing.allocator,
    };
    try std.testing.expect(publisher.current_source == null);
    try std.testing.expect(publisher.text == null);
}

test "MIME_PREFERENCE entries are valid C strings" {
    for (&clipboard.MIME_PREFERENCE) |mime| {
        try std.testing.expect(mime.len > 0);
        // Zig string literals are null-terminated, which is required
        // by wl_data_source_offer.
        try std.testing.expect(mime.ptr[mime.len] == 0);
    }
}
