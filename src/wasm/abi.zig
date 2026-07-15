// SPDX-License-Identifier: Apache-2.0

const std = @import("std");
const builtin = @import("builtin");
const catalog = @import("../catalog/catalog.zig");
const endian = @import("../core/endian.zig");
const model = @import("../core/model.zig");
const protocol_bytes = @import("../programmer/protocol_bytes.zig");
const session = @import("../programmer/session.zig");
const t48 = @import("../programmer/t48.zig");

const command = protocol_bytes.command;
const endpoints = protocol_bytes.endpoint;
const packet = protocol_bytes.packet;

const TransferKind = enum(u32) {
    done = 0,
    out = 1,
    in = 2,
    failed = 3,
};

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
    send_protect_off,
    send_protect_off_status,
    recv_protect_off_status,
    send_write_cmd,
    send_write_payload,
    send_write_status,
    recv_write_status,
    send_end_before_verify,
    send_verify_t56_bitstream_header,
    send_verify_t56_bitstream_payload,
    send_verify_begin,
    send_verify_begin_status,
    recv_verify_begin_status,
    send_protect_on,
    send_protect_on_status,
    recv_protect_on_status,
    send_read_cmd,
    recv_read_payload,
    send_read_status,
    recv_read_status,
    verify_send_read_cmd,
    verify_recv_read_payload,
    verify_send_read_status,
    verify_recv_read_status,
    send_final_end,
    send_abort_end,
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
    erase_num_fuses: u8 = 0,
    erase_pld: u8 = 0,
    verify: bool = false,
    data: []u8 = &.{},
    verify_data: []u8 = &.{},
    payload: []u8 = &.{},
    offset: usize = 0,
    command: [packet.begin_len]u8 = [_]u8{0} ** packet.begin_len,
    transfer: Transfer = .{},
    error_code: u32 = 0,
    result: []u8 = &.{},
    error_message: []u8 = &.{},
    short_read_actual: usize = 0,
    short_read_required: usize = 0,
    continue_on_id_mismatch: bool = false,
    unprotect_before: bool = false,
    protect_after: bool = false,
    transaction_open: bool = false,

    fn deinit(self: *Operation, alloc: std.mem.Allocator) void {
        if (self.data.len != 0) alloc.free(self.data);
        if (self.verify_data.len != 0) alloc.free(self.verify_data);
        if (self.payload.len != 0) alloc.free(self.payload);
        if (self.result.len != 0) alloc.free(self.result);
        if (self.error_message.len != 0) alloc.free(self.error_message);
        alloc.destroy(self);
    }
};

var last_result: []u8 = &.{};
var last_error: []u8 = &.{};

fn allocator() std.mem.Allocator {
    if (comptime builtin.is_test) return std.testing.allocator;
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
        writeDeviceSummaryJson(&out.writer, summary) catch return setError("out of memory");
    }
    out.writer.writeAll("]") catch return setError("out of memory");
    return setResult(out.toOwnedSlice() catch return setError("out of memory"));
}

export fn mp_device_detail(name_ptr: u32, name_len: u32, programmer_value: u32) u32 {
    const name = sliceConst(name_ptr, name_len);
    const programmer = programmerFromAbi(programmer_value) catch return setError("invalid programmer");
    const device = catalog.find(name, programmer) catch return setResult(allocator().dupe(u8, "null") catch return setError("out of memory"));
    const package = model.decodePackageDetails(device.package_details_raw);
    const summary = catalog.DeviceSummary{
        .name = device.canonical_name,
        .aliases = device.aliases,
        .chip_type = device.chip_type,
        .code_memory_size = device.code_memory_size,
        .data_memory_size = device.data_memory_size,
        .user_memory_size = device.data_memory2_size,
        .package_pins = package.pin_count,
        .page_size = device.page_size,
        .chip_id = device.chip_id,
        .chip_id_bytes_count = device.chip_id_bytes_count,
        .blank_value = device.blank_value,
        .can_erase = device.can_erase,
        .supports_t48 = device.supports(.t48),
        .supports_t56 = device.supports(.t56),
    };
    var out: std.Io.Writer.Allocating = .init(allocator());
    defer out.deinit();
    writeDeviceSummaryJson(&out.writer, summary) catch return setError("out of memory");
    return setResult(out.toOwnedSlice() catch return setError("out of memory"));
}

export fn mp_start_read_rom(programmer_value: u32, device_ptr: u32, device_len: u32, memory_value: u32, skip_id_check: u32, continue_on_id_mismatch: u32) u32 {
    if (skip_id_check > 1 or continue_on_id_mismatch > 1) return failStart("invalid boolean option");
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
        .continue_on_id_mismatch = continue_on_id_mismatch != 0,
    };
    return @intCast(@intFromPtr(op));
}

