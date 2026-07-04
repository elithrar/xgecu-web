// SPDX-License-Identifier: GPL-3.0-or-later

const std = @import("std");
const builtin = @import("builtin");
const catalog = @import("../catalog/catalog.zig");
const endian = @import("../core/endian.zig");
const model = @import("../core/model.zig");
const session = @import("../programmer/session.zig");
const t48 = @import("../programmer/t48.zig");

const TransferKind = enum(u32) {
    done = 0,
    out = 1,
    in = 2,
    failed = 3,
};

const t56_read_payload_max = 64;

const OpKind = enum {
    read,
    write,
};

const State = enum {
    send_info,
    recv_info,
    send_t56_bitstream_header,
    send_t56_bitstream_payload,
    send_begin,
    send_begin_status,
    recv_begin_status,
    send_chip_id,
    recv_chip_id,
    send_erase,
    recv_erase,
    send_end_after_erase,
    send_second_t56_bitstream_header,
    send_second_t56_bitstream_payload,
    send_second_begin,
    send_second_status,
    recv_second_status,
    send_write_cmd,
    send_write_payload,
    send_write_status,
    recv_write_status,
    send_read_cmd,
    recv_read_payload,
    verify_send_read_cmd,
    verify_recv_read_payload,
    done,
    failed,
};

const Transfer = struct {
    kind: TransferKind = .done,
    endpoint: u8 = 0,
    ptr: u32 = 0,
    len: u32 = 0,
};

const Operation = struct {
    kind: OpKind,
    requested_programmer: model.Programmer,
    programmer: model.Programmer = .auto,
    device: catalog.DeviceRecord,
    descriptor: t48.Device,
    memory: model.MemoryKind,
    state: State = .send_info,
    awaiting: bool = false,
    skip_id_check: bool = false,
    erase: bool = true,
    verify: bool = false,
    data: []u8 = &.{},
    verify_data: []u8 = &.{},
    payload: []u8 = &.{},
    offset: usize = 0,
    command: [512]u8 = [_]u8{0} ** 512,
    transfer: Transfer = .{},
    error_code: u32 = 0,

    fn deinit(self: *Operation, alloc: std.mem.Allocator) void {
        if (self.data.len != 0) alloc.free(self.data);
        if (self.verify_data.len != 0) alloc.free(self.verify_data);
        if (self.payload.len != 0) alloc.free(self.payload);
        alloc.destroy(self);
    }
};

var last_result: []u8 = &.{};
var last_error: []u8 = &.{};

fn allocator() std.mem.Allocator {
    if (builtin.target.cpu.arch == .wasm32) return std.heap.wasm_allocator;
    return std.heap.page_allocator;
}

export fn mp_alloc(len: u32) u32 {
    if (len == 0) return 0;
    const bytes = allocator().alloc(u8, len) catch return 0;
    return @intCast(@intFromPtr(bytes.ptr));
}

export fn mp_free(ptr: u32, len: u32) void {
    if (ptr == 0 or len == 0) return;
    const bytes: [*]u8 = @ptrFromInt(ptr);
    allocator().free(bytes[0..len]);
}

export fn mp_result_ptr() u32 {
    return if (last_result.len == 0) 0 else @intCast(@intFromPtr(last_result.ptr));
}

export fn mp_result_len() u32 {
    return @intCast(last_result.len);
}

export fn mp_last_error_ptr() u32 {
    return if (last_error.len == 0) 0 else @intCast(@intFromPtr(last_error.ptr));
}

export fn mp_last_error_len() u32 {
    return @intCast(last_error.len);
}

export fn mp_device_list(query_ptr: u32, query_len: u32, programmer_value: u32, limit_value: u32) u32 {
    const query = sliceConst(query_ptr, query_len);
    const programmer = programmerFromAbi(programmer_value) catch return setError("invalid programmer");
    const limit: usize = if (limit_value == 0) 100 else limit_value;
    const summaries = catalog.list(allocator(), if (query.len == 0) null else query, programmer, limit) catch return setError("device list failed");
    defer allocator().free(summaries);

    var out: std.Io.Writer.Allocating = .init(allocator());
    defer out.deinit();
    out.writer.writeAll("[") catch return setError("out of memory");
    for (summaries, 0..) |summary, index| {
        if (index != 0) out.writer.writeAll(",") catch return setError("out of memory");
        out.writer.writeAll("{\"name\":") catch return setError("out of memory");
        writeJsonString(&out.writer, summary.name) catch return setError("out of memory");
        out.writer.print(
            ",\"codeMemorySize\":{d},\"dataMemorySize\":{d},\"packagePins\":{d},\"supportsT48\":{},\"supportsT56\":{}}}",
            .{ summary.code_memory_size, summary.data_memory_size, summary.package_pins, summary.supports_t48, summary.supports_t56 },
        ) catch return setError("out of memory");
    }
    out.writer.writeAll("]") catch return setError("out of memory");
    return setResult(out.toOwnedSlice() catch return setError("out of memory"));
}

