//! GuestRPC/RPCI session transport layer.
//!
//! Implements the VMware GuestRPC protocol on top of the backdoor I/O port.
//! GuestRPC allows the guest to send text commands (e.g. RPCI "info-set"
//! or "vmx.capability.dnd_version") and receive replies from the hypervisor.
//!
//! The protocol multiplexes over CMD_MESSAGE (0x1E) with sub-commands encoded
//! in the upper 16 bits of ECX and channel IDs in the upper 16 bits of EDX.
//! Data is transferred 4 bytes at a time in EBX using little-endian packing.

const std = @import("std");
const backdoor = @import("backdoor.zig");
const platform = @import("../platform.zig");

const Allocator = std.mem.Allocator;

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

/// Backdoor command number for GuestRPC message operations.
pub const CMD_MESSAGE: u16 = 0x1e;

/// Magic value sent in EBX when opening a GuestRPC channel ("RPCI" as LE u32).
pub const GUESTRPC_MAGIC: u32 = 0x49435052;

/// Sub-commands placed in the upper 16 bits of ECX.
const SUBCMD_OPEN: u16 = 0x00;
const SUBCMD_COMMAND_LEN: u16 = 0x01;
const SUBCMD_COMMAND_DATA: u16 = 0x02;
const SUBCMD_REPLY_LEN: u16 = 0x03;
const SUBCMD_REPLY_DATA: u16 = 0x04;
const SUBCMD_REPLY_FINISH: u16 = 0x05;
const SUBCMD_CLOSE: u16 = 0x06;

/// GuestRPC status flag bits returned in the high 16 bits of ECX.
/// open-vm-tools checks only these bits, not exact ECX values, because
/// different VMware versions set different combinations of HB/CPT flags.
const STATUS_SUCCESS: u32 = 0x0001;
const STATUS_DORECV: u32 = 0x0002;

/// Cookie flag ORed into EBX during OPEN to request authenticated channels.
/// Modern VMware requires this; the hypervisor returns cookie values in
/// ESI/EDI that must accompany all subsequent calls on the channel.
const GUESTMSG_FLAG_COOKIE: u32 = 0x80000000;

/// Returns true when the SUCCESS bit is set in the ECX status word.
fn statusOk(ecx: u32) bool {
    return (ecx >> 16) & STATUS_SUCCESS != 0;
}

/// Reply status prefix indicating success ("1 " as little-endian u16).
const RPC_SUCCESS_PREFIX: u16 = 0x2031;

/// Length of the reply status prefix in bytes.
const REPLY_PREFIX_LEN: usize = 2;

// ---------------------------------------------------------------------------
// Error set
// ---------------------------------------------------------------------------

pub const Error = backdoor.Error || error{
    ChannelOpenFailed,
    SendFailed,
    ReceiveFailed,
    ReplyTooLarge,
    RpcFailed,
};

// ---------------------------------------------------------------------------
// Session
// ---------------------------------------------------------------------------

