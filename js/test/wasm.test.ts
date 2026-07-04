import { describe, expect, it, vi } from "vitest";
import { XgecuWebUSBError } from "../src/errors";
import { WasmBridge } from "../src/wasm";
import type { UsbTransfer, WasmExports } from "../src/wasm";

describe("WasmBridge", () => {
  it("surfaces start-operation errors from Wasm", () => {
    const fake = fakeExports();
    fake.error = "device not found";
    fake.mp_start_read_rom = vi.fn(() => 0);
    const bridge = new WasmBridge(fake);

    expect(() =>
      bridge.startReadROM({
        programmer: "t48",
        device: "missing",
        memory: "code",
        skipIdCheck: false
      })
    ).toThrow("device not found");
  });

  it("runs OUT and IN transfers and always destroys the operation", async () => {
    const fake = fakeExports();
    const outbound = new Uint8Array([0xa5, 0x5a]);
    fake.writeMemory(256, outbound);
    fake.sequence = [1, 2, 0];
    fake.transferPtr = 256;
    fake.transferLen = outbound.byteLength;
    fake.inLength = 3;
    fake.result = new Uint8Array([0x42]);
    const bridge = new WasmBridge(fake);
    const seen: UsbTransfer[] = [];

    const result = await bridge.runOperation(123, async (transfer) => {
      seen.push(transfer);
      if (transfer.direction === "in") return new Uint8Array([1, 2, 3]);
      return;
    });

    expect(seen).toEqual([
      { direction: "out", endpoint: 1, data: outbound },
      { direction: "in", endpoint: 2, length: 3 }
    ]);
    expect(fake.completedIn).toEqual(new Uint8Array([1, 2, 3]));
    expect(result).toEqual(new Uint8Array([0x42]));
    expect(fake.mp_operation_destroy).toHaveBeenCalledWith(123);
  });

  it("destroys failed operations and reports Wasm errors", async () => {
    const fake = fakeExports();
    fake.error = "VerifyFailed";
    fake.sequence = [3];
    const bridge = new WasmBridge(fake);

    await expect(bridge.runOperation(9, async () => undefined)).rejects.toThrow(XgecuWebUSBError);
    expect(fake.mp_operation_destroy).toHaveBeenCalledWith(9);
  });
});

type MutableWasmExports = WasmExports & {
  completedIn: Uint8Array;
  currentKind: number;
  error: string;
  inLength: number;
  result: Uint8Array;
  sequence: number[];
  transferLen: number;
  transferPtr: number;
  writeMemory(ptr: number, bytes: Uint8Array): void;
};

function fakeExports(): MutableWasmExports {
  const memory = new WebAssembly.Memory({ initial: 1 });
  const encoder = new TextEncoder();
  let nextPtr = 1024;
  const fake = {
    memory,
    completedIn: new Uint8Array(),
    currentKind: 0,
    error: "",
    inLength: 0,
    result: new Uint8Array(),
    sequence: [] as number[],
    transferLen: 0,
    transferPtr: 0,
    writeMemory(ptr: number, bytes: Uint8Array): void {
      new Uint8Array(memory.buffer, ptr, bytes.byteLength).set(bytes);
    },
    mp_alloc: vi.fn((len: number) => {
      const ptr = nextPtr;
      nextPtr += Math.max(len, 1);
      return ptr;
    }),
    mp_free: vi.fn((_ptr: number, _len: number) => {}),
    mp_result_ptr: vi.fn(() => {
      fake.writeMemory(512, fake.result);
      return fake.result.byteLength === 0 ? 0 : 512;
    }),
    mp_result_len: vi.fn(() => fake.result.byteLength),
    mp_last_error_ptr: vi.fn(() => {
      const bytes = encoder.encode(fake.error);
      fake.writeMemory(384, bytes);
      return bytes.byteLength === 0 ? 0 : 384;
    }),
    mp_last_error_len: vi.fn(() => encoder.encode(fake.error).byteLength),
    mp_device_list: vi.fn(() => 0),
    mp_start_read_rom: vi.fn(() => 1),
    mp_start_write_rom: vi.fn(() => 2),
    mp_operation_next: vi.fn(() => {
      fake.currentKind = fake.sequence.shift() ?? 0;
      return fake.currentKind;
    }),
    mp_transfer_endpoint: vi.fn(() => (fake.currentKind === 1 ? 1 : 2)),
    mp_transfer_ptr: vi.fn(() => fake.transferPtr),
    mp_transfer_len: vi.fn(() => (fake.currentKind === 2 ? fake.inLength : fake.transferLen)),
    mp_operation_complete: vi.fn((_handle: number, _status: number, dataPtr: number, dataLen: number) => {
      if (dataLen !== 0) fake.completedIn = new Uint8Array(memory.buffer, dataPtr, dataLen).slice();
      return 0;
    }),
    mp_operation_result: vi.fn(() => 0),
    mp_operation_destroy: vi.fn((_handle: number) => {})
  };
  return fake as MutableWasmExports;
}
