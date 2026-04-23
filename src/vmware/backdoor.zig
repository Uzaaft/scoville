//! VMware backdoor I/O port (0x5658) interface.
//!
//! The VMware backdoor is a paravirtual interface that allows guest code
//! to communicate with the hypervisor using x86 IN/OUT instructions on
//! a magic I/O port. The guest loads specific values into registers
//! (including the magic number 0x564D5868 "VMXh") and executes an IN
//! instruction on port 0x5658.

const std = @import("std");
const builtin = @import("builtin");

/// Standard backdoor I/O port used for command/response exchanges.
pub const BACKDOOR_PORT: u16 = 0x5658;

/// High-bandwidth backdoor port used for bulk data transfers.
pub const BACKDOOR_HB_PORT: u16 = 0x5659;

/// Magic value loaded into EAX ("VMXh" as little-endian u32).
pub const MAGIC: u32 = 0x564D5868;

// ---------------------------------------------------------------------------
// Commands (low 16 bits of ECX)
// ---------------------------------------------------------------------------

/// Probe VMware presence and retrieve the hypervisor version.
pub const CMD_GET_VERSION: u16 = 0x0a;

// ---------------------------------------------------------------------------
// Errors
// ---------------------------------------------------------------------------

pub const Error = error{
    /// The current CPU architecture does not support x86 IN/OUT instructions.
    UnsupportedArchitecture,
    /// The backdoor probe did not return the expected magic value.
    HypervisorUnavailable,
    /// A backdoor call produced an unexpected result.
    BackdoorFailed,
};

// ---------------------------------------------------------------------------
// Register pack
// ---------------------------------------------------------------------------

/// Register state passed to and returned from a backdoor call.
pub const Registers = struct {
    eax: u32 = MAGIC,
    ebx: u32 = 0,
    ecx: u32 = 0,
    edx: u32 = BACKDOOR_PORT,
    esi: u32 = 0,
    edi: u32 = 0,
};

// ---------------------------------------------------------------------------
// Backdoor invocation
// ---------------------------------------------------------------------------

/// Execute a VMware backdoor command on the standard port (0x5658).
///
/// Loads the register pack into x86 registers, executes `inl %dx, %eax`,
/// and returns the hypervisor's response in all six registers.
pub fn call(req: Registers) Error!Registers {
    if (comptime builtin.cpu.arch != .x86_64) {
        return error.UnsupportedArchitecture;
    }

    var out_eax: u32 = undefined;
    var out_ebx: u32 = undefined;
    var out_ecx: u32 = undefined;
    var out_edx: u32 = undefined;
    var out_esi: u32 = undefined;
    var out_edi: u32 = undefined;

    asm volatile ("inl %%dx, %%eax"
        : [_] "={eax}" (out_eax),
          [_] "={ebx}" (out_ebx),
          [_] "={ecx}" (out_ecx),
          [_] "={edx}" (out_edx),
          [_] "={esi}" (out_esi),
          [_] "={edi}" (out_edi),
        : [_] "{eax}" (MAGIC),
          [_] "{ebx}" (req.ebx),
          [_] "{ecx}" (req.ecx),
          [_] "{edx}" (@as(u32, BACKDOOR_PORT)),
          [_] "{esi}" (req.esi),
          [_] "{edi}" (req.edi),
    );

    return .{
        .eax = out_eax,
        .ebx = out_ebx,
        .ecx = out_ecx,
        .edx = out_edx,
        .esi = out_esi,
        .edi = out_edi,
    };
}

/// Execute a VMware backdoor command on the high-bandwidth port (0x5659).
///
/// Identical to `call` except that the transfer uses the HB port, which
/// is intended for bulk data (rep outsb / rep insb). The instruction is
/// kept as a simple `inl` for now; the rep-string variant will be added
/// when the GuestRPC data-transfer path is implemented.
pub fn callHighBandwidth(req: Registers) Error!Registers {
    if (comptime builtin.cpu.arch != .x86_64) {
        return error.UnsupportedArchitecture;
    }

    var out_eax: u32 = undefined;
    var out_ebx: u32 = undefined;
    var out_ecx: u32 = undefined;
    var out_edx: u32 = undefined;
    var out_esi: u32 = undefined;
    var out_edi: u32 = undefined;

    asm volatile ("inl %%dx, %%eax"
        : [_] "={eax}" (out_eax),
          [_] "={ebx}" (out_ebx),
          [_] "={ecx}" (out_ecx),
          [_] "={edx}" (out_edx),
          [_] "={esi}" (out_esi),
          [_] "={edi}" (out_edi),
        : [_] "{eax}" (MAGIC),
          [_] "{ebx}" (req.ebx),
          [_] "{ecx}" (req.ecx),
          [_] "{edx}" (@as(u32, BACKDOOR_HB_PORT)),
          [_] "{esi}" (req.esi),
          [_] "{edi}" (req.edi),
    );

    return .{
        .eax = out_eax,
        .ebx = out_ebx,
        .ecx = out_ecx,
        .edx = out_edx,
        .esi = out_esi,
        .edi = out_edi,
    };
}

/// Probe for a running VMware hypervisor.
///
/// Sends CMD_GET_VERSION through the backdoor and checks that the reply
/// contains the expected magic value in EBX. Returns
/// `error.HypervisorUnavailable` when the magic does not match (i.e.
/// we are not running inside a VMware virtual machine).
pub fn probeVmware() Error!void {
    const reply = try call(.{
        .ecx = CMD_GET_VERSION,
    });

    if (reply.ebx != MAGIC) {
        return error.HypervisorUnavailable;
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "BACKDOOR_PORT has correct value" {
    try std.testing.expectEqual(@as(u16, 0x5658), BACKDOOR_PORT);
}

test "BACKDOOR_HB_PORT has correct value" {
    try std.testing.expectEqual(@as(u16, 0x5659), BACKDOOR_HB_PORT);
}

test "MAGIC has correct value" {
    try std.testing.expectEqual(@as(u32, 0x564D5868), MAGIC);
}

test "CMD_GET_VERSION has correct value" {
    try std.testing.expectEqual(@as(u16, 0x0a), CMD_GET_VERSION);
}

test "Registers default values" {
    const regs: Registers = .{};
    try std.testing.expectEqual(MAGIC, regs.eax);
    try std.testing.expectEqual(@as(u32, 0), regs.ebx);
    try std.testing.expectEqual(@as(u32, 0), regs.ecx);
    try std.testing.expectEqual(@as(u32, BACKDOOR_PORT), regs.edx);
    try std.testing.expectEqual(@as(u32, 0), regs.esi);
    try std.testing.expectEqual(@as(u32, 0), regs.edi);
}

test "smoke: probeVmware inside VMware" {
    // Only runs when explicitly opted in; will SIGILL outside a VMware guest.
    // Use the libc getenv since the build system links libc.
    if (std.c.getenv("SCOVILLE_VMWARE_SMOKE") == null) return;

    probeVmware() catch |err| {
        std.debug.print("probeVmware failed: {}\n", .{err});
        return err;
    };
}