export fn mp_start_read_rom(programmer_value: u32, device_ptr: u32, device_len: u32, memory_value: u32, skip_id_check: u32) u32 {
    const programmer = programmerFromAbi(programmer_value) catch return failStart("invalid programmer");
    const memory = memoryFromAbi(memory_value) catch return failStart("invalid memory kind");
    const device_name = sliceConst(device_ptr, device_len);
    const device = catalog.find(device_name, programmer) catch return failStart("device not found or unsupported by requested programmer");
    const op = allocator().create(Operation) catch return failStart("out of memory");
    op.* = .{
        .kind = .read,
        .requested_programmer = programmer,
        .device = device,
        .descriptor = device.descriptor(.t48),
        .memory = memory,
        .skip_id_check = skip_id_check != 0,
    };
    return @intCast(@intFromPtr(op));
}

export fn mp_start_write_rom(programmer_value: u32, device_ptr: u32, device_len: u32, memory_value: u32, data_ptr: u32, data_len: u32, erase: u32, verify: u32, skip_id_check: u32) u32 {
    const programmer = programmerFromAbi(programmer_value) catch return failStart("invalid programmer");
    const memory = memoryFromAbi(memory_value) catch return failStart("invalid memory kind");
    const device_name = sliceConst(device_ptr, device_len);
    const device = catalog.find(device_name, programmer) catch return failStart("device not found or unsupported by requested programmer");
    const data = allocator().dupe(u8, sliceConst(data_ptr, data_len)) catch return failStart("out of memory");
    const op = allocator().create(Operation) catch {
        allocator().free(data);
        return failStart("out of memory");
    };
    op.* = .{
        .kind = .write,
        .requested_programmer = programmer,
        .device = device,
        .descriptor = device.descriptor(.t48),
        .memory = memory,
        .data = data,
        .erase = erase != 0,
        .verify = verify != 0,
        .skip_id_check = skip_id_check != 0,
    };
    return @intCast(@intFromPtr(op));
}

export fn mp_operation_destroy(handle: u32) void {
    if (handle == 0) return;
    operationFromHandle(handle).deinit(allocator());
}

export fn mp_operation_next(handle: u32) u32 {
    const op = operationFromHandle(handle);
    if (op.awaiting) return @intFromEnum(op.transfer.kind);
    op.transfer = nextTransfer(op) catch |err| {
        op.state = .failed;
        op.error_code = errorCode(err);
        _ = setError(@errorName(err));
        return @intFromEnum(TransferKind.failed);
    };
    op.awaiting = op.transfer.kind == .out or op.transfer.kind == .in;
    return @intFromEnum(op.transfer.kind);
}

export fn mp_transfer_endpoint(handle: u32) u32 {
    return operationFromHandle(handle).transfer.endpoint;
}

export fn mp_transfer_ptr(handle: u32) u32 {
    return operationFromHandle(handle).transfer.ptr;
}

export fn mp_transfer_len(handle: u32) u32 {
    return operationFromHandle(handle).transfer.len;
}

export fn mp_operation_complete(handle: u32, status: u32, data_ptr: u32, data_len: u32) u32 {
    const op = operationFromHandle(handle);
    if (!op.awaiting) return setError("operation is not awaiting a transfer");
    op.awaiting = false;
    if (status != 0) {
        op.state = .failed;
        return setError("webusb transfer failed");
    }
    completeTransfer(op, sliceConst(data_ptr, data_len)) catch |err| {
        op.state = .failed;
        op.error_code = errorCode(err);
        return setError(@errorName(err));
    };
    return 0;
}

