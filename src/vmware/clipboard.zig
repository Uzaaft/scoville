//! VMware clipboard protocol layer (V4).
//!
//! Implements the DnD/CopyPaste V4 binary protocol used by VMware to
//! synchronize clipboard contents between the host and the guest.
//! Sits on top of the RPCI transport: capability negotiation uses plain
//! RPCI text commands, while clipboard data travels as binary packets
//! prefixed with "copypaste.transport ".

const std = @import("std");
const platform = @import("../platform.zig");

const Allocator = std.mem.Allocator;

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

/// V4 packet header size: 14 × u32 = 56 bytes.
pub const HEADER_SIZE: usize = 56;

/// Maximum number of clipboard format slots in the CPClipboard wire format.
pub const MAX_FORMAT_SLOTS: u32 = 11;

// -- Message types ----------------------------------------------------------

pub const MSG_TYPE_CP: u32 = 2;

// -- Source identifiers -----------------------------------------------------

pub const SRC_HOST: u32 = 1;
pub const SRC_GUEST: u32 = 3;

// -- Commands ---------------------------------------------------------------

pub const CMD_PING: u32 = 1;
pub const CMD_PING_REPLY: u32 = 2;
pub const CMD_REQUEST_NEXT: u32 = 3;
pub const CMD_REPLY: u32 = 4;
pub const CMD_REQUEST_CLIPBOARD: u32 = 2000;
pub const CMD_REQUEST_FILES: u32 = 2001;
pub const CMD_RECV_CLIPBOARD: u32 = 2002;
pub const CMD_SEND_CLIPBOARD: u32 = 2003;

// -- Capability mask bits ---------------------------------------------------

pub const CAP_VALID: u32 = 1 << 0;
pub const CAP_DND: u32 = 1 << 1;
pub const CAP_CP: u32 = 1 << 2;
pub const CAP_PLAIN_TEXT_CP: u32 = 1 << 4;

/// Capability mask for text-only clipboard support.
pub const CAP_TEXT_CLIPBOARD: u32 = CAP_VALID | CAP_CP | CAP_PLAIN_TEXT_CP;

// -- Clipboard format indices -----------------------------------------------

pub const CPFORMAT_TEXT: u32 = 1;

// -- RPCI command strings ---------------------------------------------------

pub const RPCI_SET_CP_VERSION = "tools.capability.copypaste_version 4";
pub const RPCI_GET_CP_VERSION = "vmx.capability.copypaste_version";
pub const RPCI_TRANSPORT_PREFIX = "copypaste.transport ";

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

/// Which X11/Wayland selection the clipboard event applies to.
pub const SelectionKind = enum(u8) {
    clipboard = 0,
    primary = 1,
};

/// DnDCPMsgHdrV4: 14 × u32 packed little-endian.
pub const HeaderV4 = struct {
    cmd: u32 = 0,
    msg_type: u32 = MSG_TYPE_CP,
    src: u32 = SRC_GUEST,
    session_id: u32 = 0,
    status: u32 = 0,
    param1: u32 = 0,
    param2: u32 = 0,
    param3: u32 = 0,
    param4: u32 = 0,
    param5: u32 = 0,
    param6: u32 = 0,
    binary_size: u32 = 0,
    payload_offset: u32 = 0,
    payload_size: u32 = 0,

    const FIELD_COUNT = 14;

    /// Serialize the header into a 56-byte little-endian buffer.
    pub fn encode(self: *const HeaderV4) [HEADER_SIZE]u8 {
        var buf: [HEADER_SIZE]u8 = undefined;
        const fields = [FIELD_COUNT]u32{
            self.cmd,
            self.msg_type,
            self.src,
            self.session_id,
            self.status,
            self.param1,
            self.param2,
            self.param3,
            self.param4,
            self.param5,
            self.param6,
            self.binary_size,
            self.payload_offset,
            self.payload_size,
        };
        for (fields, 0..) |val, i| {
            std.mem.writeInt(u32, buf[i * 4 ..][0..4], val, .little);
        }
        return buf;
    }

    /// Decode a 56-byte little-endian buffer into a HeaderV4.
    pub fn decode(buf: *const [HEADER_SIZE]u8) HeaderV4 {
        var fields: [FIELD_COUNT]u32 = undefined;
        for (&fields, 0..) |*f, i| {
            f.* = std.mem.readInt(u32, buf[i * 4 ..][0..4], .little);
        }
        return .{
            .cmd = fields[0],
            .msg_type = fields[1],
            .src = fields[2],
            .session_id = fields[3],
            .status = fields[4],
            .param1 = fields[5],
            .param2 = fields[6],
            .param3 = fields[7],
            .param4 = fields[8],
            .param5 = fields[9],
            .param6 = fields[10],
            .binary_size = fields[11],
            .payload_offset = fields[12],
            .payload_size = fields[13],
        };
    }
};

