import { describe, expect, it, vi } from "vitest";
import { WebUSBTransferError } from "../src/errors";
import { BrowserXgecuWebUSB, performWebUSBTransfer } from "../src/webusb";
import type { ProgrammerConnection, USBDeviceLike, USBNavigatorLike } from "../src/types";
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
  outStatus: "ok" | "stall" | "babble" = "ok";
  inStatus: "ok" | "stall" | "babble" = "ok";
  bytesWritten: number | undefined;
  omitInData = false;
  failRelease = false;

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
  releaseInterface = vi.fn(async (_interfaceNumber: number) => {
    if (this.failRelease) throw new Error("release failed");
  });

  async transferOut(endpointNumber: number, data: BufferSource) {
    this.out.push({ endpoint: endpointNumber, data: bufferSourceBytes(data) });
    return { status: this.outStatus, bytesWritten: this.bytesWritten ?? this.out[this.out.length - 1].data.byteLength };
  }

  async transferIn(endpointNumber: number, length: number) {
    if (this.omitInData) return { status: this.inStatus };
    const next = this.in.shift() ?? new Uint8Array(length);
    return { status: this.inStatus, data: new DataView(next.buffer, next.byteOffset, next.byteLength) };
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

  it("rejects failed OUT transfers", async () => {
    const device = new FakeDevice();
    device.outStatus = "stall";
    await expect(performWebUSBTransfer(device, { direction: "out", endpoint: 1, data: new Uint8Array([0xaa]) })).rejects.toThrow(WebUSBTransferError);
  });

  it("rejects short OUT transfers", async () => {
    const device = new FakeDevice();
    device.bytesWritten = 0;
    await expect(performWebUSBTransfer(device, { direction: "out", endpoint: 1, data: new Uint8Array([0xaa]) })).rejects.toThrow("wrote 0 of 1 bytes");
  });

  it("rejects failed or empty IN transfers", async () => {
    const stalled = new FakeDevice();
    stalled.inStatus = "stall";
    await expect(performWebUSBTransfer(stalled, { direction: "in", endpoint: 1, length: 4 })).rejects.toThrow(WebUSBTransferError);

    const empty = new FakeDevice();
    empty.omitInData = true;
    await expect(performWebUSBTransfer(empty, { direction: "in", endpoint: 1, length: 4 })).rejects.toThrow("returned no data");
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

    const result = await api.requestProgrammer();
    expect(result.status).toBe("ok");
    const programmer = result.unwrap();

    expect(programmer.opened).toBe(true);
    expect(device.configuration).toEqual({ configurationValue: 1 });
    expect(device.claimInterface).toHaveBeenCalledWith(0);
  });

  it("releases the claimed interface before closing", async () => {
    const device = new FakeDevice();
    const result = await new BrowserXgecuWebUSB(fakeWasm(), {
      requestDevice: vi.fn(async () => device),
      getDevices: vi.fn(async () => [device])
    }).requestProgrammer();
    const programmer = result.unwrap();

    await programmer.close();

    expect(device.releaseInterface).toHaveBeenCalledWith(0);
    expect(device.opened).toBe(false);
  });

  it("still closes when interface release fails", async () => {
    const device = new FakeDevice();
    device.failRelease = true;
    const result = await new BrowserXgecuWebUSB(fakeWasm(), {
      requestDevice: vi.fn(async () => device),
      getDevices: vi.fn(async () => [device])
    }).requestProgrammer();
    const programmer = result.unwrap();

    await expect(programmer.close()).resolves.toBeUndefined();

    expect(device.releaseInterface).toHaveBeenCalledWith(0);
    expect(device.opened).toBe(false);
  });

  it("routes readROM through the Wasm operation runner", async () => {
    const device = new FakeDevice();
    const wasm = fakeWasm();
    const runOperation = vi.spyOn(wasm, "runOperation");
    const api = new BrowserXgecuWebUSB(wasm, {
      requestDevice: vi.fn(async () => device),
      getDevices: vi.fn(async () => [device])
    });
    const programmer = (await api.requestProgrammer()).unwrap();
    const result = await api.readROM({ programmer, device: "AT28C64B", skipIdCheck: true });

    expect(result.status).toBe("ok");
    expect(result.unwrap()).toEqual(new Uint8Array([0x42]));
    expect(runOperation).toHaveBeenCalledOnce();
  });

  it("configures and claims already-open devices before reads", async () => {
    const device = new FakeDevice();
    device.opened = true;
    const api = new BrowserXgecuWebUSB(fakeWasm(), fakeUsb(device));
    const programmer = programmerConnection(device);

    const result = await api.readROM({ programmer, device: "AT28C64B" });

    expect(result.status).toBe("ok");
    expect(device.configuration).toEqual({ configurationValue: 1 });
    expect(device.claimInterface).toHaveBeenCalledWith(0);
  });

  it("routes writeROM with safe defaults", async () => {
    const device = new FakeDevice();
    const wasm = fakeWasm();
    const startWriteROM = vi.spyOn(wasm, "startWriteROM");
    const runOperation = vi.spyOn(wasm, "runOperation");
    const api = new BrowserXgecuWebUSB(wasm, fakeUsb(device));
    const programmer = (await api.requestProgrammer()).unwrap();
    const data = new Uint8Array([0x01, 0x02]);

    const result = await api.writeROM({ programmer, device: "AT28C64B@DIP28", data });

    expect(result.status).toBe("ok");
    expect(startWriteROM).toHaveBeenCalledWith({
      programmer: "auto",
      device: "AT28C64B@DIP28",
      memory: "code",
      data,
      erase: true,
      verify: true,
      skipIdCheck: false,
      continueOnIdMismatch: false,
      unprotectBefore: false,
      protectAfter: false
    });
    expect(runOperation).toHaveBeenCalledOnce();
  });

  it("rejects empty writeROM data before starting Wasm operation", async () => {
    const device = new FakeDevice();
    const wasm = fakeWasm();
    const startWriteROM = vi.spyOn(wasm, "startWriteROM");
    const api = new BrowserXgecuWebUSB(wasm, fakeUsb(device));
    const programmer = (await api.requestProgrammer()).unwrap();

    const result = await api.writeROM({ programmer, device: "AT28C64B@DIP28", data: new Uint8Array() });
    expect(result.status).toBe("error");
    if (result.status === "error") expect(result.error.message).toContain("must not be empty");
    expect(startWriteROM).not.toHaveBeenCalled();
  });

  it("rejects concurrent ROM operations on one device", async () => {
    const device = new FakeDevice();
    let release!: () => void;
    const wasm = fakeWasm();
    vi.spyOn(wasm, "runOperation").mockImplementation(
      () =>
        new Promise<Uint8Array>((resolve) => {
          release = () => resolve(new Uint8Array([0x42]));
        })
    );
    const api = new BrowserXgecuWebUSB(wasm, fakeUsb(device));
    const programmer = (await api.requestProgrammer()).unwrap();

    const first = api.readROM({ programmer, device: "AT28C64B" });
    const second = await api.readROM({ programmer, device: "AT28C64B" });
    release();
    await first;

    expect(second.status).toBe("error");
    if (second.status === "error") expect(second.error.code).toBe("OperationInProgress");
  });
});

