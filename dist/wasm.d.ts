import { DeviceDetail, DeviceListQuery, DeviceSummary, MemoryKind, ProgrammerKind, RomProgressHandler } from './types';
export interface WasmExports {
    memory: WebAssembly.Memory;
    mp_alloc(len: number): number;
    mp_free(ptr: number, len: number): void;
    mp_result_ptr(): number;
    mp_result_len(): number;
    mp_last_error_ptr(): number;
    mp_last_error_len(): number;
    mp_device_list(queryPtr: number, queryLen: number, programmer: number, limit: number): number;
    mp_device_detail(devicePtr: number, deviceLen: number, programmer: number): number;
    mp_start_pin_check(programmer: number, devicePtr: number, deviceLen: number): number;
    mp_start_read_rom(programmer: number, devicePtr: number, deviceLen: number, memory: number, skipIdCheck: number, continueOnIdMismatch: number): number;
    mp_start_write_rom(programmer: number, devicePtr: number, deviceLen: number, memory: number, dataPtr: number, dataLen: number, erase: number, eraseNumFuses: number, erasePld: number, verify: number, skipIdCheck: number, continueOnIdMismatch: number, unprotectBefore: number, protectAfter: number): number;
    mp_operation_next(handle: number): number;
    mp_transfer_endpoint(handle: number): number;
    mp_transfer_ptr(handle: number): number;
    mp_transfer_len(handle: number): number;
    mp_operation_complete(handle: number, status: number, dataPtr: number, dataLen: number): number;
    mp_operation_result(handle: number): number;
    mp_operation_result_ptr(handle: number): number;
    mp_operation_result_len(handle: number): number;
    mp_operation_error_ptr(handle: number): number;
    mp_operation_error_len(handle: number): number;
    mp_operation_error_code(handle: number): number;
    mp_operation_abort(handle: number): number;
    mp_operation_offset(handle: number): number;
    mp_operation_total(handle: number): number;
    mp_operation_phase(handle: number): number;
    mp_operation_destroy(handle: number): void;
}
export type UsbTransfer = {
    direction: "out";
    endpoint: number;
    data: Uint8Array;
} | {
    direction: "in";
    endpoint: number;
    length: number;
};
export type UsbTransferHandler = (transfer: UsbTransfer) => Promise<Uint8Array | void>;
export interface RunOperationOptions {
    signal?: AbortSignal;
    onProgress?: RomProgressHandler;
    onCleanupFailure?: () => void;
}
declare const wasmOperationHandleBrand: unique symbol;
export type WasmOperationHandle = number & {
    readonly [wasmOperationHandleBrand]: true;
};
export declare class WasmBridge {
    private readonly exports;
    private readonly operations;
    constructor(exports: WasmExports);
    static load(wasmUrl?: string | URL): Promise<WasmBridge>;
    deviceList(query?: DeviceListQuery): DeviceSummary[];
    resolveDevice(name: string, programmer?: ProgrammerKind): DeviceDetail | null;
    startReadROM(options: {
        programmer: ProgrammerKind;
        device: string;
        memory: MemoryKind;
        skipIdCheck: boolean;
        continueOnIdMismatch: boolean;
    }): WasmOperationHandle;
    startPinCheck(options: {
        programmer: "auto" | "t48";
        device: string;
    }): WasmOperationHandle;
    startWriteROM(options: {
        programmer: ProgrammerKind;
        device: string;
        memory: MemoryKind;
        data: Uint8Array;
        erase: boolean;
        eraseNumFuses: number;
        erasePld: number;
        verify: boolean;
        skipIdCheck: boolean;
        continueOnIdMismatch: boolean;
        unprotectBefore: boolean;
        protectAfter: boolean;
    }): WasmOperationHandle;
    disposeOperation(handle: WasmOperationHandle): void;
    runOperation(handle: WasmOperationHandle, performTransfer: UsbTransferHandler, options?: RunOperationOptions): Promise<Uint8Array>;
    memoryBytes(ptr: number, len: number): Uint8Array;
    private withBytes;
    private resultBytes;
    private operationResultBytes;
    private lastError;
    private throwIfError;
    private operationError;
    private operationProgress;
    private registerOperation;
    private drainCleanupBestEffort;
    private drainCleanup;
}
export declare function programmerToAbi(programmer: ProgrammerKind): number;
export declare function memoryToAbi(memory: MemoryKind): number;
export {};
//# sourceMappingURL=wasm.d.ts.map