// ---------------------------------------------------------------------------
// Errors
// ---------------------------------------------------------------------------

pub const Error = error{
    InvalidPayload,
    FormatIndexOutOfRange,
    PayloadTooLarge,
};

// ---------------------------------------------------------------------------
// CPClipboard serialization
// ---------------------------------------------------------------------------

/// Serialize a text-only CPClipboard payload.
///
/// Wire format: u32 maxFmt, then for each slot 0..maxFmt-1:
///   u32 exists (bool), if exists: u32 size, [size]u8 data.
/// Finally: u32 changed (bool).
/// `text` must be NUL-terminated UTF-8 (as VMware expects).
pub fn serializeClipboard(
    allocator: Allocator,
    text: []const u8,
) Allocator.Error![]u8 {
    // Compute total size:
    //   4 (maxFmt) + MAX_FORMAT_SLOTS * 4 (exists bools)
    //   + 4 (size for CPFORMAT_TEXT) + text.len
    //   + 4 (changed bool)
    const fixed_overhead = 4 + MAX_FORMAT_SLOTS * 4 + 4 + 4;
    const total = fixed_overhead + text.len;

    const buf = try allocator.alloc(u8, total);
    errdefer allocator.free(buf);

    var offset: usize = 0;

    // maxFmt
    writeU32(buf, &offset, MAX_FORMAT_SLOTS);

    // Format slots
    for (0..MAX_FORMAT_SLOTS) |i| {
        if (i == CPFORMAT_TEXT) {
            writeU32(buf, &offset, 1); // exists = true
            writeU32(buf, &offset, @intCast(text.len));
            @memcpy(buf[offset..][0..text.len], text);
            offset += text.len;
        } else {
            writeU32(buf, &offset, 0); // exists = false
        }
    }

    // changed = true
    writeU32(buf, &offset, 1);

    std.debug.assert(offset == total);
    return buf;
}

/// Deserialize a CPClipboard payload, extracting the text format.
///
/// Returns the text bytes (without copying) as a slice into `data`.
/// The caller does not own the returned slice.
pub fn deserializeClipboard(data: []const u8) Error![]const u8 {
    const limits: platform.Limits = .{};
    var offset: usize = 0;

    const max_fmt = readU32(data, &offset) orelse return error.InvalidPayload;
    if (max_fmt > MAX_FORMAT_SLOTS) return error.FormatIndexOutOfRange;

    for (0..max_fmt) |i| {
        const exists = readU32(data, &offset) orelse return error.InvalidPayload;
        if (exists != 0) {
            const size = readU32(data, &offset) orelse return error.InvalidPayload;
            if (size > limits.max_clipboard_bytes) return error.PayloadTooLarge;
            if (offset + size > data.len) return error.InvalidPayload;
            if (i == CPFORMAT_TEXT) {
                return data[offset..][0..size];
            }
            offset += size;
        }
    }

    return error.InvalidPayload;
}

/// Build a capability negotiation RPCI command string.
pub fn formatCapabilityCommand(
    allocator: Allocator,
    mask: u32,
) Allocator.Error![]u8 {
    return std.fmt.allocPrint(allocator, "tools.capability.dnd_version 4\x00tools.capability.copypaste_version 4\x00vmx.capability.unified_clipboard {d}", .{mask});
}

/// Build the full RPCI payload for a clipboard transport message.
///
/// Returns "copypaste.transport " ++ header_bytes ++ payload.
pub fn buildTransportMessage(
    allocator: Allocator,
    header: *const HeaderV4,
    payload: []const u8,
) Allocator.Error![]u8 {
    const prefix = RPCI_TRANSPORT_PREFIX;
    const hdr_bytes = header.encode();
    const total = prefix.len + HEADER_SIZE + payload.len;

    const buf = try allocator.alloc(u8, total);
    @memcpy(buf[0..prefix.len], prefix);
    @memcpy(buf[prefix.len..][0..HEADER_SIZE], &hdr_bytes);
    @memcpy(buf[prefix.len + HEADER_SIZE ..], payload);
    return buf;
}

