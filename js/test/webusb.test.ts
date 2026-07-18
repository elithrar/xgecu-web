import { describe, expect, it, vi } from "vitest";
import { WebUSBTransferError } from "../src/errors";
import { BrowserXgecuWebUSB, performWebUSBTransfer } from "../src/webusb";
import type { USBConfigurationLike, USBDeviceLike, USBNavigatorLike } from "../src/types";
import type { UsbTransferHandler, WasmBridge } from "../src/wasm";

class FakeDevice implements USBDeviceLike {
  opened = false;
  vendorId = 0xa466;
  productId = 0x0a53;
  productName = "T48";
  manufacturerName = "XGecu";
  serialNumber = "TEST";
  configuration: USBConfigurationLike | null = null;
  out: Array<{ endpoint: number; data: Uint8Array }> = [];
  in: Uint8Array[] = [new Uint8Array([1, 2, 3, 4])];
  outStatus: "ok" | "stall" | "babble" = "ok";
  inStatus: "ok" | "stall" | "babble" = "ok";
  bytesWritten: number | undefined;
  omitInData = false;
  failRelease = false;
  failClose = false;
  failClaim = false;
  failTransferIn: unknown;

  async open(): Promise<void> {
    this.opened = true;
  }

  async close(): Promise<void> {
    if (this.failClose) throw new Error("close failed");
    this.opened = false;
  }

  async selectConfiguration(configurationValue: number): Promise<void> {
    this.configuration = { configurationValue };
  }

  claimInterface = vi.fn(async (_interfaceNumber: number) => {
    if (this.failClaim) throw new Error("claim failed");
  });
  selectAlternateInterface = vi.fn(async (_interfaceNumber: number, alternateSetting: number) => {
    const usbInterface = this.configuration?.interfaces?.[0];
    const alternate = usbInterface?.alternates.find((entry) => entry.alternateSetting === alternateSetting);
    if (usbInterface && alternate) (usbInterface as { alternate: typeof alternate }).alternate = alternate;
  });
  releaseInterface = vi.fn(async (_interfaceNumber: number) => {
    if (this.failRelease) throw new Error("release failed");
  });

  async transferOut(endpointNumber: number, data: BufferSource) {
    this.out.push({ endpoint: endpointNumber, data: bufferSourceBytes(data) });
    return { status: this.outStatus, bytesWritten: this.bytesWritten ?? this.out[this.out.length - 1].data.byteLength };
  }

