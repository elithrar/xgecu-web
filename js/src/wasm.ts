import { XgecuWebUSBError, xgecuErrorCodeFromAbi } from "./errors";
import type { DeviceDetail, DeviceListQuery, DeviceSummary, MemoryKind, ProgrammerKind, RomProgressEvent, RomProgressHandler, RomOperationPhase } from "./types";

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
  mp_start_read_rom(programmer: number, devicePtr: number, deviceLen: number, memory: number, skipIdCheck: number, continueOnIdMismatch: number): number;
  mp_start_write_rom(
    programmer: number,
    devicePtr: number,
    deviceLen: number,
    memory: number,
    dataPtr: number,
    dataLen: number,
    erase: number,
    verify: number,
    skipIdCheck: number,
    continueOnIdMismatch: number,
    unprotectBefore: number,
    protectAfter: number
  ): number;
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

export type UsbTransfer =
  | { direction: "out"; endpoint: number; data: Uint8Array }
  | { direction: "in"; endpoint: number; length: number };

export type UsbTransferHandler = (transfer: UsbTransfer) => Promise<Uint8Array | void>;

export interface RunOperationOptions {
  signal?: AbortSignal;
  onProgress?: RomProgressHandler;
}

const textEncoder = new TextEncoder();
const textDecoder = new TextDecoder();

export class WasmBridge {
  constructor(private readonly exports: WasmExports) {}

  static async load(wasmUrl?: string | URL): Promise<WasmBridge> {
    const url = wasmUrl ?? new URL(/* @vite-ignore */ "./xgecu_web.wasm", import.meta.url);
    const response = await fetch(url);
    if (!response.ok) throw new XgecuWebUSBError(`Failed to load xgecu_web.wasm: HTTP ${response.status}.`);
    const module = await WebAssembly.instantiate(await response.arrayBuffer(), {});
    return new WasmBridge(module.instance.exports as unknown as WasmExports);
  }

  deviceList(query: DeviceListQuery = {}): DeviceSummary[] {
    const queryBytes = textEncoder.encode(query.search ?? "");
    return this.withBytes(queryBytes, (queryPtr) => {
      const rc = this.exports.mp_device_list(queryPtr, queryBytes.byteLength, programmerToAbi(query.programmer ?? "auto"), query.limit ?? 100);
      this.throwIfError(rc);
      return JSON.parse(textDecoder.decode(this.resultBytes())) as DeviceSummary[];
    });
  }

  resolveDevice(name: string, programmer: ProgrammerKind = "auto"): DeviceDetail | null {
    const deviceBytes = textEncoder.encode(name);
    return this.withBytes(deviceBytes, (devicePtr) => {
      const rc = this.exports.mp_device_detail(devicePtr, deviceBytes.byteLength, programmerToAbi(programmer));
      this.throwIfError(rc);
      return JSON.parse(textDecoder.decode(this.resultBytes())) as DeviceDetail | null;
    });
  }

  startReadROM(options: { programmer: ProgrammerKind; device: string; memory: MemoryKind; skipIdCheck: boolean; continueOnIdMismatch: boolean }): number {
    const deviceBytes = textEncoder.encode(options.device);
    return this.withBytes(deviceBytes, (devicePtr) => {
      const handle = this.exports.mp_start_read_rom(
        programmerToAbi(options.programmer),
        devicePtr,
        deviceBytes.byteLength,
        memoryToAbi(options.memory),
        options.skipIdCheck ? 1 : 0,
        options.continueOnIdMismatch ? 1 : 0
      );
      if (handle === 0) throw new XgecuWebUSBError(this.lastError() || "Failed to start readROM operation.");
      return handle;
    });
  }

