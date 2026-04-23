//! VMware backdoor interface.
//!
//! The VMware backdoor is a paravirtual interface that allows guest code
//! to communicate with the hypervisor.  On x86_64 the guest executes an
//! `inl` instruction on I/O port 0x5658.  On aarch64 the guest reads
//! the MDCCSR_EL0 debug register with a magic sentinel in X7, which
//! VMware intercepts and handles as an emulated I/O operation.

const std = @import("std");
const builtin = @import("builtin");

/// Standard backdoor I/O port used for command/response exchanges.
pub const BACKDOOR_PORT: u16 = 0x5658;

/// High-bandwidth backdoor port used for bulk data transfers.
pub const BACKDOOR_HB_PORT: u16 = 0x5659;

/// Magic value loaded into EAX/X0 ("VMXh" as little-endian u32).
pub const MAGIC: u32 = 0x564D5868;

// ---------------------------------------------------------------------------
// Commands (low 16 bits of ECX)
// ---------------------------------------------------------------------------

/// Probe VMware presence and retrieve the hypervisor version.
pub const CMD_GET_VERSION: u16 = 0x0a;

// ---------------------------------------------------------------------------
// ARM64 control word constants (placed in X7)
// ---------------------------------------------------------------------------

/// Sentinel placed in X7 bits [63:32] so VMware recognises the trap.
const X86_IO_MAGIC: u64 = 0x86;

/// W7 bit: transfer size 4 bytes (bits [1:0] = 0b10).
const X86_IO_W7_SIZE_4B: u64 = 2;
/// W7 bit 2: direction = read (IN).
const X86_IO_W7_DIR: u64 = 1 << 2;
/// W7 bit 3: use DX register for port address.
const X86_IO_W7_WITH: u64 = 1 << 3;

// ---------------------------------------------------------------------------
// Errors
// ---------------------------------------------------------------------------

pub const Error = error{
    /// The current CPU architecture is not supported.
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
///
/// Field names use the x86 convention (eax–edi) regardless of the
/// underlying architecture; on aarch64 they map to X0–X5.
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
pub fn call(req: Registers) Error!Registers {
    return callPort(BACKDOOR_PORT, req);
}

/// Execute a VMware backdoor command on the high-bandwidth port (0x5659).
pub fn callHighBandwidth(req: Registers) Error!Registers {
    return callPort(BACKDOOR_HB_PORT, req);
}

fn callPort(port: u16, req: Registers) Error!Registers {
    if (comptime builtin.cpu.arch == .x86_64)
        return callX86(port, req)
    else if (comptime builtin.cpu.arch == .aarch64)
        return callArm64(port, req)
    else
        return error.UnsupportedArchitecture;
}

// ---------------------------------------------------------------------------
// x86_64: IN instruction on I/O port
// ---------------------------------------------------------------------------

fn callX86(port: u16, req: Registers) Registers {
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
          [_] "{edx}" (@as(u32, port)),
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

// ---------------------------------------------------------------------------
// aarch64: MRS XZR, MDCCSR_EL0 trapped by VMware
// ---------------------------------------------------------------------------

fn callArm64(port: u16, req: Registers) Registers {
    // X7 control word: low 32 = IO descriptor, high 32 = magic 0x86.
    const w7: u64 = (X86_IO_W7_WITH | X86_IO_W7_DIR | X86_IO_W7_SIZE_4B) |
        (X86_IO_MAGIC << 32);

    // Use explicit register constraints matching the x86 register mapping:
    //   x0=eax, x1=ebx, x2=ecx, x3=edx, x4=esi, x5=edi
    var out_x0: u64 = undefined;
    var out_x1: u64 = undefined;
    var out_x2: u64 = undefined;
    var out_x3: u64 = undefined;
    var out_x4: u64 = undefined;
    var out_x5: u64 = undefined;

    asm volatile ("mrs xzr, mdccsr_el0"
        : [_] "={x0}" (out_x0),
          [_] "={x1}" (out_x1),
          [_] "={x2}" (out_x2),
          [_] "={x3}" (out_x3),
          [_] "={x4}" (out_x4),
          [_] "={x5}" (out_x5),
        : [_] "{x0}" (@as(u64, MAGIC)),
          [_] "{x1}" (@as(u64, req.ebx)),
          [_] "{x2}" (@as(u64, req.ecx)),
          [_] "{x3}" (@as(u64, port)),
          [_] "{x4}" (@as(u64, req.esi)),
          [_] "{x5}" (@as(u64, req.edi)),
          [_] "{x7}" (w7),
    );

    return .{
        .eax = @truncate(out_x0),
        .ebx = @truncate(out_x1),
        .ecx = @truncate(out_x2),
        .edx = @truncate(out_x3),
        .esi = @truncate(out_x4),
        .edi = @truncate(out_x5),
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
