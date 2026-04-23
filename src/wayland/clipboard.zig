//! Wayland clipboard receive path.
//!
//! Pure-logic helpers for receiving clipboard data from a Wayland
//! compositor.  Handles MIME type preference ranking and pipe-fd
//! reading with bounded allocation.  The actual wl_data_device
//! listener wiring lives in the bridge layer where a real compositor
//! connection is available.

const std = @import("std");
const platform = @import("../platform.zig");

const Allocator = std.mem.Allocator;
const fd_t = std.posix.fd_t;

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

/// MIME types accepted for clipboard text, in decreasing preference.
pub const MIME_PREFERENCE = [_][]const u8{
    "text/plain;charset=utf-8",
    "text/plain",
    "UTF8_STRING",
    "STRING",
};

// ---------------------------------------------------------------------------
// Errors
// ---------------------------------------------------------------------------

pub const Error = error{
    PayloadTooLarge,
    ReadFailed,
};

// ---------------------------------------------------------------------------
// MIME preference
// ---------------------------------------------------------------------------

/// Return the best MIME type from `offered` according to our preference
/// order, or null if none match.
pub fn preferredMime(offered: []const []const u8) ?[]const u8 {
    for (&MIME_PREFERENCE) |want| {
        for (offered) |have| {
            if (std.mem.eql(u8, want, have)) return want;
        }
    }
    return null;
}

// ---------------------------------------------------------------------------
// Pipe reading
// ---------------------------------------------------------------------------

/// Read a pipe fd to completion, allocating up to `max_bytes`.
///
/// Returns the data read.  Caller owns the returned slice.
/// Returns `error.PayloadTooLarge` if the pipe delivers more than
/// `max_bytes` before EOF.  Returns `error.ReadFailed` on I/O errors.
pub fn readFdAlloc(
    allocator: Allocator,
    fd: fd_t,
    max_bytes: usize,
) (Allocator.Error || Error)![]u8 {
    std.debug.assert(max_bytes > 0);

    const initial_capacity: usize = 4096;
    const cap = @min(initial_capacity, max_bytes);
    var buf = try allocator.alloc(u8, cap);
    var len: usize = 0;
    var ok = false;
    defer if (!ok) allocator.free(buf);

    while (true) {
        if (len == buf.len) {
            if (buf.len >= max_bytes) {
                // Probe for more data beyond the limit.
                var probe: [1]u8 = undefined;
                const p = std.posix.read(fd, &probe) catch
                    return error.ReadFailed;
                if (p > 0) return error.PayloadTooLarge;
                break;
            }
            buf = allocator.realloc(buf, @min(buf.len *| 2, max_bytes)) catch
                return error.ReadFailed;
        }

        const n = std.posix.read(fd, buf[len..]) catch
            return error.ReadFailed;
        if (n == 0) break;
        len += n;
    }

    // Shrink to exact size
    if (len < buf.len) {
        buf = allocator.realloc(buf, len) catch {
            ok = true;
            return buf[0..len];
        };
    }
    ok = true;
    return buf[0..len];
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "preferredMime selects best match" {
    const offered = [_][]const u8{ "text/html", "text/plain", "text/plain;charset=utf-8" };
    const result = preferredMime(&offered);
    try std.testing.expectEqualStrings("text/plain;charset=utf-8", result.?);
}

test "preferredMime falls back to lower priority" {
    const offered = [_][]const u8{ "image/png", "STRING" };
    const result = preferredMime(&offered);
    try std.testing.expectEqualStrings("STRING", result.?);
}

test "preferredMime returns null when nothing matches" {
    const offered = [_][]const u8{ "image/png", "application/json" };
    const result = preferredMime(&offered);
    try std.testing.expect(result == null);
}

test "preferredMime empty offered list returns null" {
    const offered = [_][]const u8{};
    const result = preferredMime(&offered);
    try std.testing.expect(result == null);
}

test "readFdAlloc reads pipe to completion" {
    var fds: [2]fd_t = undefined;
    if (std.c.pipe(&fds) != 0) return error.ReadFailed;
    defer _ = std.c.close(fds[0]);

    const data = "clipboard text";
    _ = std.c.write(fds[1], data.ptr, data.len);
    _ = std.c.close(fds[1]);

    const result = try readFdAlloc(std.testing.allocator, fds[0], 4096);
    defer std.testing.allocator.free(result);

    try std.testing.expectEqualStrings(data, result);
}

test "readFdAlloc rejects oversized payload" {
    var fds: [2]fd_t = undefined;
    if (std.c.pipe(&fds) != 0) return error.ReadFailed;
    defer _ = std.c.close(fds[0]);

    const data = "this is too long";
    _ = std.c.write(fds[1], data.ptr, data.len);
    _ = std.c.close(fds[1]);

    const result = readFdAlloc(std.testing.allocator, fds[0], 4);
    try std.testing.expectError(error.PayloadTooLarge, result);
}

test "readFdAlloc handles empty pipe" {
    var fds: [2]fd_t = undefined;
    if (std.c.pipe(&fds) != 0) return error.ReadFailed;
    defer _ = std.c.close(fds[0]);
    _ = std.c.close(fds[1]);

    const result = try readFdAlloc(std.testing.allocator, fds[0], 4096);
    defer std.testing.allocator.free(result);

    try std.testing.expectEqual(@as(usize, 0), result.len);
}
