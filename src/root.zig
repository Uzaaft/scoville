//! Scoville: VMware guest-host clipboard bridge for Wayland.
//!
//! Provides a Zig library that communicates with the VMware hypervisor
//! through the backdoor I/O port (0x5658) and RPCI, bridging clipboard
//! data to and from the Wayland compositor via wl_data_device.

const std = @import("std");

test {
    // Register submodule tests here as the project grows:
    // _ = @import("vmware/backdoor.zig");
    // _ = @import("wayland/clipboard.zig");
    // _ = @import("bridge.zig");
}