export fn mp_operation_result(handle: u32) u32 {
    const op = operationFromHandle(handle);
    if (op.state != .done) return setError("operation is not complete");
    return switch (op.kind) {
        .read => setResult(allocator().dupe(u8, op.data) catch return setError("out of memory")),
        .write => setResult(allocator().dupe(u8, "null") catch return setError("out of memory")),
    };
}

fn nextTransfer(op: *Operation) !Transfer {
    switch (op.state) {
        .send_info => {
            @memset(op.command[0..5], 0);
            return outTransfer(op, 1, op.command[0..5]);
        },
        .recv_info => return inTransfer(1, 80),
        .send_t56_bitstream_header, .send_second_t56_bitstream_header => {
            @memset(op.command[0..8], 0);
            op.command[0] = 0x26;
            const bitstream = op.device.algorithmFor(.t56) orelse return error.AlgorithmUnavailable;
            if (bitstream.len == 0) return error.AlgorithmUnavailable;
            endian.storeInt(op.command[4..8], bitstream.len, .little);
            return outTransfer(op, 1, op.command[0..8]);
        },
        .send_t56_bitstream_payload, .send_second_t56_bitstream_payload => {
            const bitstream = op.device.algorithmFor(.t56) orelse return error.AlgorithmUnavailable;
            if (bitstream.len == 0) return error.AlgorithmUnavailable;
            return outTransfer(op, 1, bitstream);
        },
        .send_begin, .send_second_begin => {
            writeBeginPacket(op);
            return outTransfer(op, 1, op.command[0..64]);
        },
        .send_begin_status, .send_second_status, .send_write_status => {
            @memset(op.command[0..8], 0);
            op.command[0] = 0x39;
            return outTransfer(op, 1, op.command[0..8]);
        },
        .recv_begin_status, .recv_second_status, .recv_write_status => return inTransfer(1, 32),
        .send_chip_id => {
            @memset(op.command[0..8], 0);
            op.command[0] = 0x05;
            return outTransfer(op, 1, op.command[0..8]);
        },
        .recv_chip_id => return inTransfer(1, 32),
        .send_erase => {
            @memset(op.command[0..15], 0);
            op.command[0] = 0x0e;
            return outTransfer(op, 1, op.command[0..15]);
        },
        .recv_erase => return inTransfer(1, 64),
        .send_end_after_erase => {
            @memset(op.command[0..8], 0);
            op.command[0] = 0x04;
            return outTransfer(op, 1, op.command[0..8]);
        },
        .send_write_cmd => {
            const len = currentWriteLen(op);
            @memset(op.command[0..8], 0);
            op.command[0] = writeCommand(op.memory);
            endian.storeInt(op.command[2..4], len, .little);
            endian.storeInt(op.command[4..8], op.offset, .little);
            return outTransfer(op, 1, op.command[0..8]);
        },
        .send_write_payload => {
            const len = currentWriteLen(op);
            if (op.programmer == .t56) {
                const transfer_len = @max(@as(usize, op.descriptor.write_buffer_size), len);
                if (transfer_len > op.payload.len) return error.PayloadBufferTooSmall;
                @memset(op.payload[0..transfer_len], 0);
                @memcpy(op.payload[0..len], op.data[op.offset .. op.offset + len]);
                return outTransfer(op, 1, op.payload[0..transfer_len]);
            }
            return outTransfer(op, 2, op.data[op.offset .. op.offset + len]);
        },
        .send_read_cmd, .verify_send_read_cmd => {
            const len = currentReadLen(op);
            @memset(op.command[0..8], 0);
            op.command[0] = readCommand(op.memory);
            endian.storeInt(op.command[2..4], len, .little);
            endian.storeInt(op.command[4..8], op.offset, .little);
            return outTransfer(op, 1, op.command[0..8]);
        },
        .recv_read_payload, .verify_recv_read_payload => {
            const len = currentReadLen(op);
            if (op.programmer == .t56) return inTransfer(1, @intCast(len + 16));
            return inTransfer(2, @intCast(len));
        },
        .done => return .{ .kind = .done },
        .failed => return .{ .kind = .failed },
    }
}

