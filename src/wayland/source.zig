//! Wayland clipboard publish path.
//!
//! Pure-logic helpers for publishing clipboard data to a Wayland
//! compositor via wl_data_source.  The actual data source lifecycle
//! (create, offer MIME types, set_selection) requires a live compositor
//! connection and lives in the bridge layer.

const std = @import("std");

const fd_t = std.posix.fd_t;

// ---------------------------------------------------------------------------
// Errors
// ---------------------------------------------------------------------------

pub const Error = error{
    WriteFailed,
};

// ---------------------------------------------------------------------------
// Pipe writing
// ---------------------------------------------------------------------------

/// Write all of `data` to the file descriptor, retrying on partial writes.
///
/// Used to fulfil wl_data_source.send requests: the compositor opens a
/// pipe, and we write the clipboard payload into the write end.
pub fn writeSendData(fd: fd_t, data: []const u8) Error!void {
    var offset: usize = 0;
    while (offset < data.len) {
        const remaining = data[offset..];
        const ret = std.c.write(fd, remaining.ptr, remaining.len);
        if (ret <= 0) return error.WriteFailed;
        offset += @intCast(ret);
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "writeSendData writes full payload" {
    var fds: [2]fd_t = undefined;
    if (std.c.pipe(&fds) != 0) return error.WriteFailed;
    defer _ = std.c.close(fds[0]);

    const data = "hello from vmware host";
    try writeSendData(fds[1], data);
    _ = std.c.close(fds[1]);

    var buf: [64]u8 = undefined;
    const n = std.posix.read(fds[0], &buf) catch return error.WriteFailed;
    try std.testing.expectEqualStrings(data, buf[0..n]);
}

test "writeSendData handles empty data" {
    var fds: [2]fd_t = undefined;
    if (std.c.pipe(&fds) != 0) return error.WriteFailed;
    defer _ = std.c.close(fds[0]);

    try writeSendData(fds[1], "");
    _ = std.c.close(fds[1]);

    var buf: [1]u8 = undefined;
    const n = std.posix.read(fds[0], &buf) catch return error.WriteFailed;
    try std.testing.expectEqual(@as(usize, 0), n);
}

test "writeSendData detects closed pipe" {
    var fds: [2]fd_t = undefined;
    if (std.c.pipe(&fds) != 0) return error.WriteFailed;
    _ = std.c.close(fds[0]); // close read end first

    const result = writeSendData(fds[1], "data");
    _ = std.c.close(fds[1]);
    try std.testing.expectError(error.WriteFailed, result);
}