function fakeWasm(): WasmBridge {
  return {
    deviceList: () => [fakeDeviceSummary()],
    resolveDevice: () => fakeDeviceSummary(),
    startReadROM: () => 1,
    startWriteROM: () => 2,
    runOperation: async (_handle: number, performTransfer: UsbTransferHandler) => {
      await performTransfer({ direction: "out", endpoint: 1, data: new Uint8Array([0]) });
      return new Uint8Array([0x42]);
    }
  } as unknown as WasmBridge;
}

function fakeDeviceSummary() {
  return {
    name: "AT28C64B@DIP28",
    aliases: ["AT28C64B"],
    chipType: "memory",
    codeMemorySize: 8192,
    dataMemorySize: 0,
    userMemorySize: 0,
    packagePins: 28,
    pageSize: 64,
    chipId: 0,
    chipIdBytesCount: 0,
    blankValue: 0xff,
    supportsT48: true,
    supportsT56: false
  } as const;
}

function fakeUsb(device: FakeDevice): USBNavigatorLike {
  return {
    requestDevice: vi.fn(async () => device),
    getDevices: vi.fn(async () => [device])
  };
}

function programmerConnection(device: FakeDevice): ProgrammerConnection {
  return {
    device,
    productName: device.productName,
    manufacturerName: device.manufacturerName,
    serialNumber: device.serialNumber,
    vendorId: device.vendorId,
    productId: device.productId,
    opened: device.opened,
    close: async () => device.close()
  };
}

function bufferSourceBytes(data: BufferSource): Uint8Array {
  if (data instanceof ArrayBuffer) return new Uint8Array(data).slice();
  return new Uint8Array(data.buffer, data.byteOffset, data.byteLength).slice();
}
