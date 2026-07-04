import { describe, expect, it, vi } from "vitest";
import { BrowserXgecuWebUSB, performWebUSBTransfer } from "../src/webusb";
import type { USBDeviceLike, USBNavigatorLike } from "../src/types";
import type { UsbTransferHandler, WasmBridge } from "../src/wasm";

class FakeDevice implements USBDeviceLike {
  opened = false;
  vendorId = 0xa466;
  productId = 0x0a53;
  productName = "T48";
  manufacturerName = "XGecu";
  serialNumber = "TEST";
  configuration: unknown | null = null;
  out: Array<{ endpoint: number; data: Uint8Array }> = [];
  in: Uint8Array[] = [new Uint8Array([1, 2, 3, 4])];

  async open(): Promise<void> {
    this.opened = true;
  }

  async close(): Promise<void> {
    this.opened = false;
  }

  async selectConfiguration(configurationValue: number): Promise<void> {
    this.configuration = { configurationValue };
  }

  claimInterface = vi.fn(async (_interfaceNumber: number) => {});

  async transferOut(endpointNumber: number, data: BufferSource) {
    this.out.push({ endpoint: endpointNumber, data: new Uint8Array(data instanceof ArrayBuffer ? data : data.buffer).slice() });
    return { status: "ok" as const, bytesWritten: this.out[this.out.length - 1].data.byteLength };
  }

  async transferIn(endpointNumber: number, length: number) {
    const next = this.in.shift() ?? new Uint8Array(length);
    return { status: "ok" as const, data: new DataView(next.buffer, next.byteOffset, next.byteLength) };
  }
}

describe("performWebUSBTransfer", () => {
  it("maps ABI OUT transfers to WebUSB transferOut", async () => {
    const device = new FakeDevice();
    await performWebUSBTransfer(device, { direction: "out", endpoint: 1, data: new Uint8Array([0xaa, 0xbb]) });
    expect(device.out).toEqual([{ endpoint: 1, data: new Uint8Array([0xaa, 0xbb]) }]);
  });

  it("maps ABI IN transfers to WebUSB transferIn", async () => {
    const device = new FakeDevice();
    const data = await performWebUSBTransfer(device, { direction: "in", endpoint: 2, length: 4 });
    expect(data).toEqual(new Uint8Array([1, 2, 3, 4]));
  });
});

describe("BrowserXgecuWebUSB", () => {
  it("opens, configures, and claims requested programmers", async () => {
    const device = new FakeDevice();
    const usb: USBNavigatorLike = {
      requestDevice: vi.fn(async () => device),
      getDevices: vi.fn(async () => [device])
    };
    const api = new BrowserXgecuWebUSB(fakeWasm(), usb);

    const programmer = await api.requestProgrammer();

    expect(programmer.opened).toBe(true);
    expect(device.configuration).toEqual({ configurationValue: 1 });
    expect(device.claimInterface).toHaveBeenCalledWith(0);
  });

  it("routes readROM through the Wasm operation runner", async () => {
    const device = new FakeDevice();
    const wasm = fakeWasm();
    const runOperation = vi.spyOn(wasm, "runOperation");
    const api = new BrowserXgecuWebUSB(wasm, {
      requestDevice: vi.fn(async () => device),
      getDevices: vi.fn(async () => [device])
    });
    const programmer = await api.requestProgrammer();
    const data = await api.readROM({ programmer, device: "AT28C64B", skipIdCheck: true });

    expect(data).toEqual(new Uint8Array([0x42]));
    expect(runOperation).toHaveBeenCalledOnce();
  });
});

function fakeWasm(): WasmBridge {
  return {
    deviceList: () => [{ name: "AT28C64B@DIP28", codeMemorySize: 8192, dataMemorySize: 0, packagePins: 28, supportsT48: true, supportsT56: true }],
    startReadROM: () => 1,
    startWriteROM: () => 2,
    runOperation: async (_handle: number, performTransfer: UsbTransferHandler) => {
      await performTransfer({ direction: "out", endpoint: 1, data: new Uint8Array([0]) });
      return new Uint8Array([0x42]);
    }
  } as unknown as WasmBridge;
}
