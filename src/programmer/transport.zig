// SPDX-License-Identifier: Apache-2.0

const std = @import("std");

pub const Error = error{
    Io,
};

pub const Transport = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        send: *const fn (context: *anyopaque, bytes: []const u8) Error!usize,
        recv: *const fn (context: *anyopaque, out: []u8) Error!usize,
        write_payload: *const fn (context: *anyopaque, bytes: []const u8, limit: usize) Error!usize,
        read_payload: *const fn (context: *anyopaque, out: []u8, limit: usize) Error!usize,
        close: *const fn (context: *anyopaque) void,
    };

    pub fn send(self: Transport, bytes: []const u8) Error!void {
        if (try self.vtable.send(self.context, bytes) != bytes.len) return Error.Io;
    }

    pub fn recv(self: Transport, out: []u8) Error!usize {
        return self.vtable.recv(self.context, out);
    }

    pub fn writePayload(self: Transport, bytes: []const u8, limit: usize) Error!void {
        if (try self.vtable.write_payload(self.context, bytes, limit) != bytes.len) return Error.Io;
    }

    pub fn readPayload(self: Transport, out: []u8, limit: usize) Error!void {
        if (try self.vtable.read_payload(self.context, out, limit) != out.len) return Error.Io;
    }

    pub fn close(self: Transport) void {
        self.vtable.close(self.context);
    }

    /// Preserve the primary operation error, but quarantine a transport whose
    /// protocol cleanup could not be completed.
    pub fn quarantineOnCleanupFailure(self: Transport, result: anyerror!void) void {
        result catch self.close();
    }
};

pub const FakeTransport = struct {
    sent: std.ArrayListUnmanaged(u8) = .empty,
    payload_sent: std.ArrayListUnmanaged(u8) = .empty,
    response: []const u8,
    payload_response: []const u8 = &.{},
    allocator: std.mem.Allocator,
    send_calls: usize = 0,
    write_payload_calls: usize = 0,
    read_payload_calls: usize = 0,
    short_send_call: ?usize = null,
    short_write_payload_call: ?usize = null,
    short_read_payload_call: ?usize = null,
    close_count: usize = 0,

    pub fn init(allocator: std.mem.Allocator, response: []const u8) FakeTransport {
        return .{ .allocator = allocator, .response = response };
    }

    pub fn deinit(self: *FakeTransport) void {
        self.sent.deinit(self.allocator);
        self.payload_sent.deinit(self.allocator);
    }

    pub fn transport(self: *FakeTransport) Transport {
        return .{ .context = self, .vtable = &vtable };
    }

    const vtable = Transport.VTable{ .send = send, .recv = recv, .write_payload = writePayload, .read_payload = readPayload, .close = close };

    fn send(context: *anyopaque, bytes: []const u8) Error!usize {
        const self: *FakeTransport = @ptrCast(@alignCast(context));
        self.send_calls += 1;
        const len = if (self.short_send_call == self.send_calls and bytes.len != 0) bytes.len - 1 else bytes.len;
        self.sent.appendSlice(self.allocator, bytes[0..len]) catch return Error.Io;
        return len;
    }

    fn recv(context: *anyopaque, out: []u8) Error!usize {
        const self: *FakeTransport = @ptrCast(@alignCast(context));
        const len = @min(self.response.len, out.len);
        @memcpy(out[0..len], self.response[0..len]);
        return len;
    }

    fn writePayload(context: *anyopaque, bytes: []const u8, limit: usize) Error!usize {
        _ = limit;
        const self: *FakeTransport = @ptrCast(@alignCast(context));
        self.write_payload_calls += 1;
        const len = if (self.short_write_payload_call == self.write_payload_calls and bytes.len != 0) bytes.len - 1 else bytes.len;
        self.payload_sent.appendSlice(self.allocator, bytes[0..len]) catch return Error.Io;
        return len;
    }

    fn readPayload(context: *anyopaque, out: []u8, limit: usize) Error!usize {
        _ = limit;
        const self: *FakeTransport = @ptrCast(@alignCast(context));
        self.read_payload_calls += 1;
        var len = @min(self.payload_response.len, out.len);
        if (self.short_read_payload_call == self.read_payload_calls and len == out.len and len != 0) len -= 1;
        @memcpy(out[0..len], self.payload_response[0..len]);
        return len;
    }

    fn close(context: *anyopaque) void {
        const self: *FakeTransport = @ptrCast(@alignCast(context));
        self.close_count += 1;
    }
};

test "transport rejects short command and payload transfers" {
    var fake = FakeTransport.init(std.testing.allocator, &.{});
    defer fake.deinit();

    fake.short_send_call = 1;
    try std.testing.expectError(Error.Io, fake.transport().send(&.{ 1, 2 }));

    fake.short_write_payload_call = 1;
    try std.testing.expectError(Error.Io, fake.transport().writePayload(&.{ 1, 2 }, 0));

    fake.payload_response = &.{ 1, 2 };
    fake.short_read_payload_call = 1;
    var out: [2]u8 = undefined;
    try std.testing.expectError(Error.Io, fake.transport().readPayload(&out, 0));
}

test "cleanup failure quarantines transport" {
    var fake = FakeTransport.init(std.testing.allocator, &.{});
    defer fake.deinit();

    fake.transport().quarantineOnCleanupFailure(Error.Io);
    try std.testing.expectEqual(@as(usize, 1), fake.close_count);
}
