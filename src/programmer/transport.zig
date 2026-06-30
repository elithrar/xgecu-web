// SPDX-License-Identifier: GPL-3.0-or-later

const std = @import("std");

pub const Error = error{
    Io,
};

pub const Transport = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        send: *const fn (context: *anyopaque, bytes: []const u8) Error!void,
        recv: *const fn (context: *anyopaque, out: []u8) Error!usize,
        write_payload: *const fn (context: *anyopaque, bytes: []const u8, limit: usize) Error!void,
        read_payload: *const fn (context: *anyopaque, out: []u8, limit: usize) Error!void,
        close: *const fn (context: *anyopaque) void,
    };

    pub fn send(self: Transport, bytes: []const u8) Error!void {
        return self.vtable.send(self.context, bytes);
    }

    pub fn recv(self: Transport, out: []u8) Error!usize {
        return self.vtable.recv(self.context, out);
    }

    pub fn writePayload(self: Transport, bytes: []const u8, limit: usize) Error!void {
        return self.vtable.write_payload(self.context, bytes, limit);
    }

    pub fn readPayload(self: Transport, out: []u8, limit: usize) Error!void {
        return self.vtable.read_payload(self.context, out, limit);
    }

    pub fn close(self: Transport) void {
        self.vtable.close(self.context);
    }
};

pub const FakeTransport = struct {
    sent: std.ArrayListUnmanaged(u8) = .empty,
    payload_sent: std.ArrayListUnmanaged(u8) = .empty,
    response: []const u8,
    payload_response: []const u8 = &.{},
    allocator: std.mem.Allocator,

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

    fn send(context: *anyopaque, bytes: []const u8) Error!void {
        const self: *FakeTransport = @ptrCast(@alignCast(context));
        self.sent.appendSlice(self.allocator, bytes) catch return Error.Io;
    }

    fn recv(context: *anyopaque, out: []u8) Error!usize {
        const self: *FakeTransport = @ptrCast(@alignCast(context));
        const len = @min(self.response.len, out.len);
        @memcpy(out[0..len], self.response[0..len]);
        return len;
    }

    fn writePayload(context: *anyopaque, bytes: []const u8, limit: usize) Error!void {
        _ = limit;
        const self: *FakeTransport = @ptrCast(@alignCast(context));
        self.payload_sent.appendSlice(self.allocator, bytes) catch return Error.Io;
    }

    fn readPayload(context: *anyopaque, out: []u8, limit: usize) Error!void {
        _ = limit;
        const self: *FakeTransport = @ptrCast(@alignCast(context));
        if (self.payload_response.len < out.len) return Error.Io;
        @memcpy(out, self.payload_response[0..out.len]);
    }

    fn close(context: *anyopaque) void {
        _ = context;
    }
};