  async transferIn(endpointNumber: number, length: number) {
    if (this.failTransferIn) throw this.failTransferIn;
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

  it("accepts a successful short IN packet for protocol-level validation", async () => {
    const device = new FakeDevice();
    const data = await performWebUSBTransfer(device, { direction: "in", endpoint: 1, length: 20 });
    expect(data).toEqual(new Uint8Array([1, 2, 3, 4]));
  });

  it("wraps rejected WebUSB transfers with a stable error code", async () => {
    const device = new FakeDevice();
    const cause = new DOMException("disconnected", "NetworkError");
    device.failTransferIn = cause;
    await expect(performWebUSBTransfer(device, { direction: "in", endpoint: 1, length: 4 })).rejects.toMatchObject({
      code: "WebUSBTransferFailed",
      cause
    });
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
    device.productName = "XGecu T48 \0";
    device.manufacturerName = "XGecu.com\0\0";
    device.serialNumber = "";
    const usb: USBNavigatorLike = {
      requestDevice: vi.fn(async () => device),
      getDevices: vi.fn(async () => [device])
    };
    const api = new BrowserXgecuWebUSB(fakeWasm(), usb);

    const programmer = await api.requestProgrammer();

    expect(programmer.opened).toBe(true);
    expect(programmer.productName).toBe("XGecu T48");
    expect(programmer.manufacturerName).toBe("XGecu.com");
    expect(programmer.serialNumber).toBeUndefined();
    expect(device.configuration).toEqual({ configurationValue: 1 });
    expect(device.claimInterface).toHaveBeenCalledWith(0);
  });

  it("releases the claimed interface before closing", async () => {
    const device = new FakeDevice();
    const programmer = await new BrowserXgecuWebUSB(fakeWasm(), {
      requestDevice: vi.fn(async () => device),
      getDevices: vi.fn(async () => [device])
    }).requestProgrammer();

    await programmer.close();

    expect(device.releaseInterface).toHaveBeenCalledWith(0);
    expect(device.opened).toBe(false);
  });

  it("still closes when interface release fails", async () => {
    const device = new FakeDevice();
    device.failRelease = true;
    const programmer = await new BrowserXgecuWebUSB(fakeWasm(), {
      requestDevice: vi.fn(async () => device),
      getDevices: vi.fn(async () => [device])
    }).requestProgrammer();

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
    const programmer = await api.requestProgrammer();
    const data = await api.readROM({ programmer, device: "AT28C64B", skipIdCheck: true });

    expect(data).toEqual(new Uint8Array([0x42]));
    expect(runOperation).toHaveBeenCalledOnce();
  });

  it("runs an explicit T48 pin-contact check and returns device pin numbers", async () => {
    const device = new FakeDevice();
    const wasm = fakeWasm();
    const startPinCheck = vi.spyOn(wasm, "startPinCheck");
    vi.spyOn(wasm, "runOperation").mockResolvedValue(
      new TextEncoder().encode('{"passed":false,"checkedPins":[2,3,28],"badPins":[2]}')
    );
    const api = new BrowserXgecuWebUSB(wasm, fakeUsb(device));
    const programmer = await api.requestProgrammer();

    await expect(api.checkPinContacts({ programmer, device: "AT28C64B" })).resolves.toEqual({
      passed: false,
      checkedPins: [2, 3, 28],
      badPins: [2]
    });
    expect(startPinCheck).toHaveBeenCalledWith({ programmer: "auto", device: "AT28C64B" });
  });

  it("configures and claims already-open devices before reads", async () => {
    const device = new FakeDevice();
    device.opened = true;
    const api = new BrowserXgecuWebUSB(fakeWasm(), fakeUsb(device));
    const programmer = await api.connectProgrammer(device);

    await api.readROM({ programmer, device: "AT28C64B" });

    expect(device.configuration).toEqual({ configurationValue: 1 });
    expect(device.claimInterface).toHaveBeenCalledWith(0);
  });

  it("selects configuration 1 when another configuration is active", async () => {
    const device = new FakeDevice();
    device.opened = true;
    device.configuration = { configurationValue: 2 };
    const api = new BrowserXgecuWebUSB(fakeWasm(), fakeUsb(device));
    const programmer = await api.connectProgrammer(device);

    expect(device.configuration).toEqual({ configurationValue: 1 });
    expect(device.claimInterface).toHaveBeenCalledWith(0);
    await programmer.close();
  });

  it("selects an alternate exposing the required bulk endpoints", async () => {
    const device = new FakeDevice();
    const empty = { alternateSetting: 0, endpoints: [] } as const;
    const bulk = {
      alternateSetting: 1,
      endpoints: [
        { endpointNumber: 1, direction: "in", type: "bulk" },
        { endpointNumber: 1, direction: "out", type: "bulk" },
        { endpointNumber: 2, direction: "in", type: "bulk" },
        { endpointNumber: 2, direction: "out", type: "bulk" }
      ]
    } as const;
    device.opened = true;
    device.configuration = {
      configurationValue: 1,
      interfaces: [{ interfaceNumber: 0, alternate: empty, alternates: [empty, bulk] }]
    };

    await new BrowserXgecuWebUSB(fakeWasm(), fakeUsb(device)).connectProgrammer(device);

    expect(device.selectAlternateInterface).toHaveBeenCalledWith(0, 1);
  });

  it("requires an explicit reconnect after a disconnect", async () => {
    const device = new FakeDevice();
    const api = new BrowserXgecuWebUSB(fakeWasm(), fakeUsb(device));
    const programmer = await api.connectProgrammer(device);
    device.opened = false;

    await expect(api.readROM({ programmer, device: "AT28C64B" })).rejects.toMatchObject({ code: "WebUSBLifecycleFailed" });

    expect(device.claimInterface).toHaveBeenCalledOnce();
  });

  it("keeps a shared device open until all connection wrappers close", async () => {
    const device = new FakeDevice();
    const api = new BrowserXgecuWebUSB(fakeWasm(), fakeUsb(device));
    const first = await api.connectProgrammer(device);
    const second = await api.connectProgrammer(device);

    await first.close();
    expect(device.opened).toBe(true);
    expect(device.releaseInterface).not.toHaveBeenCalled();

    await second.close();
    expect(device.opened).toBe(false);
    expect(device.releaseInterface).toHaveBeenCalledOnce();
  });

  it("rolls back a device opened before claim failure", async () => {
    const device = new FakeDevice();
    device.failClaim = true;
    const api = new BrowserXgecuWebUSB(fakeWasm(), fakeUsb(device));

    await expect(api.connectProgrammer(device)).rejects.toMatchObject({ code: "WebUSBLifecycleFailed" });
    expect(device.opened).toBe(false);
  });

  it("routes writeROM with safe defaults", async () => {
    const device = new FakeDevice();
    const wasm = fakeWasm();
    const startWriteROM = vi.spyOn(wasm, "startWriteROM");
    const runOperation = vi.spyOn(wasm, "runOperation");
    const api = new BrowserXgecuWebUSB(wasm, fakeUsb(device));
    const programmer = await api.requestProgrammer();
    const data = new Uint8Array(8192);
    data.set([0x01, 0x02]);

    await api.writeROM({ programmer, device: "AT28C64B@DIP28", data });

    expect(startWriteROM).toHaveBeenCalledWith({
      programmer: "auto",
      device: "AT28C64B@DIP28",
      memory: "code",
      data,
      erase: true,
      eraseNumFuses: 0,
      erasePld: 0,
      verify: true,
      skipIdCheck: false,
      continueOnIdMismatch: false,
      unprotectBefore: false,
      protectAfter: false
    });
    expect(runOperation).toHaveBeenCalledOnce();
  });

  it("snapshots write options and bytes before asynchronous device setup", async () => {
    const device = new FakeDevice();
    const wasm = fakeWasm();
    const startWriteROM = vi.spyOn(wasm, "startWriteROM");
    const api = new BrowserXgecuWebUSB(wasm, fakeUsb(device));
    const programmer = await api.requestProgrammer();
    const data = new Uint8Array(8192);
    data[0] = 0x12;
    const options = { programmer, device: "AT28C64B@DIP28", data, verify: true };

    const write = api.writeROM(options);
    data[0] = 0x34;
    options.device = "mutated";
    options.verify = false;
    await write;

    expect(startWriteROM).toHaveBeenCalledWith(expect.objectContaining({
      device: "AT28C64B@DIP28",
      verify: true,
      data: expect.any(Uint8Array)
    }));
    expect(vi.mocked(startWriteROM).mock.calls[0][0].data[0]).toBe(0x12);
  });

  it("rejects oversized writeROM data before starting Wasm operation", async () => {
    const device = new FakeDevice();
    const wasm = fakeWasm();
    const startWriteROM = vi.spyOn(wasm, "startWriteROM");
    const api = new BrowserXgecuWebUSB(wasm, fakeUsb(device));
    const programmer = await api.requestProgrammer();

    await expect(api.writeROM({ programmer, device: "AT28C64B@DIP28", data: new Uint8Array(8193) })).rejects.toMatchObject({ code: "InputTooLarge" });
    expect(startWriteROM).not.toHaveBeenCalled();
  });

  it("rejects partial writeROM data when erase is enabled", async () => {
    const device = new FakeDevice();
    const wasm = fakeWasm();
    const startWriteROM = vi.spyOn(wasm, "startWriteROM");
    const api = new BrowserXgecuWebUSB(wasm, fakeUsb(device));
    const programmer = await api.requestProgrammer();

    await expect(api.writeROM({ programmer, device: "AT28C64B@DIP28", data: new Uint8Array([0x01]) })).rejects.toMatchObject({ code: "InputTooLarge" });
    expect(startWriteROM).not.toHaveBeenCalled();
  });

  it("rejects electrical erase for externally erased targets", async () => {
    const device = new FakeDevice();
    const wasm = fakeWasm();
    vi.spyOn(wasm, "resolveDevice").mockReturnValue({
      ...fakeDeviceSummary(),
      name: "M27C64A@DIP28",
      aliases: ["M27C64A"],
      canErase: false
    });
    const startWriteROM = vi.spyOn(wasm, "startWriteROM");
    const api = new BrowserXgecuWebUSB(wasm, fakeUsb(device));
    const programmer = await api.requestProgrammer();
    const data = new Uint8Array(8192).fill(0xff);

    await expect(api.writeROM({ programmer, device: "M27C64A@DIP28", data })).rejects.toMatchObject({ code: "InvalidInput" });
    expect(startWriteROM).not.toHaveBeenCalled();

    await api.writeROM({ programmer, device: "M27C64A@DIP28", data, erase: false });
    expect(startWriteROM).toHaveBeenCalledWith(expect.objectContaining({ erase: false }));
  });

  it("rejects unsupported protection requests before starting Wasm", async () => {
    const device = new FakeDevice();
    const wasm = fakeWasm();
    vi.spyOn(wasm, "resolveDevice").mockReturnValue({
      ...fakeDeviceSummary(),
      aliases: ["AT28C64B"],
      supportsUnprotect: false,
      supportsProtect: false
    });
    const startWriteROM = vi.spyOn(wasm, "startWriteROM");
    const api = new BrowserXgecuWebUSB(wasm, fakeUsb(device));
    const programmer = await api.requestProgrammer();

    await expect(api.writeROM({
      programmer,
      device: "AT28C64B",
      data: new Uint8Array(8192),
      unprotectBefore: true
    })).rejects.toMatchObject({ code: "ProtectionUnsupported" });
    expect(startWriteROM).not.toHaveBeenCalled();
  });

  it("rejects erase writes outside code memory", async () => {
    const device = new FakeDevice();
    const wasm = fakeWasm();
    vi.spyOn(wasm, "resolveDevice").mockReturnValue({ ...fakeDeviceSummary(), aliases: ["AT28C64B"], dataMemorySize: 8 });
    const api = new BrowserXgecuWebUSB(wasm, fakeUsb(device));
    const programmer = await api.connectProgrammer(device);

    await expect(api.writeROM({ programmer, device: "AT28C64B", memory: "data", data: new Uint8Array(8) })).rejects.toMatchObject({ code: "InvalidInput" });
  });

  it("rejects empty writeROM data before starting Wasm operation", async () => {
    const device = new FakeDevice();
    const wasm = fakeWasm();
    const startWriteROM = vi.spyOn(wasm, "startWriteROM");
    const api = new BrowserXgecuWebUSB(wasm, fakeUsb(device));
    const programmer = await api.requestProgrammer();

    await expect(api.writeROM({ programmer, device: "AT28C64B@DIP28", data: new Uint8Array() })).rejects.toThrow("must not be empty");
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
    const programmer = await api.requestProgrammer();

    const first = api.readROM({ programmer, device: "AT28C64B" });
    await expect(api.readROM({ programmer, device: "AT28C64B" })).rejects.toMatchObject({ code: "OperationInProgress" });
    release();
    await first;
  });

  it("rejects close while a ROM operation is active", async () => {
    const device = new FakeDevice();
    let release!: () => void;
    const wasm = fakeWasm();
    vi.spyOn(wasm, "runOperation").mockImplementation(() => new Promise<Uint8Array>((resolve) => {
      release = () => resolve(new Uint8Array([0x42]));
    }));
    const api = new BrowserXgecuWebUSB(wasm, fakeUsb(device));
    const programmer = await api.connectProgrammer(device);

    const read = api.readROM({ programmer, device: "AT28C64B" });
    await expect(programmer.close()).rejects.toMatchObject({ code: "OperationInProgress" });
    expect(device.opened).toBe(true);
    release();
    await read;
    await programmer.close();
  });

  it("rejects connect while a ROM operation is active", async () => {
    const device = new FakeDevice();
    let release!: () => void;
    const wasm = fakeWasm();
    vi.spyOn(wasm, "runOperation").mockImplementation(() => new Promise<Uint8Array>((resolve) => {
      release = () => resolve(new Uint8Array([0x42]));
    }));
    const api = new BrowserXgecuWebUSB(wasm, fakeUsb(device));
    const programmer = await api.connectProgrammer(device);

    const read = api.readROM({ programmer, device: "AT28C64B" });
    await expect(api.connectProgrammer(device)).rejects.toMatchObject({ code: "OperationInProgress" });
    release();
    await read;
  });

  it("rejects operations through a closed connection", async () => {
    const device = new FakeDevice();
    const api = new BrowserXgecuWebUSB(fakeWasm(), fakeUsb(device));
    const programmer = await api.connectProgrammer(device);
    await programmer.close();

    await expect(api.readROM({ programmer, device: "AT28C64B" })).rejects.toMatchObject({ code: "WebUSBLifecycleFailed" });
    expect(device.opened).toBe(false);
  });

  it("rejects structurally forged connection wrappers", async () => {
    const device = new FakeDevice();
    const api = new BrowserXgecuWebUSB(fakeWasm(), fakeUsb(device));
    const forged = {
      device,
      vendorId: device.vendorId,
      productId: device.productId,
      opened: false,
      close: async () => undefined
    };

    await expect(api.readROM({ programmer: forged, device: "AT28C64B" })).rejects.toMatchObject({ code: "WebUSBLifecycleFailed" });
    expect(device.opened).toBe(false);
  });

  it("rejects malformed runtime safety options", async () => {
    const device = new FakeDevice();
    const wasm = fakeWasm();
    const api = new BrowserXgecuWebUSB(wasm, fakeUsb(device));
    const programmer = await api.connectProgrammer(device);

    await expect(api.writeROM({ programmer, device: "AT28C64B", data: new Uint8Array(8192), skipIdCheck: "false" } as never)).rejects.toMatchObject({ code: "InvalidInput" });
    await expect(api.writeROM({ programmer, device: "AT28C64B", data: new Uint8Array(8192), eraseNumFuses: 1.5 })).rejects.toMatchObject({ code: "InvalidInput" });
  });

  it("does not open a device for a pre-aborted operation", async () => {
    const device = new FakeDevice();
    const api = new BrowserXgecuWebUSB(fakeWasm(), fakeUsb(device));
    const programmer = await api.connectProgrammer(device);
    const controller = new AbortController();
    controller.abort();

    await expect(api.readROM({ programmer, device: "AT28C64B", signal: controller.signal })).rejects.toMatchObject({ code: "OperationAborted" });
    expect(device.opened).toBe(true);
    expect(device.claimInterface).toHaveBeenCalledOnce();
  });

  it("closes and quarantines a programmer when transaction cleanup fails", async () => {
    const device = new FakeDevice();
    const wasm = fakeWasm();
    vi.spyOn(wasm, "runOperation").mockImplementation(async (_handle, _performTransfer, options) => {
      options?.onCleanupFailure?.();
      throw new WebUSBTransferError("cleanup failed");
    });
    const api = new BrowserXgecuWebUSB(wasm, fakeUsb(device));
    const programmer = await api.requestProgrammer();

    await expect(api.readROM({ programmer, device: "AT28C64B" })).rejects.toThrow("cleanup failed");
    expect(device.opened).toBe(false);
    await expect(api.readROM({ programmer, device: "AT28C64B" })).rejects.toMatchObject({ code: "WebUSBLifecycleFailed" });

    await api.connectProgrammer(device);
    expect(device.opened).toBe(true);
  });

  it("preserves quarantine when a poisoned programmer cannot be reset", async () => {
    const device = new FakeDevice();
    const wasm = fakeWasm();
    vi.spyOn(wasm, "runOperation").mockImplementation(async (_handle, _performTransfer, options) => {
      options?.onCleanupFailure?.();
      device.failClose = true;
      throw new WebUSBTransferError("cleanup failed");
    });
    const api = new BrowserXgecuWebUSB(wasm, fakeUsb(device));
    const programmer = await api.requestProgrammer();

    await expect(api.readROM({ programmer, device: "AT28C64B" })).rejects.toThrow("cleanup failed");
    expect(device.opened).toBe(true);
    await expect(api.connectProgrammer(device)).rejects.toMatchObject({ code: "WebUSBLifecycleFailed" });
    await expect(api.readROM({ programmer, device: "AT28C64B" })).rejects.toMatchObject({ code: "WebUSBLifecycleFailed" });
  });
});

function fakeWasm(): WasmBridge {
  return {
    deviceList: () => [fakeDeviceSummary()],
    resolveDevice: () => fakeDeviceSummary(),
    startPinCheck: () => 3,
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
    canErase: true,
    supportsUnprotect: true,
    supportsProtect: true,
    supportsPinCheck: true,
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

function bufferSourceBytes(data: BufferSource): Uint8Array {
  if (data instanceof ArrayBuffer) return new Uint8Array(data).slice();
  return new Uint8Array(data.buffer, data.byteOffset, data.byteLength).slice();
}
