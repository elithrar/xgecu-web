// SPDX-License-Identifier: GPL-3.0-or-later

const std = @import("std");
const transport_mod = @import("transport.zig");

const c = @cImport({
    @cInclude("libusb.h");
});

const mp_tl866_vid = 0x04d8;
const mp_tl866_pid = 0xe11c;
const mp_tl866ii_vid = 0xa466;
const mp_tl866ii_pid = 0x0a53;
const mp_t76_vid = 0xa466;
const mp_t76_pid = 0x1a86;
const usb_timeout_ms = 5000;
const usb_read_timeout_ms = 360000;

pub const Error = error{
    LibusbInit,
    NotFound,
    ClaimInterface,
    Transfer,
    ShortWrite,
    OutOfMemory,
};

pub const UsbTransport = struct {
    allocator: std.mem.Allocator,
    handle: *c.libusb_device_handle,
    vid: u16,
    pid: u16,

    pub fn open(allocator: std.mem.Allocator) Error!*UsbTransport {
        if (c.libusb_init(null) < 0) return Error.LibusbInit;
        errdefer c.libusb_exit(null);

        const ids = [_]struct { vid: u16, pid: u16 }{
            .{ .vid = mp_tl866_vid, .pid = mp_tl866_pid },
            .{ .vid = mp_tl866ii_vid, .pid = mp_tl866ii_pid },
            .{ .vid = mp_t76_vid, .pid = mp_t76_pid },
        };

        for (ids) |id| {
            if (c.libusb_open_device_with_vid_pid(null, id.vid, id.pid)) |handle| {
                errdefer c.libusb_close(handle);
                if (c.libusb_claim_interface(handle, 0) != 0) return Error.ClaimInterface;
                const self = allocator.create(UsbTransport) catch return Error.OutOfMemory;
                self.* = .{ .allocator = allocator, .handle = handle, .vid = id.vid, .pid = id.pid };
                return self;
            }
        }
        return Error.NotFound;
    }

    pub fn transport(self: *UsbTransport) transport_mod.Transport {
        return .{ .context = self, .vtable = &vtable };
    }

    const vtable = transport_mod.Transport.VTable{ .send = send, .recv = recv, .write_payload = writePayload, .read_payload = readPayload, .close = close };

    fn send(context: *anyopaque, bytes: []const u8) transport_mod.Error!void {
        const self: *UsbTransport = @ptrCast(@alignCast(context));
        var transferred: c_int = 0;
        const rc = c.libusb_bulk_transfer(self.handle, c.LIBUSB_ENDPOINT_OUT | 0x01, @constCast(bytes.ptr), @intCast(bytes.len), &transferred, usb_timeout_ms);
        if (rc != c.LIBUSB_SUCCESS) return transport_mod.Error.Io;
        if (transferred != bytes.len) return transport_mod.Error.Io;
    }

    fn recv(context: *anyopaque, out: []u8) transport_mod.Error!usize {
        const self: *UsbTransport = @ptrCast(@alignCast(context));
        var transferred: c_int = 0;
        const rc = c.libusb_bulk_transfer(self.handle, c.LIBUSB_ENDPOINT_IN | 0x01, out.ptr, @intCast(out.len), &transferred, usb_read_timeout_ms);
        if (rc != c.LIBUSB_SUCCESS) return transport_mod.Error.Io;
        return @intCast(transferred);
    }

    fn writePayload(context: *anyopaque, bytes: []const u8, limit: usize) transport_mod.Error!void {
        const self: *UsbTransport = @ptrCast(@alignCast(context));
        if (self.pid == mp_t76_pid) {
            try bulkTransferExact(self.handle, c.LIBUSB_ENDPOINT_OUT | 0x05, @constCast(bytes.ptr), bytes.len, usb_timeout_ms);
            return;
        }
        if (limit == 0 or bytes.len <= limit) {
            try bulkTransferExact(self.handle, c.LIBUSB_ENDPOINT_OUT | 0x02, @constCast(bytes.ptr), bytes.len, usb_timeout_ms);
            return;
        }
        // Larger non-T76 payloads are split across EP2/EP3 by Xgpro/minipro.
        const split = payloadSplit(bytes.len);
        try bulkTransferExact(self.handle, c.LIBUSB_ENDPOINT_OUT | 0x02, @constCast(bytes.ptr), split.ep2, usb_timeout_ms);
        try bulkTransferExact(self.handle, c.LIBUSB_ENDPOINT_OUT | 0x03, @constCast(bytes.ptr + split.ep2), split.ep3, usb_timeout_ms);
    }

    fn readPayload(context: *anyopaque, out: []u8, limit: usize) transport_mod.Error!void {
        const self: *UsbTransport = @ptrCast(@alignCast(context));
        if (self.pid == mp_t76_pid) {
            try bulkTransferExact(self.handle, c.LIBUSB_ENDPOINT_IN | 0x02, out.ptr, out.len, usb_timeout_ms);
            return;
        }
        if (out.len < 64) {
            var data = [_]u8{0} ** 64;
            try bulkTransferExact(self.handle, c.LIBUSB_ENDPOINT_IN | 0x02, &data, data.len, usb_timeout_ms);
            @memcpy(out, data[0..out.len]);
            return;
        }
        if (out.len == 64 or limit == 0 or out.len < limit) {
            try bulkTransferExact(self.handle, c.LIBUSB_ENDPOINT_IN | 0x02, out.ptr, out.len, usb_timeout_ms);
            return;
        }

        const allocator = self.allocator;
        const data = allocator.alloc(u8, out.len) catch return transport_mod.Error.Io;
        defer allocator.free(data);
        try payloadTransfer(self.handle, c.LIBUSB_ENDPOINT_IN, data[0 .. out.len / 2], data[out.len / 2 ..]);

        const blocks = out.len / 64;
        for (0..blocks) |i| {
            const source = if (i % 2 == 0) data[0 .. out.len / 2] else data[out.len / 2 ..];
            @memcpy(out[i * 64 ..][0..64], source[(i / 2) * 64 ..][0..64]);
        }
    }

    fn close(context: *anyopaque) void {
        const self: *UsbTransport = @ptrCast(@alignCast(context));
        _ = c.libusb_release_interface(self.handle, 0);
        c.libusb_close(self.handle);
        c.libusb_exit(null);
        const allocator = self.allocator;
        allocator.destroy(self);
    }
};