fn completeTransfer(op: *Operation, data: []const u8) !void {
    switch (op.state) {
        .send_info => op.state = .recv_info,
        .recv_info => {
            const info = session.parseSystemInfo(data) orelse return error.UnsupportedProgrammer;
            if (info.programmer != .t48 and info.programmer != .t56) return error.UnsupportedProgrammer;
            if (op.requested_programmer != .auto and op.requested_programmer != info.programmer) return error.ProgrammerMismatch;
            if (!op.device.supports(info.programmer)) return error.UnsupportedProgrammer;
            op.programmer = info.programmer;
            op.descriptor = op.device.descriptor(info.programmer);
            if (op.kind == .read) {
                const size = memorySize(op.device, op.memory);
                if (size == 0) return error.EmptyMemoryRegion;
                op.data = try allocator().alloc(u8, size);
            } else {
                if (op.data.len > memorySize(op.device, op.memory)) return error.InputTooLarge;
                if (op.verify) op.verify_data = try allocator().alloc(u8, op.data.len);
                if (info.programmer == .t56) op.payload = try allocator().alloc(u8, @max(@as(usize, op.descriptor.write_buffer_size), 1));
            }
            op.state = if (op.programmer == .t56) .send_t56_bitstream_header else .send_begin;
        },
        .send_t56_bitstream_header => op.state = .send_t56_bitstream_payload,
        .send_t56_bitstream_payload => op.state = .send_begin,
        .send_begin => op.state = .send_begin_status,
        .send_begin_status => op.state = .recv_begin_status,
        .recv_begin_status => {
            try checkStatus(data);
            op.state = if (shouldCheckChipId(op)) .send_chip_id else afterChipIdState(op);
        },
        .send_chip_id => op.state = .recv_chip_id,
        .recv_chip_id => {
            try checkChipId(op, data);
            op.state = afterChipIdState(op);
        },
        .send_erase => op.state = .recv_erase,
        .recv_erase => op.state = .send_end_after_erase,
        .send_end_after_erase => op.state = if (op.programmer == .t56) .send_second_t56_bitstream_header else .send_second_begin,
        .send_second_t56_bitstream_header => op.state = .send_second_t56_bitstream_payload,
        .send_second_t56_bitstream_payload => op.state = .send_second_begin,
        .send_second_begin => op.state = .send_second_status,
        .send_second_status => op.state = .recv_second_status,
        .recv_second_status => {
            try checkStatus(data);
            op.state = .send_write_cmd;
        },
        .send_write_cmd => op.state = .send_write_payload,
        .send_write_payload => op.state = .send_write_status,
        .send_write_status => op.state = .recv_write_status,
        .recv_write_status => {
            try checkStatus(data);
            op.offset += currentWriteLen(op);
            if (op.offset < op.data.len) {
                op.state = .send_write_cmd;
            } else if (op.verify) {
                op.offset = 0;
                op.state = .verify_send_read_cmd;
            } else {
                op.state = .done;
            }
        },
        .send_read_cmd => op.state = .recv_read_payload,
        .recv_read_payload => {
            const len = currentReadLen(op);
            const source = if (op.programmer == .t56) data[0..@min(len, data.len)] else data;
            if (source.len < len) return error.ShortRead;
            @memcpy(op.data[op.offset .. op.offset + len], source[0..len]);
            op.offset += len;
            op.state = if (op.offset < op.data.len) .send_read_cmd else .done;
        },
        .verify_send_read_cmd => op.state = .verify_recv_read_payload,
        .verify_recv_read_payload => {
            const len = currentReadLen(op);
            const source = if (op.programmer == .t56) data[0..@min(len, data.len)] else data;
            if (source.len < len) return error.ShortRead;
            @memcpy(op.verify_data[op.offset .. op.offset + len], source[0..len]);
            op.offset += len;
            if (op.offset < op.verify_data.len) {
                op.state = .verify_send_read_cmd;
            } else if (std.mem.eql(u8, op.data, op.verify_data)) {
                op.state = .done;
            } else {
                return error.VerifyFailed;
            }
        },
        .done, .failed => {},
    }
}

fn outTransfer(op: *Operation, endpoint: u8, bytes: []const u8) Transfer {
    _ = op;
    const ptr: u32 = if (builtin.target.cpu.arch == .wasm32) @intCast(@intFromPtr(bytes.ptr)) else 0;
    return .{ .kind = .out, .endpoint = endpoint, .ptr = ptr, .len = @intCast(bytes.len) };
}

