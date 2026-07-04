import { XgecuWebUSBError } from "./errors";
import type { DeviceListQuery, DeviceSummary, MemoryKind, ProgrammerKind } from "./types";

export interface WasmExports {
  memory: WebAssembly.Memory;
  mp_alloc(len: number): number;
  mp_free(ptr: number, len: number): void;
  mp_result_ptr(): number;
  mp_result_len(): number;
  mp_last_error_ptr(): number;
  mp_last_error_len(): number;
  mp_device_list(queryPtr: number, queryLen: number, programmer: number, limit: number): number;
  mp_start_read_rom(programmer: number, devicePtr: number, deviceLen: number, memory: number, skipIdCheck: number): number;
  mp_start_write_rom(
    programmer: number,
    devicePtr: number,
    deviceLen: number,
    memory: number,
    dataPtr: number,
    dataLen: number,
    erase: number,
    verify: number,
    skipIdCheck: number
  ): number;
  mp_operation_next(handle: number): number;
  mp_transfer_endpoint(handle: number): number;
  mp_transfer_ptr(handle: number): number;
  mp_transfer_len(handle: number): number;
  mp_operation_complete(handle: number, status: number, dataPtr: number, dataLen: number): number;
  mp_operation_result(handle: number): number;
  mp_operation_destroy(handle: number): void;
}

export type UsbTransfer =
  | { direction: "out"; endpoint: number; data: Uint8Array }
  | { direction: "in"; endpoint: number; length: number };

export type UsbTransferHandler = (transfer: UsbTransfer) => Promise<Uint8Array | void>;

const textEncoder = new TextEncoder();
const textDecoder = new TextDecoder();

export class WasmBridge {
  constructor(private readonly exports: WasmExports) {}

  static async load(wasmUrl?: string | URL): Promise<WasmBridge> {
    const url = wasmUrl ?? new URL(/* @vite-ignore */ "./xgecu_webusb.wasm", import.meta.url);
    const response = await fetch(url);
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

  startReadROM(options: { programmer: ProgrammerKind; device: string; memory: MemoryKind; skipIdCheck: boolean }): number {
    const deviceBytes = textEncoder.encode(options.device);
    return this.withBytes(deviceBytes, (devicePtr) => {
      const handle = this.exports.mp_start_read_rom(
        programmerToAbi(options.programmer),
        devicePtr,
        deviceBytes.byteLength,
        memoryToAbi(options.memory),
        options.skipIdCheck ? 1 : 0
      );
      if (handle === 0) throw new XgecuWebUSBError("Failed to start readROM operation.");
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
          options.skipIdCheck ? 1 : 0
        );
        if (handle === 0) throw new XgecuWebUSBError("Failed to start writeROM operation.");
        return handle;
      })
    );
  }

  async runOperation(handle: number, performTransfer: UsbTransferHandler): Promise<Uint8Array> {
    try {
      for (;;) {
        const kind = this.exports.mp_operation_next(handle);
        if (kind === 0) {
          this.throwIfError(this.exports.mp_operation_result(handle));
          return this.resultBytes().slice();
        }
        if (kind === 1) {
          const endpoint = this.exports.mp_transfer_endpoint(handle);
          const data = this.memoryBytes(this.exports.mp_transfer_ptr(handle), this.exports.mp_transfer_len(handle)).slice();
          await performTransfer({ direction: "out", endpoint, data });
          this.throwIfError(this.exports.mp_operation_complete(handle, 0, 0, 0));
          continue;
        }
        if (kind === 2) {
          const endpoint = this.exports.mp_transfer_endpoint(handle);
          const length = this.exports.mp_transfer_len(handle);
          const result = await performTransfer({ direction: "in", endpoint, length });
          const bytes = result instanceof Uint8Array ? result : new Uint8Array();
          this.withBytes(bytes, (ptr) => {
            this.throwIfError(this.exports.mp_operation_complete(handle, 0, ptr, bytes.byteLength));
          });
          continue;
        }
        throw new XgecuWebUSBError(this.lastError() || "Wasm operation failed.");
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
