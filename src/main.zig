//! Scoville daemon entry point.
//!
//! Initializes the Wayland client, probes for the VMware hypervisor,
//! and runs the clipboard bridge event loop until the Wayland
//! connection is lost or a fatal error occurs.

const std = @import("std");
const daemon = @import("daemon.zig");

const log = std.log.scoped(.scoville);

pub fn main() void {
    const config: daemon.Config = .{};
    _ = config;

    log.info("scoville starting", .{});
    log.info("scoville exiting", .{});
}