fn payloadTransfer(handle: *c.libusb_device_handle, direction: u8, ep2_buffer: []u8, ep3_buffer: []u8) transport_mod.Error!void {
    const ep2 = c.libusb_alloc_transfer(0) orelse return transport_mod.Error.Io;
    defer c.libusb_free_transfer(ep2);
    const ep3 = c.libusb_alloc_transfer(0) orelse return transport_mod.Error.Io;
    defer c.libusb_free_transfer(ep3);

    var ep2_completed: c_int = 0;
    var ep3_completed: c_int = 0;
    c.libusb_fill_bulk_transfer(ep2, handle, direction | 0x02, ep2_buffer.ptr, @intCast(ep2_buffer.len), payloadTransferCallback, &ep2_completed, usb_timeout_ms);
    c.libusb_fill_bulk_transfer(ep3, handle, direction | 0x03, ep3_buffer.ptr, @intCast(ep3_buffer.len), payloadTransferCallback, &ep3_completed, usb_timeout_ms);

    if (c.libusb_submit_transfer(ep2) < 0) return transport_mod.Error.Io;
    if (c.libusb_submit_transfer(ep3) < 0) {
        _ = c.libusb_cancel_transfer(ep2);
        return transport_mod.Error.Io;
    }

    while (ep2_completed == 0) {
        const rc = c.libusb_handle_events_completed(null, &ep2_completed);
        if (rc < 0 and rc != c.LIBUSB_ERROR_INTERRUPTED) {
            _ = c.libusb_cancel_transfer(ep2);
            _ = c.libusb_cancel_transfer(ep3);
            return transport_mod.Error.Io;
        }
    }
    while (ep3_completed == 0) {
        const rc = c.libusb_handle_events_completed(null, &ep3_completed);
        if (rc < 0 and rc != c.LIBUSB_ERROR_INTERRUPTED) {
            _ = c.libusb_cancel_transfer(ep2);
            _ = c.libusb_cancel_transfer(ep3);
            return transport_mod.Error.Io;
        }
    }

    if (ep2.*.status != c.LIBUSB_TRANSFER_COMPLETED or ep3.*.status != c.LIBUSB_TRANSFER_COMPLETED) return transport_mod.Error.Io;
}

fn payloadTransferCallback(transfer: ?*c.libusb_transfer) callconv(.c) void {
    if (transfer) |value| {
        if (value.*.user_data) |user_data| {
            const completed: *c_int = @ptrCast(@alignCast(user_data));
            completed.* = 1;
        }
    }
}

fn bulkTransferExact(handle: *c.libusb_device_handle, endpoint: u8, data: [*]u8, len: usize, timeout_ms: u32) transport_mod.Error!void {
    var transferred: c_int = 0;
    const rc = c.libusb_bulk_transfer(handle, endpoint, data, @intCast(len), &transferred, timeout_ms);
    if (rc != c.LIBUSB_SUCCESS) return transport_mod.Error.Io;
    if (transferred != len) return transport_mod.Error.Io;
}

fn payloadSplit(len: usize) struct { ep2: usize, ep3: usize } {
    const remainder = len % 128;
    if (remainder == 0) return .{ .ep2 = len / 2, .ep3 = len / 2 };
    const base = (len - remainder) / 2;
    if (remainder > 64) return .{ .ep2 = base + 64, .ep3 = remainder + base - 64 };
    return .{ .ep2 = base, .ep3 = remainder + base };
}

test "payload split matches upstream endpoint sizing" {
    try std.testing.expectEqualDeep(.{ .ep2 = 64, .ep3 = 64 }, payloadSplit(128));
    try std.testing.expectEqualDeep(.{ .ep2 = 64, .ep3 = 80 }, payloadSplit(144));
    try std.testing.expectEqualDeep(.{ .ep2 = 192, .ep3 = 128 }, payloadSplit(320));
}
