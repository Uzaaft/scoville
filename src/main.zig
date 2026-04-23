//! Scoville daemon entry point.
//!
//! Initializes the Wayland client, probes for the VMware hypervisor,
//! and runs the clipboard bridge event loop until the Wayland
//! connection is lost or a fatal error occurs.

const std = @import("std");

const backdoor = @import("vmware/backdoor.zig");
const poller_mod = @import("vmware/poller.zig");
const client_mod = @import("wayland/client.zig");
const keyboard = @import("wayland/keyboard.zig");
const watcher_mod = @import("wayland/watcher.zig");
const publisher_mod = @import("wayland/publisher.zig");
const bridge_state = @import("bridge/state.zig");
const executor = @import("bridge/executor.zig");
const daemon = @import("daemon.zig");

const log = std.log.scoped(.scoville);

const allocator = std.heap.c_allocator;

/// All subsystems needed for the event loop, initialized together
/// and torn down in reverse order.
const Subsystems = struct {
    wl_client: client_mod.Client,
    serial_tracker: keyboard.SerialTracker,
    clip_watcher: watcher_mod.Watcher,
    clip_publisher: publisher_mod.Publisher,
    vmware_poller: poller_mod.Poller,
    bridge: bridge_state.Bridge,
    runtime: executor.Runtime,
};

pub fn main() void {
    log.info("scoville starting", .{});

    var subs = initSubsystems() orelse {
        std.process.exit(1);
    };
    defer deinitSubsystems(&subs);

    // Wire runtime pointers now that subs is at its final stack address.
    // Runtime borrows into Subsystems fields, so this must happen after
    // the struct move from initSubsystems' return value is complete.
    subs.runtime = .{
        .poller = &subs.vmware_poller,
        .publisher = &subs.clip_publisher,
        .serial_tracker = &subs.serial_tracker,
    };

    runLoop(&subs);

    log.info("scoville exiting", .{});
}

/// Initialize all subsystems in dependency order.
/// Returns null on any failure after logging the error.
fn initSubsystems() ?Subsystems {
    backdoor.probeVmware() catch |err| {
        log.err("vmware hypervisor not detected: {}", .{err});
        return null;
    };

    var wl_client = client_mod.Client.init() catch |err| {
        log.err("wayland client init failed: {}", .{err});
        return null;
    };
    errdefer wl_client.deinit();

    const seat = wl_client.globals.seat.?;
    const manager = wl_client.globals.data_device_manager.?;

    var serial_tracker = keyboard.SerialTracker.init(seat) orelse {
        log.err("keyboard serial tracker init failed: seat has no keyboard", .{});
        wl_client.deinit();
        return null;
    };
    errdefer serial_tracker.deinit();

    var clip_watcher = watcher_mod.Watcher.init(allocator, manager, seat) catch |err| {
        log.err("clipboard watcher init failed: {}", .{err});
        serial_tracker.deinit();
        wl_client.deinit();
        return null;
    };
    errdefer clip_watcher.deinit();

    var clip_publisher = publisher_mod.Publisher.init(allocator, manager, seat) catch |err| {
        log.err("clipboard publisher init failed: {}", .{err});
        clip_watcher.deinit();
        serial_tracker.deinit();
        wl_client.deinit();
        return null;
    };
    errdefer clip_publisher.deinit();

    var vmware_poller = poller_mod.Poller.init(allocator) catch |err| {
        log.err("vmware poller init failed: {}", .{err});
        clip_publisher.deinit();
        clip_watcher.deinit();
        serial_tracker.deinit();
        wl_client.deinit();
        return null;
    };
    errdefer vmware_poller.deinit();

    return .{
        .wl_client = wl_client,
        .serial_tracker = serial_tracker,
        .clip_watcher = clip_watcher,
        .clip_publisher = clip_publisher,
        .vmware_poller = vmware_poller,
        .bridge = .{},
        // Initialized by main after the struct is at its final address.
        .runtime = undefined,
    };
}

/// Tear down all subsystems in reverse initialization order.
fn deinitSubsystems(subs: *Subsystems) void {
    subs.vmware_poller.deinit();
    subs.clip_publisher.deinit();
    subs.clip_watcher.deinit();
    subs.serial_tracker.deinit();
    subs.wl_client.deinit();
}

/// Poll for Wayland and VMware events, dispatching through the bridge.
fn runLoop(subs: *Subsystems) void {
    const config: daemon.Config = .{};
    const wl_fd = subs.wl_client.fd();

    while (true) {
        var fds = [1]std.c.pollfd{.{
            .fd = wl_fd,
            .events = std.c.POLL.IN,
            .revents = 0,
        }};

        const poll_ret = std.c.poll(&fds, 1, @intCast(config.vmware_poll_interval_ms));

        if (poll_ret < 0) {
            log.err("poll failed", .{});
            return;
        }

        // Dispatch Wayland events if the fd is readable.
        if (fds[0].revents & std.c.POLL.IN != 0) {
            subs.wl_client.roundtrip() catch |err| {
                log.err("wayland roundtrip failed: {}", .{err});
                return;
            };
        }

        processEvents(subs);
    }
}

/// Drain pending events from both sources and dispatch through the bridge.
fn processEvents(subs: *Subsystems) void {
    if (subs.clip_watcher.takeEvent()) |event| {
        const action = subs.bridge.process(event);
        subs.runtime.dispatch(action) catch |err| {
            log.err("bridge dispatch failed for wayland event: {}", .{err});
        };
    }

    const vmware_event = subs.vmware_poller.poll() catch |err| {
        log.err("vmware poll failed: {}", .{err});
        return;
    };
    if (vmware_event) |event| {
        const action = subs.bridge.process(event);
        subs.runtime.dispatch(action) catch |err| {
            log.err("bridge dispatch failed for vmware event: {}", .{err});
        };
    }
}