export fn mp_start_write_rom(programmer_value: u32, device_ptr: u32, device_len: u32, memory_value: u32, data_ptr: u32, data_len: u32, erase: u32, erase_num_fuses: u32, erase_pld: u32, verify: u32, skip_id_check: u32, continue_on_id_mismatch: u32, unprotect_before: u32, protect_after: u32) u32 {
    if (data_len == 0) return failStart("input data is empty");
    if (data_ptr == 0) return failStart("invalid data pointer");
    if (erase > 1 or verify > 1 or skip_id_check > 1 or continue_on_id_mismatch > 1 or unprotect_before > 1 or protect_after > 1) return failStart("invalid boolean option");
    if (erase_num_fuses > std.math.maxInt(u8) or erase_pld > std.math.maxInt(u8)) return failStart("invalid erase option");
    const programmer = programmerFromAbi(programmer_value) catch return failStart("invalid programmer");
    const memory = memoryFromAbi(memory_value) catch return failStart("invalid memory kind");
    const device_name = sliceConst(device_ptr, device_len);
    const device = catalog.find(device_name, programmer) catch return failStart("device not found or unsupported by requested programmer");
    const size = memorySize(device, memory);
    if (size == 0) return failStart("EmptyMemoryRegion");
    if (data_len > size) return failStart("InputTooLarge");
    if (erase != 0 and memory != .code) return failStart("InputTooLarge");
    if (erase != 0 and data_len != size) return failStart("InputTooLarge");
    if (erase != 0 and !device.can_erase) return failStart("EraseUnsupported");
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
        .erase_num_fuses = @intCast(erase_num_fuses),
        .erase_pld = @intCast(erase_pld),
        .verify = verify != 0,
        .skip_id_check = skip_id_check != 0,
        .continue_on_id_mismatch = continue_on_id_mismatch != 0,
        .unprotect_before = unprotect_before != 0,
        .protect_after = protect_after != 0,
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
        setOperationError(op, err);
        op.state = if (op.transaction_open) .send_abort_end else .failed;
        if (op.state == .send_abort_end) {
            op.transfer = nextTransfer(op) catch {
                op.state = .failed;
                return @intFromEnum(TransferKind.failed);
            };
            op.awaiting = op.transfer.kind == .out or op.transfer.kind == .in;
            return @intFromEnum(op.transfer.kind);
        }
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
        setOperationError(op, error.WebUSBTransferFailed);
        op.state = if (op.transaction_open and op.state != .send_final_end and op.state != .send_abort_end) .send_abort_end else .failed;
        return 1;
    }
    completeTransfer(op, sliceConst(data_ptr, data_len)) catch |err| {
        setOperationError(op, err);
        op.state = if (op.transaction_open) .send_abort_end else .failed;
        return 1;
    };
    return 0;
}

export fn mp_operation_result(handle: u32) u32 {
    const op = operationFromHandle(handle);
    if (op.state != .done) return setError("operation is not complete");
    clearOperationResult(op);
    return switch (op.kind) {
        .read => setOperationResult(op, allocator().dupe(u8, op.data) catch return setError("out of memory")),
        .write => setOperationResult(op, allocator().dupe(u8, "null") catch return setError("out of memory")),
    };
}

export fn mp_operation_result_ptr(handle: u32) u32 {
    const op = operationFromHandle(handle);
    return if (op.result.len == 0) 0 else @intCast(@intFromPtr(op.result.ptr));
}

export fn mp_operation_result_len(handle: u32) u32 {
    return @intCast(operationFromHandle(handle).result.len);
}

export fn mp_operation_error_ptr(handle: u32) u32 {
    const op = operationFromHandle(handle);
    return if (op.error_message.len == 0) 0 else @intCast(@intFromPtr(op.error_message.ptr));
}

export fn mp_operation_error_len(handle: u32) u32 {
    return @intCast(operationFromHandle(handle).error_message.len);
}

export fn mp_operation_error_code(handle: u32) u32 {
    return operationFromHandle(handle).error_code;
}

export fn mp_operation_abort(handle: u32) u32 {
    const op = operationFromHandle(handle);
    op.awaiting = false;
    setOperationError(op, error.OperationAborted);
    op.state = if (op.transaction_open) .send_abort_end else .failed;
    return 0;
}

export fn mp_operation_offset(handle: u32) u32 {
    return @intCast(@min(operationFromHandle(handle).offset, std.math.maxInt(u32)));
}

export fn mp_operation_total(handle: u32) u32 {
    const op = operationFromHandle(handle);
    const total = switch (op.kind) {
        .read => op.data.len,
        .write => if (op.state == .verify_send_read_cmd or op.state == .verify_recv_read_payload) op.verify_data.len else op.data.len,
    };
    return @intCast(@min(total, std.math.maxInt(u32)));
}

export fn mp_operation_phase(handle: u32) u32 {
    return phaseCode(operationFromHandle(handle).state);
}