  startWriteROM(options: {
    programmer: ProgrammerKind;
    device: string;
    memory: MemoryKind;
    data: Uint8Array;
    erase: boolean;
    verify: boolean;
    skipIdCheck: boolean;
    continueOnIdMismatch: boolean;
    unprotectBefore: boolean;
    protectAfter: boolean;
  }): number {
    const deviceBytes = textEncoder.encode(options.device);
    return this.withBytes(deviceBytes, (devicePtr) =>
      this.withBytes(options.data, (dataPtr) => {
        const handle = this.exports.mp_start_write_rom(
          programmerToAbi(options.programmer),
          devicePtr,
          deviceBytes.byteLength,
          memoryToAbi(options.memory),
          dataPtr,
          options.data.byteLength,
          options.erase ? 1 : 0,
          options.verify ? 1 : 0,
          options.skipIdCheck ? 1 : 0,
          options.continueOnIdMismatch ? 1 : 0,
          options.unprotectBefore ? 1 : 0,
          options.protectAfter ? 1 : 0
        );
        if (handle === 0) throw new XgecuWebUSBError(this.lastError() || "Failed to start writeROM operation.");
        return handle;
      })
    );
  }

  async runOperation(handle: number, performTransfer: UsbTransferHandler, options: RunOperationOptions = {}): Promise<Uint8Array> {
    try {
      for (;;) {
        if (options.signal?.aborted) {
          this.exports.mp_operation_abort(handle);
          await this.drainCleanupBestEffort(handle, performTransfer);
          throw new XgecuWebUSBError("Operation aborted.", "OperationAborted");
        }
        const kind = this.exports.mp_operation_next(handle);
        if (kind === 0) {
          this.throwIfError(this.exports.mp_operation_result(handle));
          options.onProgress?.(this.operationProgress(handle));
          return this.operationResultBytes(handle).slice();
        }
        if (kind === 1) {
          const endpoint = this.exports.mp_transfer_endpoint(handle);
          const data = this.memoryBytes(this.exports.mp_transfer_ptr(handle), this.exports.mp_transfer_len(handle)).slice();
          try {
            await performTransfer({ direction: "out", endpoint, data });
          } catch (error) {
            await this.failTransferAndCleanupBestEffort(handle, performTransfer);
            throw error;
          }
          const rc = this.exports.mp_operation_complete(handle, 0, 0, 0);
          if (rc !== 0) {
            await this.drainCleanup(handle, performTransfer);
            throw this.operationError(handle);
          }
          options.onProgress?.(this.operationProgress(handle));
          continue;
        }
        if (kind === 2) {
          const endpoint = this.exports.mp_transfer_endpoint(handle);
          const length = this.exports.mp_transfer_len(handle);
          let result: Uint8Array | void;
          try {
            result = await performTransfer({ direction: "in", endpoint, length });
          } catch (error) {
            await this.failTransferAndCleanupBestEffort(handle, performTransfer);
            throw error;
          }
          const bytes = result instanceof Uint8Array ? result : new Uint8Array();
          let rc = 0;
          this.withBytes(bytes, (ptr) => {
            rc = this.exports.mp_operation_complete(handle, 0, ptr, bytes.byteLength);
          });
          if (rc !== 0) {
            await this.drainCleanup(handle, performTransfer);
            throw this.operationError(handle);
          }
          options.onProgress?.(this.operationProgress(handle));
          continue;
        }
        throw this.operationError(handle);
      }
    } finally {
      this.exports.mp_operation_destroy(handle);
    }
  }

  memoryBytes(ptr: number, len: number): Uint8Array {
    return new Uint8Array(this.exports.memory.buffer, ptr, len);
  }

  private withBytes<T>(bytes: Uint8Array, callback: (ptr: number) => T): T {
    if (bytes.byteLength === 0) return callback(0);
    const ptr = this.exports.mp_alloc(bytes.byteLength);
    if (ptr === 0) throw new XgecuWebUSBError("Wasm allocation failed.");
    this.memoryBytes(ptr, bytes.byteLength).set(bytes);
    try {
      return callback(ptr);
    } finally {
      this.exports.mp_free(ptr, bytes.byteLength);
    }
  }