/// GuestRPC session parameterized over an I/O backend.
///
/// `Io` must provide `fn call(self: *Io, req: backdoor.Registers) backdoor.Error!backdoor.Registers`.
/// Production code uses the real backdoor; tests inject a `FakeIo` that
/// replays scripted register sequences.
pub fn Session(comptime Io: type) type {
    return struct {
        const Self = @This();

        channel_id: u16,
        cookie_high: u32,
        cookie_low: u32,
        io: *Io,

        // -- Lifecycle ------------------------------------------------------

        /// Open a new GuestRPC channel on the hypervisor.
        ///
        /// Tries cookie-authenticated mode first (GUESTMSG_FLAG_COOKIE),
        /// falling back to legacy mode if the hypervisor rejects it.
        pub fn open(io: *Io) Error!Self {
            // Try with cookie flag first (modern VMware).
            const reply = io.call(.{
                .ecx = makeEcx(SUBCMD_OPEN),
                .ebx = GUESTRPC_MAGIC | GUESTMSG_FLAG_COOKIE,
            }) catch |err| return err;

            if (statusOk(reply.ecx)) {
                return .{
                    .channel_id = @truncate(reply.edx >> 16),
                    .cookie_high = reply.esi,
                    .cookie_low = reply.edi,
                    .io = io,
                };
            }

            // Fallback: open without cookie flag (legacy VMware).
            const legacy = io.call(.{
                .ecx = makeEcx(SUBCMD_OPEN),
                .ebx = GUESTRPC_MAGIC,
            }) catch |err| return err;

            if (!statusOk(legacy.ecx)) {
                return error.ChannelOpenFailed;
            }

            return .{
                .channel_id = @truncate(legacy.edx >> 16),
                .cookie_high = 0,
                .cookie_low = 0,
                .io = io,
            };
        }

        /// Close the channel (best-effort; errors are silently ignored).
        pub fn close(self: *Self) void {
            _ = self.io.call(.{
                .ecx = makeEcx(SUBCMD_CLOSE),
                .edx = self.makeEdx(),
                .esi = self.cookie_high,
                .edi = self.cookie_low,
            }) catch {};
        }

        // -- Public API -----------------------------------------------------

        /// Send a command string and return the reply payload.
        ///
        /// The caller owns the returned slice and must free it with `allocator`.
        /// The 2-byte status prefix is validated and stripped from the result.
        ///
        /// The command length sent to the hypervisor includes a trailing NUL
        /// byte, matching open-vm-tools' `strlen(msg) + 1` convention.
        pub fn transactAlloc(
            self: *Self,
            allocator: Allocator,
            command: []const u8,
        ) Error![]u8 {
            try self.sendCommandLength(command.len + 1);
            try self.sendCommandData(command);
            // Send the NUL terminator as a final chunk.
            try self.sendCommandData(&.{0});

            const reply_header = try self.receiveReplyLength();
            const reply_id = reply_header.reply_id;
            const reply_len = reply_header.length;

            const limits: platform.Limits = .{};
            if (reply_len > limits.max_rpc_reply_bytes) {
                return error.ReplyTooLarge;
            }

            const buf = allocator.alloc(u8, reply_len) catch {
                return error.ReceiveFailed;
            };
            errdefer allocator.free(buf);

            try self.receiveReplyData(reply_id, buf);
            try self.finishReply(reply_id);

            if (buf.len < REPLY_PREFIX_LEN) {
                return error.RpcFailed;
            }
            const prefix = std.mem.readInt(u16, buf[0..2], .little);
            if (prefix != RPC_SUCCESS_PREFIX) {
                allocator.free(buf);
                return error.RpcFailed;
            }

            // Shift payload left to strip the 2-byte prefix, then shrink.
            std.mem.copyForwards(u8, buf[0 .. buf.len - REPLY_PREFIX_LEN], buf[REPLY_PREFIX_LEN..]);
            const result = allocator.realloc(buf, buf.len - REPLY_PREFIX_LEN) catch {
                // realloc to shrink should not fail, but handle it gracefully.
                return buf[0 .. buf.len - REPLY_PREFIX_LEN];
            };
            return result;
        }

        // -- TCLO (host→guest) API ------------------------------------------

        /// Poll for a pending host→guest message on this channel.
        ///
        /// Returns the raw message bytes if one is available, or null if the
        /// channel is idle.  The caller owns the returned slice and must free
        /// it with `allocator`.
        ///
        /// Unlike `receiveReplyLength` (which expects the full 0x0083 status),
        /// this checks the individual DORECV bit to distinguish "no data" from
        /// "data ready", allowing non-blocking polling on TCLO channels.
        pub fn tryReceiveAlloc(
            self: *Self,
            allocator: Allocator,
        ) Error!?[]u8 {
            const reply = try self.io.call(.{
                .ecx = makeEcx(SUBCMD_REPLY_LEN),
                .edx = self.makeEdx(),
                .esi = self.cookie_high,
                .edi = self.cookie_low,
            });

            const status = reply.ecx >> 16;
            if (status & STATUS_SUCCESS == 0) return error.ReceiveFailed;
            if (status & STATUS_DORECV == 0) return null;

            const length: usize = reply.ebx;
            if (length == 0) return null;

            const limits: platform.Limits = .{};
            if (length > limits.max_rpc_reply_bytes) return error.ReplyTooLarge;

            const reply_id: u16 = @truncate(reply.edx >> 16);

            const buf = allocator.alloc(u8, length) catch {
                return error.ReceiveFailed;
            };
            errdefer allocator.free(buf);

            try self.receiveReplyData(reply_id, buf);
            try self.finishReply(reply_id);
            return buf;
        }

        /// Send a reply after processing a TCLO message.
        ///
        /// The response is typically "OK" or "ERROR" and is sent using the
        /// same command-length/command-data sub-commands used for RPCI sends.
        pub fn sendReply(self: *Self, response: []const u8) Error!void {
            try self.sendCommandLength(response.len);
            try self.sendCommandData(response);
        }

        // -- Private helpers ------------------------------------------------

        fn sendCommandLength(self: *Self, length: usize) Error!void {
            const reply = try self.io.call(.{
                .ecx = makeEcx(SUBCMD_COMMAND_LEN),
                .edx = self.makeEdx(),
                .ebx = @truncate(length),
                .esi = self.cookie_high,
                .edi = self.cookie_low,
            });

            if (!statusOk(reply.ecx)) {
                return error.SendFailed;
            }
        }

        fn sendCommandData(self: *Self, command: []const u8) Error!void {
            var offset: usize = 0;
            while (offset < command.len) {
                const remaining = command.len - offset;
                var chunk: [4]u8 = .{ 0, 0, 0, 0 };
                const n = @min(remaining, 4);
                @memcpy(chunk[0..n], command[offset..][0..n]);

                const word = std.mem.readInt(u32, &chunk, .little);

                const reply = try self.io.call(.{
                    .ecx = makeEcx(SUBCMD_COMMAND_DATA),
                    .edx = self.makeEdx(),
                    .ebx = word,
                    .esi = self.cookie_high,
                    .edi = self.cookie_low,
                });

                if (!statusOk(reply.ecx)) {
                    return error.SendFailed;
                }

                offset += 4;
            }
        }

        const ReplyHeader = struct {
            reply_id: u16,
            length: usize,
        };

        fn receiveReplyLength(self: *Self) Error!ReplyHeader {
            const reply = try self.io.call(.{
                .ecx = makeEcx(SUBCMD_REPLY_LEN),
                .edx = self.makeEdx(),
                .esi = self.cookie_high,
                .edi = self.cookie_low,
            });

            if (!statusOk(reply.ecx)) {
                return error.ReceiveFailed;
            }

            return .{
                .reply_id = @truncate(reply.edx >> 16),
                .length = reply.ebx,
            };
        }

        fn receiveReplyData(
            self: *Self,
            reply_id: u16,
            buf: []u8,
        ) Error!void {
            var offset: usize = 0;
            while (offset < buf.len) {
                const reply = try self.io.call(.{
                    .ecx = makeEcx(SUBCMD_REPLY_DATA),
                    .edx = self.makeEdx(),
                    .ebx = @as(u32, reply_id),
                    .esi = self.cookie_high,
                    .edi = self.cookie_low,
                });

                if (!statusOk(reply.ecx)) {
                    return error.ReceiveFailed;
                }

                var word_bytes: [4]u8 = undefined;
                std.mem.writeInt(u32, &word_bytes, reply.ebx, .little);

                const remaining = buf.len - offset;
                const n = @min(remaining, 4);
                @memcpy(buf[offset..][0..n], word_bytes[0..n]);

                offset += 4;
            }
        }

        fn finishReply(self: *Self, reply_id: u16) Error!void {
            const reply = try self.io.call(.{
                .ecx = makeEcx(SUBCMD_REPLY_FINISH),
                .edx = self.makeEdx(),
                .ebx = @as(u32, reply_id),
                .esi = self.cookie_high,
                .edi = self.cookie_low,
            });

            if (!statusOk(reply.ecx)) {
                return error.ReceiveFailed;
            }
        }

        // -- Register encoding ----------------------------------------------

        fn makeEdx(self: *const Self) u32 {
            return @as(u32, backdoor.BACKDOOR_PORT) | (@as(u32, self.channel_id) << 16);
        }

        fn makeEcx(subcmd: u16) u32 {
            return @as(u32, CMD_MESSAGE) | (@as(u32, subcmd) << 16);
        }
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const FakeIo = struct {
    replies: []const backdoor.Registers,
    call_index: usize = 0,

    fn call(self: *FakeIo, _: backdoor.Registers) backdoor.Error!backdoor.Registers {
        std.debug.assert(self.call_index < self.replies.len);
        const reply = self.replies[self.call_index];
        self.call_index += 1;
        return reply;
    }
};

test "open and close" {
    const channel_id: u16 = 0x0007;

    var io: FakeIo = .{
        .replies = &.{
            // open reply: success, channel in EDX high word
            .{ .ecx = (STATUS_SUCCESS << 16), .edx = @as(u32, channel_id) << 16 },
            // close reply: success (ignored)
            .{ .ecx = (STATUS_SUCCESS << 16) },
        },
    };

    var session = try Session(FakeIo).open(&io);
    try std.testing.expectEqual(channel_id, session.channel_id);

    session.close();
    try std.testing.expectEqual(@as(usize, 2), io.call_index);
}

test "open fails on bad status" {
    var io: FakeIo = .{
        .replies = &.{
            // cookie attempt fails
            .{ .ecx = 0x0000_0000 },
            // legacy fallback also fails
            .{ .ecx = 0x0000_0000 },
        },
    };

    const result = Session(FakeIo).open(&io);
    try std.testing.expectError(error.ChannelOpenFailed, result);
}

test "transactAlloc with short reply" {
    const channel_id: u16 = 0x0003;
    const reply_id: u16 = 0x0042;

    // Command: "ping" (4 bytes = 1 data chunk)
    // Reply: "1 ok" (4 bytes total, 2 bytes payload after prefix strip)
    const reply_word = std.mem.readInt(u32, "1 ok", .little);

    var io: FakeIo = .{
        .replies = &.{
            // open
            .{ .ecx = (STATUS_SUCCESS << 16), .edx = @as(u32, channel_id) << 16 },
            // sendCommandLength
            .{ .ecx = (STATUS_SUCCESS << 16) },
            // sendCommandData (1 chunk for "ping")
            .{ .ecx = (STATUS_SUCCESS << 16) },
            // sendCommandData (NUL terminator)
            .{ .ecx = (STATUS_SUCCESS << 16) },
            // receiveReplyLength: 4 bytes, reply_id in edx high
            .{
                .ecx = ((STATUS_SUCCESS | STATUS_DORECV) << 16),
                .ebx = 4,
                .edx = @as(u32, reply_id) << 16,
            },
            // receiveReplyData (1 chunk)
            .{ .ecx = (STATUS_SUCCESS << 16), .ebx = reply_word },
            // finishReply
            .{ .ecx = (STATUS_SUCCESS << 16) },
            // close
            .{ .ecx = (STATUS_SUCCESS << 16) },
        },
    };

    var session = try Session(FakeIo).open(&io);
    defer session.close();

    const reply = try session.transactAlloc(std.testing.allocator, "ping");
    defer std.testing.allocator.free(reply);

    try std.testing.expectEqualStrings("ok", reply);
}

test "oversized reply rejected with ReplyTooLarge" {
    const channel_id: u16 = 0x0001;
    const limits: platform.Limits = .{};

    var io: FakeIo = .{
        .replies = &.{
            // open
            .{ .ecx = (STATUS_SUCCESS << 16), .edx = @as(u32, channel_id) << 16 },
            // sendCommandLength
            .{ .ecx = (STATUS_SUCCESS << 16) },
            // sendCommandData (1 chunk for "big")
            .{ .ecx = (STATUS_SUCCESS << 16) },
            // sendCommandData (NUL terminator)
            .{ .ecx = (STATUS_SUCCESS << 16) },
            // receiveReplyLength: exceeds limit
            .{
                .ecx = ((STATUS_SUCCESS | STATUS_DORECV) << 16),
                .ebx = @truncate(limits.max_rpc_reply_bytes + 1),
                .edx = @as(u32, 0x0099) << 16,
            },
            // close (after error, caller closes)
            .{ .ecx = (STATUS_SUCCESS << 16) },
        },
    };

    var session = try Session(FakeIo).open(&io);
    defer session.close();

    const result = session.transactAlloc(std.testing.allocator, "big");
    try std.testing.expectError(error.ReplyTooLarge, result);
}

test "tryReceiveAlloc returns null when no data pending" {
    const channel_id: u16 = 0x0005;

    var io: FakeIo = .{
        .replies = &.{
            // open
            .{ .ecx = (STATUS_SUCCESS << 16), .edx = @as(u32, channel_id) << 16 },
            // REPLY_LEN: success but no DORECV bit (no data pending)
            .{ .ecx = STATUS_SUCCESS << 16 },
            // close
            .{ .ecx = (STATUS_SUCCESS << 16) },
        },
    };

    var session = try Session(FakeIo).open(&io);
    defer session.close();

    const result = try session.tryReceiveAlloc(std.testing.allocator);
    try std.testing.expect(result == null);
}

test "tryReceiveAlloc returns message when data pending" {
    const channel_id: u16 = 0x0006;
    const reply_id: u16 = 0x0010;

    // "test" as a 4-byte LE u32
    const data_word = std.mem.readInt(u32, "test", .little);

    var io: FakeIo = .{
        .replies = &.{
            // open
            .{ .ecx = (STATUS_SUCCESS << 16), .edx = @as(u32, channel_id) << 16 },
            // REPLY_LEN: success + DORECV, 4 bytes pending
            .{
                .ecx = (STATUS_SUCCESS | STATUS_DORECV) << 16,
                .ebx = 4,
                .edx = @as(u32, reply_id) << 16,
            },
            // receiveReplyData
            .{ .ecx = (STATUS_SUCCESS << 16), .ebx = data_word },
            // finishReply
            .{ .ecx = (STATUS_SUCCESS << 16) },
            // close
            .{ .ecx = (STATUS_SUCCESS << 16) },
        },
    };

    var session = try Session(FakeIo).open(&io);
    defer session.close();

    const result = try session.tryReceiveAlloc(std.testing.allocator);
    defer std.testing.allocator.free(result.?);

    try std.testing.expectEqualStrings("test", result.?);
}

test "sendReply transmits response" {
    const channel_id: u16 = 0x0008;

    var io: FakeIo = .{
        .replies = &.{
            // open
            .{ .ecx = (STATUS_SUCCESS << 16), .edx = @as(u32, channel_id) << 16 },
            // sendCommandLength for "OK "
            .{ .ecx = (STATUS_SUCCESS << 16) },
            // sendCommandData (1 chunk for "OK ")
            .{ .ecx = (STATUS_SUCCESS << 16) },
            // close
            .{ .ecx = (STATUS_SUCCESS << 16) },
        },
    };

    var session = try Session(FakeIo).open(&io);
    defer session.close();

    try session.sendReply("OK ");
}