fn inTransfer(endpoint: u8, len: u32) Transfer {
    return .{ .kind = .in, .endpoint = endpoint, .len = len };
}

fn writeBeginPacket(op: *Operation) void {
    const device = op.descriptor;
    @memset(op.command[0..64], 0);
    op.command[0] = 0x03;
    op.command[1] = device.protocol_id;
    op.command[2] = @intCast(device.variant & 0xff);
    op.command[3] = device.icsp;
    endian.storeInt(op.command[4..6], device.voltages_raw, .little);
    op.command[6] = @intCast(device.chip_info & 0xff);
    op.command[7] = @intCast(device.pin_map & 0xff);
    endian.storeInt(op.command[8..10], device.data_memory_size, .little);
    endian.storeInt(op.command[10..12], device.page_size, .little);
    endian.storeInt(op.command[12..14], device.pulse_delay, .little);
    endian.storeInt(op.command[14..16], device.data_memory2_size, .little);
    endian.storeInt(op.command[16..20], device.code_memory_size, .little);
    op.command[20] = @intCast((device.voltages_raw >> 16) & 0xff);
    if (device.voltages_raw & 0xf0 == 0xf0) {
        op.command[22] = @intCast(device.voltages_raw & 0xff);
    } else {
        op.command[21] = @intCast(device.voltages_raw & 0x0f);
        op.command[22] = @intCast(device.voltages_raw & 0xf0);
    }
    if (device.voltages_raw & 0x80000000 != 0) op.command[22] = @intCast((device.voltages_raw >> 16) & 0x0f);
    if (device.can_adjust_clock) {
        if (op.programmer == .t48) op.command[24] = 1;
        op.command[28] = device.spi_clock;
    }
    endian.storeInt(op.command[40..44], device.package_details_raw, .little);
    endian.storeInt(op.command[44..46], device.read_buffer_size, .little);
    endian.storeInt(op.command[56..60], device.flags_raw, .little);
}

fn readCommand(memory: model.MemoryKind) u8 {
    return switch (memory) {
        .code => 0x0d,
        .data => 0x10,
        .user => 0x0b,
    };
}

fn writeCommand(memory: model.MemoryKind) u8 {
    return switch (memory) {
        .code => 0x0c,
        .data => 0x11,
        .user => 0x0a,
    };
}

fn currentReadLen(op: *Operation) usize {
    const total = if (op.state == .verify_send_read_cmd or op.state == .verify_recv_read_payload) op.verify_data.len else op.data.len;
    const descriptor_chunk = @max(@as(usize, op.descriptor.read_buffer_size), 1);
    const chunk = if (op.programmer == .t56) @min(descriptor_chunk, t56_read_payload_max) else descriptor_chunk;
    return @min(chunk, total - op.offset);
}

fn currentWriteLen(op: *Operation) usize {
    const chunk = @max(@as(usize, op.descriptor.write_buffer_size), 1);
    return @min(chunk, op.data.len - op.offset);
}

fn memorySize(device: catalog.DeviceRecord, memory: model.MemoryKind) usize {
    return switch (memory) {
        .code => device.code_memory_size,
        .data => device.data_memory_size,
        .user => device.data_memory2_size,
    };
}

fn shouldCheckChipId(op: *Operation) bool {
    return !op.skip_id_check and op.device.chip_id != 0 and op.device.chip_id_bytes_count != 0;
}

fn afterChipIdState(op: *Operation) State {
    return switch (op.kind) {
        .read => .send_read_cmd,
        .write => if (op.erase) .send_erase else .send_write_cmd,
    };
}

fn checkStatus(data: []const u8) !void {
    if (data.len < 13) return error.ShortRead;
    if (data[12] != 0) return error.Overcurrent;
    if (data[0] != 0) return error.ProgrammerStatusError;
}

fn checkChipId(op: *Operation, data: []const u8) !void {
    if (data.len < 2 + op.device.chip_id_bytes_count) return error.ShortRead;
    const id_type = data[0];
    const id_len = @min(op.device.chip_id_bytes_count, 4);
    const byte_order: endian.Endian = if (id_type == 3 or id_type == 4) .little else .big;
    const actual: u32 = if (id_len == 0) 0 else @intCast(endian.loadInt(data[2 .. 2 + id_len], byte_order));
    if (actual != op.device.chip_id) return error.ChipIdMismatch;
}