fn nextTransfer(op: *Operation) !Transfer {
    switch (op.state) {
        .send_info => {
            @memset(op.command[0..packet.system_info_request_len], 0);
            return outTransfer(op, endpoints.command, op.command[0..packet.system_info_request_len]);
        },
        .recv_info => return inTransfer(endpoints.command, packet.system_info_response_len),
        .send_t56_bitstream_header, .send_second_t56_bitstream_header, .send_verify_t56_bitstream_header => {
            @memset(op.command[0..packet.bitstream_header_len], 0);
            op.command[0] = command.write_bitstream;
            const bitstream = op.device.algorithmFor(.t56) orelse return error.AlgorithmUnavailable;
            if (bitstream.len == 0) return error.AlgorithmUnavailable;
            endian.storeInt(op.command[4..8], bitstream.len, .little);
            return outTransfer(op, endpoints.command, op.command[0..packet.bitstream_header_len]);
        },
        .send_t56_bitstream_payload, .send_second_t56_bitstream_payload, .send_verify_t56_bitstream_payload => {
            const bitstream = op.device.algorithmFor(.t56) orelse return error.AlgorithmUnavailable;
            if (bitstream.len == 0) return error.AlgorithmUnavailable;
            return outTransfer(op, endpoints.command, bitstream);
        },
        .send_begin, .send_second_begin, .send_verify_begin => {
            writeBeginPacket(op);
            op.transaction_open = true;
            return outTransfer(op, endpoints.command, op.command[0..packet.begin_len]);
        },
        .send_begin_status, .send_second_status, .send_verify_begin_status, .send_protect_off_status, .send_write_status, .send_protect_on_status, .send_read_status, .verify_send_read_status => {
            @memset(op.command[0..packet.short_command_len], 0);
            op.command[0] = command.request_status;
            return outTransfer(op, endpoints.command, op.command[0..packet.short_command_len]);
        },
        .recv_begin_status, .recv_second_status, .recv_verify_begin_status, .recv_protect_off_status, .recv_write_status, .recv_protect_on_status, .recv_read_status, .verify_recv_read_status => return inTransfer(endpoints.command, packet.status_len),
        .send_chip_id => {
            @memset(op.command[0..packet.short_command_len], 0);
            op.command[0] = command.read_id;
            return outTransfer(op, endpoints.command, op.command[0..packet.short_command_len]);
        },
        .recv_chip_id => return inTransfer(endpoints.command, packet.chip_id_len),
        .send_erase => {
            @memset(op.command[0..packet.erase_len], 0);
            op.command[0] = command.erase;
            op.command[2] = op.erase_num_fuses;
            op.command[4] = op.erase_pld;
            return outTransfer(op, endpoints.command, op.command[0..packet.erase_len]);
        },
        .recv_erase => return inTransfer(endpoints.command, packet.erase_response_len),
        .send_protect_off, .send_protect_on => {
            @memset(op.command[0..packet.short_command_len], 0);
            op.command[0] = if (op.state == .send_protect_off) command.protect_off else command.protect_on;
            return outTransfer(op, endpoints.command, op.command[0..packet.short_command_len]);
        },
        .send_end_after_erase, .send_end_before_verify, .send_final_end, .send_abort_end => {
            @memset(op.command[0..packet.short_command_len], 0);
            op.command[0] = command.end_transaction;
            return outTransfer(op, endpoints.command, op.command[0..packet.short_command_len]);
        },
        .send_write_cmd => {
            const len = currentWriteLen(op);
            @memset(op.command[0..packet.short_command_len], 0);
            op.command[0] = writeCommand(op.memory);
            endian.storeInt(op.command[2..4], len, .little);
            endian.storeInt(op.command[4..8], op.offset, .little);
            return outTransfer(op, endpoints.command, op.command[0..packet.short_command_len]);
        },
        .send_write_payload => {
            const len = currentWriteLen(op);
            if (op.programmer == .t56) {
                const transfer_len = @max(@as(usize, op.descriptor.write_buffer_size), len);
                if (transfer_len > op.payload.len) return error.PayloadBufferTooSmall;
                @memset(op.payload[0..transfer_len], 0);
                @memcpy(op.payload[0..len], op.data[op.offset .. op.offset + len]);
                return outTransfer(op, endpoints.command, op.payload[0..transfer_len]);
            }
            return outTransfer(op, endpoints.payload, op.data[op.offset .. op.offset + len]);
        },
        .send_read_cmd, .verify_send_read_cmd => {
            const len = currentReadLen(op);
            @memset(op.command[0..packet.short_command_len], 0);
            op.command[0] = readCommand(op.memory);
            endian.storeInt(op.command[2..4], len, .little);
            endian.storeInt(op.command[4..8], op.offset, .little);
            return outTransfer(op, endpoints.command, op.command[0..packet.short_command_len]);
        },
        .recv_read_payload, .verify_recv_read_payload => {
            const len = currentReadLen(op);
            if (op.programmer == .t56) return inTransfer(endpoints.command, @intCast(len + packet.t56_read_status_slop));
            return inTransfer(endpoints.payload, @intCast(len));
        },
        .done => return .{ .kind = .done },
        .failed => return .{ .kind = .failed },
    }
}

