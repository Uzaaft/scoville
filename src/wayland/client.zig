//! Wayland client bootstrap for display connection and global registry.
//!
//! Connects to the Wayland compositor, binds the globals required for
//! clipboard synchronization (wl_seat, wl_data_device_manager, and
//! optionally zwp_primary_selection_device_manager_v1), and exposes
//! the underlying display fd for event-loop integration.

const std = @import("std");
const c = @import("c");

// ---------------------------------------------------------------------------
// Errors
// ---------------------------------------------------------------------------

pub const Error = error{
    ConnectFailed,
    RoundtripFailed,
    MissingSeat,
    MissingDataDeviceManager,
};

// ---------------------------------------------------------------------------
// Globals
// ---------------------------------------------------------------------------

/// Wayland globals required for clipboard operation, populated by the
/// registry listener during the initial roundtrip.
pub const Globals = struct {
    seat: ?*c.struct_wl_seat = null,
    data_device_manager: ?*c.struct_wl_data_device_manager = null,
    /// Optional: not all compositors implement the primary selection protocol.
    primary_selection_manager: ?*c.struct_zwp_primary_selection_device_manager_v1 = null,
};

/// Validates that all required globals were bound during the registry
/// roundtrip. Primary selection manager is intentionally optional.
pub fn validateGlobals(globals: Globals) Error!void {
    if (globals.seat == null) return error.MissingSeat;
    if (globals.data_device_manager == null) return error.MissingDataDeviceManager;
}

// ---------------------------------------------------------------------------
// Registry listener
// ---------------------------------------------------------------------------

/// Names of the interfaces we bind from the global registry.
const IFACE_WL_SEAT = "wl_seat";
const IFACE_WL_DATA_DEVICE_MANAGER = "wl_data_device_manager";
const IFACE_ZWP_PRIMARY_SELECTION = "zwp_primary_selection_device_manager_v1";

fn handleGlobal(
    data: ?*anyopaque,
    registry: ?*c.struct_wl_registry,
    name: u32,
    interface: [*c]const u8,
    version: u32,
) callconv(.c) void {
    _ = version;
    const globals: *Globals = @ptrCast(@alignCast(data));
    const reg = registry orelse return;
    const iface_name = std.mem.span(interface);

    if (std.mem.eql(u8, iface_name, IFACE_WL_SEAT)) {
        globals.seat = @ptrCast(c.wl_registry_bind(reg, name, &c.wl_seat_interface, 1));
    } else if (std.mem.eql(u8, iface_name, IFACE_WL_DATA_DEVICE_MANAGER)) {
        globals.data_device_manager = @ptrCast(
            c.wl_registry_bind(reg, name, &c.wl_data_device_manager_interface, 3),
        );
    } else if (std.mem.eql(u8, iface_name, IFACE_ZWP_PRIMARY_SELECTION)) {
        globals.primary_selection_manager = @ptrCast(
            c.wl_registry_bind(reg, name, &c.zwp_primary_selection_device_manager_v1_interface, 1),
        );
    }
}

fn handleGlobalRemove(
    _: ?*anyopaque,
    _: ?*c.struct_wl_registry,
    _: u32,
) callconv(.c) void {}

const REGISTRY_LISTENER: c.struct_wl_registry_listener = .{
    .global = &handleGlobal,
    .global_remove = &handleGlobalRemove,
};

// ---------------------------------------------------------------------------
// Client
// ---------------------------------------------------------------------------

/// A connected Wayland client with the globals needed for clipboard bridging.
pub const Client = struct {
    display: *c.struct_wl_display,
    registry: *c.struct_wl_registry,
    globals: Globals,

    /// Connect to the default Wayland display, bind required globals,
    /// and validate that the compositor advertises everything we need.
    pub fn init() Error!Client {
        const display = c.wl_display_connect(null) orelse return error.ConnectFailed;
        const registry = c.wl_display_get_registry(display) orelse {
            c.wl_display_disconnect(display);
            return error.ConnectFailed;
        };

        var globals: Globals = .{};
        _ = c.wl_registry_add_listener(registry, &REGISTRY_LISTENER, @ptrCast(&globals));

        if (c.wl_display_roundtrip(display) < 0) {
            c.wl_display_disconnect(display);
            return error.RoundtripFailed;
        }

        try validateGlobals(globals);

        return .{
            .display = display,
            .registry = registry,
            .globals = globals,
        };
    }

    /// Tear down the Wayland connection and release bound globals.
    pub fn deinit(self: *Client) void {
        c.wl_registry_destroy(self.registry);
        c.wl_display_disconnect(self.display);
    }

    /// Perform a blocking roundtrip to flush requests and process events.
    pub fn roundtrip(self: *Client) Error!void {
        if (c.wl_display_roundtrip(self.display) < 0) return error.RoundtripFailed;
    }

    /// Returns the file descriptor backing the Wayland connection,
    /// suitable for polling in an event loop.
    pub fn fd(self: *const Client) i32 {
        return c.wl_display_get_fd(self.display);
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "Globals defaults are all null" {
    const globals: Globals = .{};
    try std.testing.expect(globals.seat == null);
    try std.testing.expect(globals.data_device_manager == null);
    try std.testing.expect(globals.primary_selection_manager == null);
}

test "validateGlobals rejects missing seat" {
    const globals: Globals = .{};
    try std.testing.expectError(error.MissingSeat, validateGlobals(globals));
}

test "validateGlobals rejects missing data device manager" {
    const globals: Globals = .{ .seat = @ptrFromInt(0xDEAD0001) };
    try std.testing.expectError(error.MissingDataDeviceManager, validateGlobals(globals));
}

test "validateGlobals accepts when required globals present" {
    const globals: Globals = .{
        .seat = @ptrFromInt(0xDEAD0001),
        .data_device_manager = @ptrFromInt(0xDEAD0002),
    };
    try validateGlobals(globals);
}

test "validateGlobals accepts without primary selection" {
    const globals: Globals = .{
        .seat = @ptrFromInt(0xDEAD0001),
        .data_device_manager = @ptrFromInt(0xDEAD0002),
    };
    try std.testing.expect(globals.primary_selection_manager == null);
    try validateGlobals(globals);
}