fn programmerFromAbi(value: u32) !model.Programmer {
    return switch (value) {
        0 => .auto,
        1 => .t48,
        2 => .t56,
        else => error.InvalidProgrammer,
    };
}

fn memoryFromAbi(value: u32) !model.MemoryKind {
    return switch (value) {
        0 => .code,
        1 => .data,
        2 => .user,
        else => error.InvalidMemoryKind,
    };
}

fn operationFromHandle(handle: u32) *Operation {
    return @ptrFromInt(handle);
}

fn sliceConst(ptr: u32, len: u32) []const u8 {
    if (ptr == 0 or len == 0) return &.{};
    const bytes: [*]const u8 = @ptrFromInt(ptr);
    return bytes[0..len];
}

fn writeJsonString(writer: anytype, text: []const u8) !void {
    try writer.writeByte('"');
    for (text) |byte| {
        switch (byte) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            0x08 => try writer.writeAll("\\b"),
            0x0c => try writer.writeAll("\\f"),
            0x00...0x07, 0x0b, 0x0e...0x1f => try writer.print("\\u00{x:0>2}", .{byte}),
            else => try writer.writeByte(byte),
        }
    }
    try writer.writeByte('"');
}

fn setResult(bytes: []u8) u32 {
    if (last_result.len != 0) allocator().free(last_result);
    last_result = bytes;
    return 0;
}

fn setError(message: []const u8) u32 {
    if (last_error.len != 0) allocator().free(last_error);
    last_error = allocator().dupe(u8, message) catch &.{};
    return 1;
}

fn errorCode(err: anyerror) u32 {
    return switch (err) {
        error.UnsupportedProgrammer => 10,
        error.ProgrammerMismatch => 11,
        error.DeviceNotFound => 12,
        error.ChipIdMismatch => 13,
        error.Overcurrent => 14,
        error.ProgrammerStatusError => 15,
        error.VerifyFailed => 16,
        error.AlgorithmUnavailable => 17,
        error.PayloadBufferTooSmall => 18,
        else => 1,
    };
}

fn failStart(message: []const u8) u32 {
    _ = setError(message);
    return 0;
}

test "device list ABI returns JSON" {
    if (builtin.target.cpu.arch != .wasm32) return error.SkipZigTest;
    const rc = mp_device_list(0, 0, 1, 10);
    try std.testing.expectEqual(@as(u32, 0), rc);
    const ptr = mp_result_ptr();
    const len = mp_result_len();
    const bytes = sliceConst(ptr, len);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "AT28C64B") != null);
}

test "JSON string writer escapes generated catalog names" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try writeJsonString(&out.writer, "A\"B\\C\n");
    const bytes = try out.toOwnedSlice();
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings("\"A\\\"B\\\\C\\n\"", bytes);
}

test "T56 Wasm reads are capped to native protocol payload window" {
    var bytes = [_]u8{0} ** 512;
    var op = Operation{
        .kind = .read,
        .requested_programmer = .t56,
        .programmer = .t56,
        .device = catalog.devices[0],
        .descriptor = catalog.devices[0].descriptor(.t56),
        .memory = .code,
        .state = .send_read_cmd,
        .data = &bytes,
    };
    op.descriptor.read_buffer_size = 512;
    try std.testing.expectEqual(@as(usize, t56_read_payload_max), currentReadLen(&op));
}

test "T56 Wasm write payload uses owned payload buffer" {
    var data = [_]u8{0xaa} ** 20;
    var payload = [_]u8{0} ** 1024;
    var op = Operation{
        .kind = .write,
        .requested_programmer = .t56,
        .programmer = .t56,
        .device = catalog.devices[0],
        .descriptor = catalog.devices[0].descriptor(.t56),
        .memory = .code,
        .state = .send_write_payload,
        .data = &data,
        .payload = &payload,
    };
    op.descriptor.write_buffer_size = 1024;
    const transfer = try nextTransfer(&op);
    try std.testing.expectEqual(TransferKind.out, transfer.kind);
    try std.testing.expectEqual(@as(u8, 1), transfer.endpoint);
    try std.testing.expectEqual(@as(u32, 1024), transfer.len);
    try std.testing.expectEqualSlices(u8, &data, payload[0..data.len]);
    try std.testing.expectEqual(@as(u8, 0), payload[data.len]);
}