fn completeTransfer(op: *Operation, data: []const u8) !void {
    switch (op.state) {
        .send_info => op.state = .recv_info,
        .recv_info => {
            if (data.len < packet.system_info_response_min_len) {
                setShortRead(op, data.len, packet.system_info_response_min_len);
                return error.ShortRead;
            }
            const info = session.parseSystemInfo(data) orelse return error.UnsupportedProgrammer;
            if (info.programmer != .t48 and info.programmer != .t56) return error.UnsupportedProgrammer;
            if (info.status == .bootloader) return error.ProgrammerInBootloader;
            if (op.requested_programmer != .auto and op.requested_programmer != info.programmer) return error.ProgrammerMismatch;
            if (!op.device.supports(info.programmer)) return error.UnsupportedProgrammer;
            op.programmer = info.programmer;
            op.descriptor = op.device.descriptor(info.programmer);
            if (op.kind == .read) {
                const size = memorySize(op.device, op.memory);
                if (size == 0) return error.EmptyMemoryRegion;
                op.data = try allocator().alloc(u8, size);
            } else {
                const size = memorySize(op.device, op.memory);
                if (size == 0) return error.EmptyMemoryRegion;
                if (op.data.len > size) return error.InputTooLarge;
                if (op.erase and op.memory != .code) return error.InputTooLarge;
                if (op.erase and op.data.len != size) return error.InputTooLarge;
                if (op.erase and !op.device.can_erase) return error.EraseUnsupported;
                if (op.verify) op.verify_data = try allocator().alloc(u8, op.data.len);
                if (info.programmer == .t56) {
                    if (op.descriptor.write_buffer_size > packet.t56_padded_write_payload_max) return error.PayloadBufferTooSmall;
                    op.payload = try allocator().alloc(u8, @max(@as(usize, op.descriptor.write_buffer_size), 1));
                }
            }
            op.state = if (op.programmer == .t56) .send_t56_bitstream_header else .send_begin;
        },
        .send_t56_bitstream_header => op.state = .send_t56_bitstream_payload,
        .send_t56_bitstream_payload => op.state = .send_begin,
        .send_begin => {
            op.transaction_open = true;
            op.state = .send_begin_status;
        },
        .send_begin_status => op.state = .recv_begin_status,
        .recv_begin_status => {
            try checkStatus(op, data);
            op.state = if (shouldCheckChipId(op)) .send_chip_id else afterChipIdState(op);
        },
        .send_chip_id => op.state = .recv_chip_id,
        .recv_chip_id => {
            try checkChipId(op, data);
            op.state = afterChipIdState(op);
        },
        .send_erase => op.state = .recv_erase,
        .recv_erase => {
            try checkEraseResponse(op, data);
            op.state = .send_end_after_erase;
        },
        .send_end_after_erase => {
            op.transaction_open = false;
            op.state = if (op.programmer == .t56) .send_second_t56_bitstream_header else .send_second_begin;
        },
        .send_second_t56_bitstream_header => op.state = .send_second_t56_bitstream_payload,
        .send_second_t56_bitstream_payload => op.state = .send_second_begin,
        .send_second_begin => {
            op.transaction_open = true;
            op.state = .send_second_status;
        },
        .send_second_status => op.state = .recv_second_status,
        .recv_second_status => {
            try checkStatus(op, data);
            op.state = if (op.unprotect_before) .send_protect_off else .send_write_cmd;
        },
        .send_protect_off => op.state = .send_protect_off_status,
        .send_protect_off_status => op.state = .recv_protect_off_status,
        .recv_protect_off_status => {
            try checkStatus(op, data);
            op.state = .send_write_cmd;
        },
        .send_write_cmd => op.state = .send_write_payload,
        .send_write_payload => op.state = .send_write_status,
        .send_write_status => op.state = .recv_write_status,
        .recv_write_status => {
            try checkStatus(op, data);
            op.offset += currentWriteLen(op);
            if (op.offset < op.data.len) {
                op.state = .send_write_cmd;
            } else if (op.verify) {
                op.offset = 0;
                op.state = .send_end_before_verify;
            } else if (op.protect_after) {
                op.state = .send_protect_on;
            } else {
                op.state = .send_final_end;
            }
        },
        .send_end_before_verify => {
            op.transaction_open = false;
            op.state = if (op.programmer == .t56) .send_verify_t56_bitstream_header else .send_verify_begin;
        },
        .send_verify_t56_bitstream_header => op.state = .send_verify_t56_bitstream_payload,
        .send_verify_t56_bitstream_payload => op.state = .send_verify_begin,
        .send_verify_begin => {
            op.transaction_open = true;
            op.state = .send_verify_begin_status;
        },
        .send_verify_begin_status => op.state = .recv_verify_begin_status,
        .recv_verify_begin_status => {
            try checkStatus(op, data);
            op.offset = 0;
            op.state = .verify_send_read_cmd;
        },
        .send_protect_on => op.state = .send_protect_on_status,
        .send_protect_on_status => op.state = .recv_protect_on_status,
        .recv_protect_on_status => {
            try checkStatus(op, data);
            op.state = .send_final_end;
        },
        .send_read_cmd => op.state = .recv_read_payload,
        .recv_read_payload => {
            const len = currentReadLen(op);
            const source = if (op.programmer == .t56) data[0..@min(len, data.len)] else data;
            if (source.len < len) {
                setShortRead(op, source.len, len);
                return error.ShortRead;
            }
            @memcpy(op.data[op.offset .. op.offset + len], source[0..len]);
            op.offset += len;
            op.state = if (op.programmer == .t48) .send_read_status else if (op.offset < op.data.len) .send_read_cmd else .send_final_end;
        },
        .send_read_status => op.state = .recv_read_status,
        .recv_read_status => {
            try checkStatus(op, data);
            op.state = if (op.offset < op.data.len) .send_read_cmd else .send_final_end;
        },
        .verify_send_read_cmd => op.state = .verify_recv_read_payload,
        .verify_recv_read_payload => {
            const len = currentReadLen(op);
            const source = if (op.programmer == .t56) data[0..@min(len, data.len)] else data;
            if (source.len < len) {
                setShortRead(op, source.len, len);
                return error.ShortRead;
            }
            @memcpy(op.verify_data[op.offset .. op.offset + len], source[0..len]);
            op.offset += len;
            op.state = if (op.programmer == .t48) .verify_send_read_status else try afterVerifyReadStatus(op);
        },
        .verify_send_read_status => op.state = .verify_recv_read_status,
        .verify_recv_read_status => {
            try checkStatus(op, data);
            op.state = try afterVerifyReadStatus(op);
        },
        .send_final_end => {
            op.transaction_open = false;
            op.state = .done;
        },
        .send_abort_end => {
            op.transaction_open = false;
            op.state = .failed;
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
    t48.writeBeginPacket(&op.command, op.programmer, op.descriptor);
}

fn readCommand(memory: model.MemoryKind) u8 {
    return switch (memory) {
        .code => command.read_code,
        .data => command.read_data,
        .user => command.read_user_data,
    };
}

fn writeCommand(memory: model.MemoryKind) u8 {
    return switch (memory) {
        .code => command.write_code,
        .data => command.write_data,
        .user => command.write_user_data,
    };
}

fn currentReadLen(op: *Operation) usize {
    const total = if (op.state == .verify_send_read_cmd or op.state == .verify_recv_read_payload) op.verify_data.len else op.data.len;
    const descriptor_chunk = @max(@as(usize, op.descriptor.read_buffer_size), 1);
    const chunk = if (op.programmer == .t56) @min(descriptor_chunk, packet.t56_read_payload_max) else descriptor_chunk;
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
        .write => if (op.erase) .send_erase else if (op.unprotect_before) .send_protect_off else .send_write_cmd,
    };
}

fn afterVerifyReadStatus(op: *Operation) !State {
    if (op.offset < op.verify_data.len) return .verify_send_read_cmd;
    if (std.mem.eql(u8, op.data, op.verify_data)) return if (op.protect_after) .send_protect_on else .send_final_end;
    return error.VerifyFailed;
}

fn checkStatus(op: *Operation, data: []const u8) !void {
    if (data.len < 13) {
        setShortRead(op, data.len, 13);
        return error.ShortRead;
    }
    if (data[12] != 0) return error.Overcurrent;
    if (data[0] != 0) return error.ProgrammerStatusError;
}

fn checkEraseResponse(op: *Operation, data: []const u8) !void {
    if (op.programmer == .t48 and data.len <= packet.t48_erase_ack_len) {
        if (data.len < packet.t48_erase_ack_len) {
            setShortRead(op, data.len, packet.t48_erase_ack_len);
            return error.ShortRead;
        }
        // T48's short erase acknowledgement is opaque; restart status is authoritative.
        return;
    }
    try checkStatus(op, data);
}

fn checkChipId(op: *Operation, data: []const u8) !void {
    const required = 2 + op.device.chip_id_bytes_count;
    if (data.len < required) {
        setShortRead(op, data.len, required);
        return error.ShortRead;
    }
    const id_type = data[0];
    const id_len = @min(op.device.chip_id_bytes_count, 4);
    const byte_order: endian.Endian = if (id_type == 3 or id_type == 4) .little else .big;
    const actual: u32 = if (id_len == 0) 0 else @intCast(endian.loadInt(data[2 .. 2 + id_len], byte_order));
    if (actual != op.device.chip_id and !op.continue_on_id_mismatch) return error.ChipIdMismatch;
}

fn setShortRead(op: *Operation, actual: usize, required: usize) void {
    op.short_read_actual = actual;
    op.short_read_required = required;
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

fn writeJsonStringArray(writer: anytype, values: []const []const u8) !void {
    try writer.writeByte('[');
    for (values, 0..) |value, index| {
        if (index != 0) try writer.writeByte(',');
        try writeJsonString(writer, value);
    }
    try writer.writeByte(']');
}

fn writeDeviceSummaryJson(writer: anytype, summary: catalog.DeviceSummary) !void {
    try writer.writeAll("{\"name\":");
    try writeJsonString(writer, summary.name);
    try writer.writeAll(",\"aliases\":");
    try writeJsonStringArray(writer, summary.aliases);
    try writer.writeAll(",\"chipType\":");
    try writeJsonString(writer, chipTypeName(summary.chip_type));
    try writer.print(
        ",\"codeMemorySize\":{d},\"dataMemorySize\":{d},\"userMemorySize\":{d},\"packagePins\":{d},\"pageSize\":{d},\"chipId\":{d},\"chipIdBytesCount\":{d},\"blankValue\":{d},\"canErase\":{},\"supportsT48\":{},\"supportsT56\":{}}}",
        .{
            summary.code_memory_size,
            summary.data_memory_size,
            summary.user_memory_size,
            summary.package_pins,
            summary.page_size,
            summary.chip_id,
            summary.chip_id_bytes_count,
            summary.blank_value,
            summary.can_erase,
            summary.supports_t48,
            summary.supports_t56,
        },
    );
}

fn chipTypeName(chip_type: model.ChipType) []const u8 {
    return switch (chip_type) {
        .memory => "memory",
        .mcu => "mcu",
        .pld => "pld",
        .sram => "sram",
        .logic => "logic",
        .nand => "nand",
        .emmc => "emmc",
        .vga => "vga",
    };
}

fn setResult(bytes: []u8) u32 {
    clearLastResult();
    clearLastError();
    last_result = bytes;
    return 0;
}

fn setError(message: []const u8) u32 {
    clearLastError();
    clearLastResult();
    last_error = allocator().dupe(u8, message) catch &.{};
    return 1;
}

fn clearLastResult() void {
    if (last_result.len == 0) return;
    allocator().free(last_result);
    last_result = &.{};
}

fn clearLastError() void {
    if (last_error.len == 0) return;
    allocator().free(last_error);
    last_error = &.{};
}

fn setOperationResult(op: *Operation, bytes: []u8) u32 {
    clearOperationResult(op);
    clearOperationError(op);
    op.result = bytes;
    return 0;
}

fn clearOperationResult(op: *Operation) void {
    if (op.result.len == 0) return;
    allocator().free(op.result);
    op.result = &.{};
}

fn setOperationError(op: *Operation, err: anyerror) void {
    clearOperationError(op);
    clearOperationResult(op);
    op.error_code = errorCode(err);
    op.error_message = if (err == error.ShortRead and op.short_read_required > 0)
        std.fmt.allocPrint(
            allocator(),
            "ShortRead in {s}: received {d} of {d} required bytes",
            .{ @tagName(op.state), op.short_read_actual, op.short_read_required },
        ) catch &.{}
    else
        allocator().dupe(u8, @errorName(err)) catch &.{};
}

fn clearOperationError(op: *Operation) void {
    if (op.error_message.len == 0) return;
    allocator().free(op.error_message);
    op.error_message = &.{};
}

fn resetAbiGlobalsForTest() void {
    if (!comptime builtin.is_test) return;
    clearLastResult();
    clearLastError();
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
        error.EmptyMemoryRegion => 19,
        error.InputTooLarge => 20,
        error.ProgrammerInBootloader => 21,
        error.OperationAborted => 22,
        error.WebUSBTransferFailed => 23,
        error.ShortRead => 24,
        else => 1,
    };
}

fn phaseCode(state: State) u32 {
    return switch (state) {
        .send_info, .recv_info, .send_t56_bitstream_header, .send_t56_bitstream_payload, .send_begin, .send_begin_status, .recv_begin_status, .send_second_t56_bitstream_header, .send_second_t56_bitstream_payload, .send_second_begin, .send_second_status, .recv_second_status => 1,
        .send_chip_id, .recv_chip_id => 2,
        .send_erase, .recv_erase, .send_end_after_erase => 3,
        .send_protect_off, .send_protect_off_status, .recv_protect_off_status, .send_write_cmd, .send_write_payload, .send_write_status, .recv_write_status, .send_protect_on, .send_protect_on_status, .recv_protect_on_status => 4,
        .send_read_cmd, .recv_read_payload, .send_read_status, .recv_read_status => 5,
        .send_end_before_verify, .send_verify_t56_bitstream_header, .send_verify_t56_bitstream_payload, .send_verify_begin, .send_verify_begin_status, .recv_verify_begin_status, .verify_send_read_cmd, .verify_recv_read_payload, .verify_send_read_status, .verify_recv_read_status => 6,
        .send_final_end, .send_abort_end => 7,
        .done => 8,
        .failed => 9,
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

test "Wasm start write rejects empty input before operation allocation" {
    defer resetAbiGlobalsForTest();

    const rc = mp_start_write_rom(1, 0, 0, 0, 0, 0, 1, 0, 0, 1, 0, 0, 0, 0);
    try std.testing.expectEqual(@as(u32, 0), rc);
    try std.testing.expectEqualStrings("input data is empty", last_error);
}

test "Wasm start write rejects a null pointer with non-empty input" {
    defer resetAbiGlobalsForTest();

    const rc = mp_start_write_rom(1, 0, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 0);
    try std.testing.expectEqual(@as(u32, 0), rc);
    try std.testing.expectEqualStrings("invalid data pointer", last_error);
}

test "ABI result and error buffers clear each other" {
    defer resetAbiGlobalsForTest();

    const alloc = allocator();
    try std.testing.expectEqual(@as(u32, 1), setError("first failure"));
    try std.testing.expectEqualStrings("first failure", last_error);

    const result = try alloc.dupe(u8, "ok");
    try std.testing.expectEqual(@as(u32, 0), setResult(result));
    try std.testing.expectEqualStrings("ok", last_result);
    try std.testing.expectEqual(@as(usize, 0), last_error.len);

    try std.testing.expectEqual(@as(u32, 1), setError("second failure"));
    try std.testing.expectEqualStrings("second failure", last_error);
    try std.testing.expectEqual(@as(usize, 0), last_result.len);
}

test "T48 Wasm write operation sequences write status and verify transfers" {
    const alloc = allocator();
    const data = try alloc.dupe(u8, &.{ 0x12, 0x34, 0x56, 0x78 });
    var op = Operation{
        .kind = .write,
        .requested_programmer = .auto,
        .device = catalog.devices[0],
        .descriptor = catalog.devices[0].descriptor(.t48),
        .memory = .code,
        .state = .recv_info,
        .data = data,
        .erase = false,
        .verify = true,
        .skip_id_check = true,
    };
    defer {
        alloc.free(op.data);
        if (op.verify_data.len != 0) alloc.free(op.verify_data);
    }

    var info = [_]u8{0} ** packet.system_info_response_len;
    info[4] = 1;
    info[5] = 2;
    info[6] = 7;
    @memcpy(info[8..24], "2026-07-04......");
    @memcpy(info[24..32], "T48CODE!");
    @memcpy(info[32..54], "SERIAL-T48-00000000000");
    var status = [_]u8{0} ** 32;

    try completeTransfer(&op, &info);
    try expectNextTransfer(&op, .out, 1, 64); // begin
    try completeTransfer(&op, &.{});
    try expectNextTransfer(&op, .out, 1, 8); // begin status command
    try completeTransfer(&op, &.{});
    try completeTransfer(&op, &status);
    try expectNextTransfer(&op, .out, 1, 8); // write command
    try completeTransfer(&op, &.{});
    try expectNextTransfer(&op, .out, 2, 4); // T48 payload endpoint
    try completeTransfer(&op, &.{});
    try expectNextTransfer(&op, .out, 1, 8); // write status command
    try completeTransfer(&op, &.{});
    try completeTransfer(&op, &status);
    try std.testing.expectEqual(@as(usize, 0), op.offset);
    try expectNextTransfer(&op, .out, 1, 8); // end write transaction before verify
    try completeTransfer(&op, &.{});
    try expectNextTransfer(&op, .out, 1, 64); // begin independent verify transaction
    try completeTransfer(&op, &.{});
    try expectNextTransfer(&op, .out, 1, 8); // verify begin status command
    try completeTransfer(&op, &.{});
    try completeTransfer(&op, &status);
    try expectNextTransfer(&op, .out, 1, 8); // verify read command
    try completeTransfer(&op, &.{});
    try expectNextTransfer(&op, .in, 2, 4); // T48 read payload endpoint
    try completeTransfer(&op, data);
    try expectNextTransfer(&op, .out, 1, 8); // verify read status command
    try completeTransfer(&op, &.{});
    try completeTransfer(&op, &status);
    try expectNextTransfer(&op, .out, 1, 8); // final end transaction
    try completeTransfer(&op, &.{});
    try std.testing.expectEqual(State.done, op.state);
}

test "Wasm system info probe requests the full response buffer" {
    var op = Operation{
        .kind = .read,
        .requested_programmer = .auto,
        .device = catalog.devices[0],
        .descriptor = catalog.devices[0].descriptor(.t48),
        .memory = .code,
        .state = .recv_info,
    };

    try expectNextTransfer(&op, .in, endpoints.command, packet.system_info_response_len);
}

test "Wasm system info ShortRead reports the protocol minimum" {
    var op = Operation{
        .kind = .read,
        .requested_programmer = .auto,
        .device = catalog.devices[0],
        .descriptor = catalog.devices[0].descriptor(.t48),
        .memory = .code,
        .state = .recv_info,
    };
    var short = [_]u8{0} ** (packet.system_info_response_min_len - 1);

    try std.testing.expectError(error.ShortRead, completeTransfer(&op, &short));
    setOperationError(&op, error.ShortRead);
    defer clearOperationError(&op);

    try std.testing.expectEqualStrings(
        "ShortRead in recv_info: received 62 of 63 required bytes",
        op.error_message,
    );
}

test "Wasm rejects partial data before an erase transaction" {
    var data = [_]u8{0xaa};
    var op = Operation{
        .kind = .write,
        .requested_programmer = .t48,
        .device = catalog.devices[0],
        .descriptor = catalog.devices[0].descriptor(.t48),
        .memory = .code,
        .state = .recv_info,
        .data = &data,
        .erase = true,
    };
    var info = [_]u8{0} ** packet.system_info_response_min_len;
    info[4] = 1;
    info[6] = 7;

    try std.testing.expectError(error.InputTooLarge, completeTransfer(&op, &info));
    try std.testing.expectEqual(State.recv_info, op.state);
}

test "Wasm rejects electrical erase for UV EPROM after programmer detection" {
    var data = [_]u8{0xff} ** 8192;
    var op = Operation{
        .kind = .write,
        .requested_programmer = .t48,
        .device = catalog.devices[1],
        .descriptor = catalog.devices[1].descriptor(.t48),
        .memory = .code,
        .state = .recv_info,
        .data = &data,
        .erase = true,
    };
    var info = [_]u8{0} ** packet.system_info_response_min_len;
    info[4] = 1;
    info[6] = 7;

    try std.testing.expectError(error.EraseUnsupported, completeTransfer(&op, &info));
    try std.testing.expectEqual(State.recv_info, op.state);
}

test "T48 Wasm erase response status is validated" {
    var data = [_]u8{0xaa};
    var op = Operation{
        .kind = .write,
        .requested_programmer = .t48,
        .programmer = .t48,
        .device = catalog.devices[0],
        .descriptor = catalog.devices[0].descriptor(.t48),
        .memory = .code,
        .state = .recv_erase,
        .data = &data,
    };
    var status = [_]u8{0} ** 32;
    status[0] = 1;
    try std.testing.expectError(error.ProgrammerStatusError, completeTransfer(&op, &status));
}

test "T48 Wasm accepts short-packet erase acknowledgement" {
    var data = [_]u8{0xaa};
    var op = Operation{
        .kind = .write,
        .requested_programmer = .t48,
        .programmer = .t48,
        .device = catalog.devices[0],
        .descriptor = catalog.devices[0].descriptor(.t48),
        .memory = .code,
        .state = .recv_erase,
        .data = &data,
    };
    var response = [_]u8{0} ** packet.t48_erase_ack_len;
    response[0] = command.erase;

    try completeTransfer(&op, &response);
    try std.testing.expectEqual(State.send_end_after_erase, op.state);
}

test "T48 Wasm rejects truncated erase acknowledgement" {
    var data = [_]u8{0xaa};
    var op = Operation{
        .kind = .write,
        .requested_programmer = .t48,
        .programmer = .t48,
        .device = catalog.devices[0],
        .descriptor = catalog.devices[0].descriptor(.t48),
        .memory = .code,
        .state = .recv_erase,
        .data = &data,
    };
    var response = [_]u8{0} ** (packet.t48_erase_ack_len - 1);

    try std.testing.expectError(error.ShortRead, completeTransfer(&op, &response));
    try std.testing.expectEqual(@as(usize, response.len), op.short_read_actual);
    try std.testing.expectEqual(@as(usize, packet.t48_erase_ack_len), op.short_read_required);
}

test "T48 Wasm rejects incomplete extended erase status" {
    var data = [_]u8{0xaa};
    var op = Operation{
        .kind = .write,
        .requested_programmer = .t48,
        .programmer = .t48,
        .device = catalog.devices[0],
        .descriptor = catalog.devices[0].descriptor(.t48),
        .memory = .code,
        .state = .recv_erase,
        .data = &data,
    };
    var response = [_]u8{0} ** 12;

    try std.testing.expectError(error.ShortRead, completeTransfer(&op, &response));
    try std.testing.expectEqual(@as(usize, response.len), op.short_read_actual);
    try std.testing.expectEqual(@as(usize, 13), op.short_read_required);
}

test "Wasm ShortRead errors report state and required length" {
    var data = [_]u8{0xaa} ** 4;
    var verify_data = [_]u8{0} ** 4;
    var op = Operation{
        .kind = .write,
        .requested_programmer = .t48,
        .programmer = .t48,
        .device = catalog.devices[0],
        .descriptor = catalog.devices[0].descriptor(.t48),
        .memory = .code,
        .state = .verify_recv_read_payload,
        .data = &data,
        .verify_data = &verify_data,
        .verify = true,
    };

    try std.testing.expectError(error.ShortRead, completeTransfer(&op, &.{0xaa}));
    setOperationError(&op, error.ShortRead);
    defer clearOperationError(&op);

    try std.testing.expectEqual(@as(u32, 24), op.error_code);
    try std.testing.expectEqualStrings(
        "ShortRead in verify_recv_read_payload: received 1 of 4 required bytes",
        op.error_message,
    );
}

test "Wasm protection runs after verification and checks status" {
    var data = [_]u8{0xaa};
    var verify_data = [_]u8{0xaa};
    var op = Operation{
        .kind = .write,
        .requested_programmer = .t48,
        .programmer = .t48,
        .device = catalog.devices[0],
        .descriptor = catalog.devices[0].descriptor(.t48),
        .memory = .code,
        .state = .verify_recv_read_status,
        .data = &data,
        .verify_data = &verify_data,
        .offset = 1,
        .verify = true,
        .protect_after = true,
        .transaction_open = true,
    };
    var status = [_]u8{0} ** packet.status_len;

    try completeTransfer(&op, &status);
    try expectNextTransfer(&op, .out, endpoints.command, packet.short_command_len);
    try std.testing.expectEqual(command.protect_on, op.command[0]);
    try completeTransfer(&op, &.{});
    try expectNextTransfer(&op, .out, endpoints.command, packet.short_command_len);
    try std.testing.expectEqual(command.request_status, op.command[0]);
    try completeTransfer(&op, &.{});
    try expectNextTransfer(&op, .in, endpoints.command, packet.status_len);
    status[0] = 1;
    try std.testing.expectError(error.ProgrammerStatusError, completeTransfer(&op, &status));
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
    try std.testing.expectEqual(@as(usize, packet.t56_read_payload_max), currentReadLen(&op));
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

fn expectNextTransfer(op: *Operation, kind: TransferKind, endpoint: u8, len: u32) !void {
    const transfer = try nextTransfer(op);
    try std.testing.expectEqual(kind, transfer.kind);
    try std.testing.expectEqual(endpoint, transfer.endpoint);
    try std.testing.expectEqual(len, transfer.len);
}
