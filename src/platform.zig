//! Platform constraints and hard limits for Scoville.
//!
//! Scoville requires Linux on x86_64 or aarch64.  On x86_64 the VMware
//! backdoor uses I/O port 0x5658 via `inl`; on aarch64 it traps on a
//! read of the MDCCSR_EL0 debug register.

const std = @import("std");
const builtin = @import("builtin");

/// Hard resource limits that bound all internal buffers and collections.
pub const Limits = struct {
    /// Maximum clipboard payload size (1 MiB).
    max_clipboard_bytes: usize = 1 << 20,
    /// Maximum GuestRPC reply size (1 MiB).
    max_rpc_reply_bytes: usize = 1 << 20,
    /// Maximum number of MIME types tracked per clipboard selection.
    max_mime_types: usize = 8,
};

/// Returns true when the given arch+os combination supports the VMware
/// backdoor (x86_64 via I/O port, aarch64 via MDCCSR_EL0 trap).
pub fn supportsVmwareBackdoor(arch: std.Target.Cpu.Arch, os_tag: std.Target.Os.Tag) bool {
    return (arch == .x86_64 or arch == .aarch64) and os_tag == .linux;
}

/// Asserts at comptime that the current target can use the VMware backdoor.
/// Returns `error.UnsupportedPlatform` on unsupported targets so callers
/// can propagate the error instead of hitting a compile-time failure.
pub fn requireVmwareBackdoor() error{UnsupportedPlatform}!void {
    if (!comptime supportsVmwareBackdoor(builtin.cpu.arch, builtin.os.tag)) {
        return error.UnsupportedPlatform;
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "supportsVmwareBackdoor accepts x86_64 linux" {
    try std.testing.expect(supportsVmwareBackdoor(.x86_64, .linux));
}

test "supportsVmwareBackdoor accepts aarch64 linux" {
    try std.testing.expect(supportsVmwareBackdoor(.aarch64, .linux));
}

test "supportsVmwareBackdoor rejects x86_64 windows" {
    try std.testing.expect(!supportsVmwareBackdoor(.x86_64, .windows));
}

test "supportsVmwareBackdoor rejects aarch64 macos" {
    try std.testing.expect(!supportsVmwareBackdoor(.aarch64, .macos));
}

test "limit sanity: rpc reply >= clipboard" {
    const limits: Limits = .{};
    try std.testing.expect(limits.max_rpc_reply_bytes >= limits.max_clipboard_bytes);
}

test "limit sanity: max_mime_types > 0" {
    const limits: Limits = .{};
    try std.testing.expect(limits.max_mime_types > 0);
}