  private resultBytes(): Uint8Array {
    return this.memoryBytes(this.exports.mp_result_ptr(), this.exports.mp_result_len());
  }

  private operationResultBytes(handle: number): Uint8Array {
    return this.memoryBytes(this.exports.mp_operation_result_ptr(handle), this.exports.mp_operation_result_len(handle));
  }

  private lastError(): string {
    const ptr = this.exports.mp_last_error_ptr();
    const len = this.exports.mp_last_error_len();
    if (ptr === 0 || len === 0) return "";
    return textDecoder.decode(this.memoryBytes(ptr, len));
  }

  private throwIfError(rc: number): void {
    if (rc === 0) return;
    throw new XgecuWebUSBError(this.lastError() || "Wasm call failed.");
  }

  private operationError(handle: number): XgecuWebUSBError {
    const code = this.exports.mp_operation_error_code(handle);
    const ptr = this.exports.mp_operation_error_ptr(handle);
    const len = this.exports.mp_operation_error_len(handle);
    const message = ptr === 0 || len === 0 ? this.lastError() || "Wasm operation failed." : textDecoder.decode(this.memoryBytes(ptr, len));
    return new XgecuWebUSBError(message, xgecuErrorCodeFromAbi(code));
  }

  private operationProgress(handle: number): RomProgressEvent {
    return {
      phase: phaseFromAbi(this.exports.mp_operation_phase(handle)),
      offset: this.exports.mp_operation_offset(handle),
      total: this.exports.mp_operation_total(handle)
    };
  }

  private async failTransferAndCleanupBestEffort(handle: number, performTransfer: UsbTransferHandler): Promise<void> {
    this.exports.mp_operation_complete(handle, 1, 0, 0);
    await this.drainCleanupBestEffort(handle, performTransfer);
  }

  private async drainCleanupBestEffort(handle: number, performTransfer: UsbTransferHandler): Promise<void> {
    try {
      await this.drainCleanup(handle, performTransfer);
    } catch {
      // Cleanup is best effort after a failure or abort; preserve the original error.
    }
  }

  private async drainCleanup(handle: number, performTransfer: UsbTransferHandler): Promise<void> {
    for (let step = 0; step < 4; step += 1) {
      const kind = this.exports.mp_operation_next(handle);
      if (kind === 0 || kind === 3) return;
      if (kind === 1) {
        const endpoint = this.exports.mp_transfer_endpoint(handle);
        const data = this.memoryBytes(this.exports.mp_transfer_ptr(handle), this.exports.mp_transfer_len(handle)).slice();
        await performTransfer({ direction: "out", endpoint, data });
        this.exports.mp_operation_complete(handle, 0, 0, 0);
        continue;
      }
      if (kind === 2) {
        const endpoint = this.exports.mp_transfer_endpoint(handle);
        const length = this.exports.mp_transfer_len(handle);
        const result = await performTransfer({ direction: "in", endpoint, length });
        const bytes = result instanceof Uint8Array ? result : new Uint8Array();
        this.withBytes(bytes, (ptr) => {
          this.exports.mp_operation_complete(handle, 0, ptr, bytes.byteLength);
        });
      }
    }
  }
}

export function programmerToAbi(programmer: ProgrammerKind): number {
  switch (programmer) {
    case "auto":
      return 0;
    case "t48":
      return 1;
    case "t56":
      return 2;
  }
}

export function memoryToAbi(memory: MemoryKind): number {
  switch (memory) {
    case "code":
      return 0;
    case "data":
      return 1;
    case "user":
      return 2;
  }
}

function phaseFromAbi(phase: number): RomOperationPhase {
  switch (phase) {
    case 1:
      return "connecting";
    case 2:
      return "identifying";
    case 3:
      return "erasing";
    case 4:
      return "writing";
    case 5:
      return "reading";
    case 6:
      return "verifying";
    case 7:
      return "cleanup";
    case 8:
      return "done";
    case 9:
      return "failed";
    default:
      return "connecting";
  }
}
