//! Scoville: VMware guest-host clipboard bridge for Wayland.
//!
//! Provides a Zig library that communicates with the VMware hypervisor
//! through the backdoor I/O port (0x5658) and RPCI, bridging clipboard
//! data to and from the Wayland compositor via wl_data_device.

const std = @import("std");

test {
    _ = @import("platform.zig");
    _ = @import("vmware/backdoor.zig");
    _ = @import("vmware/rpci.zig");
    _ = @import("vmware/clipboard.zig");
    _ = @import("wayland/c.zig");
    _ = @import("wayland/client.zig");
    _ = @import("wayland/clipboard.zig");
    _ = @import("wayland/source.zig");
    _ = @import("wayland/keyboard.zig");
    _ = @import("wayland/watcher.zig");
    _ = @import("wayland/publisher.zig");
    _ = @import("vmware/poller.zig");
    _ = @import("bridge/state.zig");
    _ = @import("bridge/sync.zig");
    _ = @import("bridge/executor.zig");
    _ = @import("daemon.zig");
}