// ---------------------------------------------------------------------------
// Private helpers
// ---------------------------------------------------------------------------

fn writeU32(buf: []u8, offset: *usize, value: u32) void {
    std.mem.writeInt(u32, buf[offset.*..][0..4], value, .little);
    offset.* += 4;
}

fn readU32(buf: []const u8, offset: *usize) ?u32 {
    if (offset.* + 4 > buf.len) return null;
    const val = std.mem.readInt(u32, buf[offset.*..][0..4], .little);
    offset.* += 4;
    return val;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "HeaderV4 encode/decode round-trip" {
    const original: HeaderV4 = .{
        .cmd = CMD_SEND_CLIPBOARD,
        .msg_type = MSG_TYPE_CP,
        .src = SRC_GUEST,
        .session_id = 0x42,
        .binary_size = 128,
        .payload_offset = HEADER_SIZE,
        .payload_size = 128,
    };

    const encoded = original.encode();
    try std.testing.expectEqual(@as(usize, HEADER_SIZE), encoded.len);

    const decoded = HeaderV4.decode(&encoded);
    try std.testing.expectEqual(original.cmd, decoded.cmd);
    try std.testing.expectEqual(original.msg_type, decoded.msg_type);
    try std.testing.expectEqual(original.src, decoded.src);
    try std.testing.expectEqual(original.session_id, decoded.session_id);
    try std.testing.expectEqual(original.binary_size, decoded.binary_size);
    try std.testing.expectEqual(original.payload_offset, decoded.payload_offset);
    try std.testing.expectEqual(original.payload_size, decoded.payload_size);
}

test "HeaderV4 encode produces correct byte order" {
    const hdr: HeaderV4 = .{ .cmd = CMD_PING };
    const buf = hdr.encode();
    // First 4 bytes = cmd = 1 in little-endian
    const cmd = std.mem.readInt(u32, buf[0..4], .little);
    try std.testing.expectEqual(CMD_PING, cmd);
}

test "serializeClipboard round-trip" {
    const text = "hello\x00";
    const serialized = try serializeClipboard(std.testing.allocator, text);
    defer std.testing.allocator.free(serialized);

    const recovered = try deserializeClipboard(serialized);
    try std.testing.expectEqualSlices(u8, text, recovered);
}

test "deserializeClipboard rejects truncated input" {
    // Only 2 bytes — not enough for the maxFmt u32
    const bad: []const u8 = &.{ 0x0B, 0x00 };
    try std.testing.expectError(error.InvalidPayload, deserializeClipboard(bad));
}

test "deserializeClipboard rejects oversized format" {
    // maxFmt = 12 (> MAX_FORMAT_SLOTS)
    var buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &buf, 12, .little);
    try std.testing.expectError(error.FormatIndexOutOfRange, deserializeClipboard(&buf));
}

test "capability mask constants" {
    // text clipboard mask must include VALID, CP, and PLAIN_TEXT_CP
    try std.testing.expect(CAP_TEXT_CLIPBOARD & CAP_VALID != 0);
    try std.testing.expect(CAP_TEXT_CLIPBOARD & CAP_CP != 0);
    try std.testing.expect(CAP_TEXT_CLIPBOARD & CAP_PLAIN_TEXT_CP != 0);
    // must not include DND
    try std.testing.expect(CAP_TEXT_CLIPBOARD & CAP_DND == 0);
}

test "buildTransportMessage structure" {
    const hdr: HeaderV4 = .{ .cmd = CMD_RECV_CLIPBOARD, .src = SRC_HOST };
    const payload = "test";
    const msg = try buildTransportMessage(std.testing.allocator, &hdr, payload);
    defer std.testing.allocator.free(msg);

    const prefix = RPCI_TRANSPORT_PREFIX;
    try std.testing.expectEqualSlices(u8, prefix, msg[0..prefix.len]);
    try std.testing.expectEqual(prefix.len + HEADER_SIZE + payload.len, msg.len);

    // Verify the header is embedded correctly
    const decoded = HeaderV4.decode(msg[prefix.len..][0..HEADER_SIZE]);
    try std.testing.expectEqual(CMD_RECV_CLIPBOARD, decoded.cmd);
    try std.testing.expectEqual(SRC_HOST, decoded.src);

    // Verify the payload follows the header
    try std.testing.expectEqualSlices(u8, payload, msg[prefix.len + HEADER_SIZE ..]);
}
