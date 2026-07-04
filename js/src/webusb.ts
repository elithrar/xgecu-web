import { Result } from "better-result";
import type { Result as BetterResult } from "better-result";
import { WebUSBTransferError, WebUSBUnavailableError, XgecuWebUSBError, xgecuErrorFromUnknown } from "./errors";
import type {
  DeviceDetail,
  DeviceListQuery,
  DeviceSummary,
  ProgrammerConnection,
  ProgrammerInfo,
  ReadROMOptions,
  USBDeviceLike,
  USBNavigatorLike,
  WriteROMOptions,
  XgecuWebUSB
} from "./types";
import { WasmBridge } from "./wasm";
import type { UsbTransfer } from "./wasm";

const XGECU_VENDOR_ID = 0xa466;
const XGECU_PRODUCT_ID = 0x0a53;
const INTERFACE_NUMBER = 0;
const DEFAULT_CONFIGURATION = 1;
const claimedDevices = new WeakSet<USBDeviceLike>();
const activeOperations = new WeakSet<USBDeviceLike>();

export class WebUSBProgrammerConnection implements ProgrammerConnection {
  constructor(readonly device: USBDeviceLike) {}

  get opened(): boolean {
    return this.device.opened;
  }

  get vendorId(): number {
    return this.device.vendorId;
  }

  get productId(): number {
    return this.device.productId;
  }

  get productName(): string | undefined {
    return this.device.productName;
  }

  get manufacturerName(): string | undefined {
    return this.device.manufacturerName;
  }

  get serialNumber(): string | undefined {
    return this.device.serialNumber;
  }

  async close(): Promise<void> {
    if (!this.device.opened) return;
    try {
      if (claimedDevices.has(this.device)) await this.device.releaseInterface?.(INTERFACE_NUMBER);
    } catch {
      // Closing is the cleanup path; a stale claimed-interface state should not keep the device open.
    } finally {
      claimedDevices.delete(this.device);
      await this.device.close();
    }
  }
}

export class BrowserXgecuWebUSB implements XgecuWebUSB {
  constructor(
    private readonly wasm: WasmBridge,
    private readonly usb: USBNavigatorLike = requireWebUSB()
  ) {}

  deviceList(query: DeviceListQuery = {}): DeviceSummary[] {
    return unwrapInternal(resultFromThrowable(() => this.wasm.deviceList(query)));
  }

  resolveDevice(name: string, programmer: DeviceListQuery["programmer"] = "auto"): DeviceDetail | null {
    return unwrapInternal(resultFromThrowable(() => this.wasm.resolveDevice(name, programmer)));
  }

  async getProgrammers(): Promise<ProgrammerInfo[]> {
    return unwrapInternal(await resultFromPromise(async () => {
      const devices = await this.usb.getDevices();
      return devices.filter(isSupportedUsbId).map(deviceInfo);
    }));
  }

  async requestProgrammer(): Promise<ProgrammerConnection> {
    return unwrapInternal(await resultFromPromise(async () => {
      const device = await this.usb.requestDevice({
        filters: [{ vendorId: XGECU_VENDOR_ID, productId: XGECU_PRODUCT_ID }]
      });
      if (!isSupportedUsbId(device)) {
        throw new XgecuWebUSBError("Selected USB device is not a supported T48/T56 programmer.", "UnsupportedProgrammer");
      }
      await openAndClaim(device);
      return new WebUSBProgrammerConnection(device);
    }));
  }

  async connectProgrammer(device: USBDeviceLike): Promise<ProgrammerConnection> {
    return unwrapInternal(await resultFromPromise(async () => {
      if (!isSupportedUsbId(device)) {
        throw new XgecuWebUSBError("USB device is not a supported T48/T56 programmer.", "UnsupportedProgrammer");
      }
      await openAndClaim(device);
      return new WebUSBProgrammerConnection(device);
    }));
  }

  async readROM(options: ReadROMOptions): Promise<Uint8Array> {
    return withProgrammerOperation(options.programmer.device, async () => {
      await ensureReady(options.programmer.device);
      const handle = this.wasm.startReadROM({
        programmer: options.programmerKind ?? "auto",
        device: options.device,
        memory: options.memory ?? "code",
        skipIdCheck: options.skipIdCheck ?? false,
        continueOnIdMismatch: options.continueOnIdMismatch ?? false
      });
      return this.wasm.runOperation(handle, (transfer) => performWebUSBTransfer(options.programmer.device, transfer), {
        signal: options.signal,
        onProgress: options.onProgress
      });
    });
  }

  async writeROM(options: WriteROMOptions): Promise<void> {
    if (options.data.byteLength === 0) throw new XgecuWebUSBError("writeROM data must not be empty.", "InputTooLarge");
    return withProgrammerOperation(options.programmer.device, async () => {
      await ensureReady(options.programmer.device);
      const handle = this.wasm.startWriteROM({
        programmer: options.programmerKind ?? "auto",
        device: options.device,
        memory: options.memory ?? "code",
        data: options.data,
        erase: options.erase ?? true,
        verify: options.verify ?? true,
        skipIdCheck: options.skipIdCheck ?? false,
        continueOnIdMismatch: options.continueOnIdMismatch ?? false,
        unprotectBefore: options.unprotectBefore ?? false,
        protectAfter: options.protectAfter ?? false
      });
      await this.wasm.runOperation(handle, (transfer) => performWebUSBTransfer(options.programmer.device, transfer), {
        signal: options.signal,
        onProgress: options.onProgress
      });
    });
  }
}

export async function createProgrammer(options: { wasmUrl?: string | URL; usb?: USBNavigatorLike } = {}): Promise<XgecuWebUSB> {
  return unwrapInternal(await resultFromPromise(async () => {
    const wasm = await WasmBridge.load(options.wasmUrl);
    return new BrowserXgecuWebUSB(wasm, options.usb ?? requireWebUSB());
  }));
}

export async function performWebUSBTransfer(device: USBDeviceLike, transfer: UsbTransfer): Promise<Uint8Array | void> {
  if (transfer.direction === "out") {
    const result = await device.transferOut(transfer.endpoint, toArrayBuffer(transfer.data));
    if (result.status !== "ok") throw new WebUSBTransferError(`USB transferOut(${transfer.endpoint}) failed with ${result.status}.`);
    if (result.bytesWritten != null && result.bytesWritten !== transfer.data.byteLength) {
      throw new WebUSBTransferError(`USB transferOut(${transfer.endpoint}) wrote ${result.bytesWritten} of ${transfer.data.byteLength} bytes.`);
    }
    return;
  }

  const result = await device.transferIn(transfer.endpoint, transfer.length);
  if (result.status !== "ok") throw new WebUSBTransferError(`USB transferIn(${transfer.endpoint}) failed with ${result.status}.`);
  if (!result.data) throw new WebUSBTransferError(`USB transferIn(${transfer.endpoint}) returned no data.`);
  if (result.data.byteLength < transfer.length) {
    throw new WebUSBTransferError(`USB transferIn(${transfer.endpoint}) returned ${result.data.byteLength} of ${transfer.length} bytes.`);
  }
  return new Uint8Array(result.data.buffer, result.data.byteOffset, result.data.byteLength).slice();
}

function toArrayBuffer(bytes: Uint8Array): ArrayBuffer {
  const copy = new Uint8Array(bytes.byteLength);
  copy.set(bytes);
  return copy.buffer;
}

async function ensureReady(device: USBDeviceLike): Promise<void> {
  await openAndClaim(device);
}

async function openAndClaim(device: USBDeviceLike): Promise<void> {
  if (!device.opened) await lifecycle("open USB device", () => device.open());
  if (device.configuration == null) await lifecycle("select USB configuration 1", () => device.selectConfiguration(DEFAULT_CONFIGURATION));
  if (!claimedDevices.has(device)) {
    await lifecycle("claim USB interface 0", () => device.claimInterface(INTERFACE_NUMBER));
    claimedDevices.add(device);
  }
}

function requireWebUSB(): USBNavigatorLike {
  if (typeof navigator === "undefined" || !navigator.usb) throw new WebUSBUnavailableError();
  return navigator.usb;
}

function isSupportedUsbId(device: Pick<USBDeviceLike, "vendorId" | "productId">): boolean {
  return device.vendorId === XGECU_VENDOR_ID && device.productId === XGECU_PRODUCT_ID;
}

function deviceInfo(device: USBDeviceLike): ProgrammerInfo {
  return {
    productName: device.productName,
    manufacturerName: device.manufacturerName,
    serialNumber: device.serialNumber,
    vendorId: device.vendorId,
    productId: device.productId,
    opened: device.opened
  };
}

async function withProgrammerOperation<T>(device: USBDeviceLike, task: () => Promise<T>): Promise<T> {
  if (activeOperations.has(device)) {
    throw new XgecuWebUSBError("A ROM operation is already in progress for this programmer.", "OperationInProgress");
  }
  activeOperations.add(device);
  try {
    return unwrapInternal(Result.ok(await task()));
  } catch (error) {
    throw unwrapInternal(Result.err(xgecuErrorFromUnknown(error)));
  } finally {
    activeOperations.delete(device);
  }
}

async function resultFromPromise<T>(task: () => Promise<T>): Promise<BetterResult<T, XgecuWebUSBError>> {
  try {
    return Result.ok(await task());
  } catch (error) {
    return Result.err(xgecuErrorFromUnknown(error));
  }
}

function resultFromThrowable<T>(task: () => T): BetterResult<T, XgecuWebUSBError> {
  try {
    return Result.ok(task());
  } catch (error) {
    return Result.err(xgecuErrorFromUnknown(error));
  }
}

function unwrapInternal<T>(result: BetterResult<T, XgecuWebUSBError>): T {
  if (result.status === "error") throw result.error;
  return result.value;
}

async function lifecycle(action: string, task: () => Promise<void>): Promise<void> {
  try {
    await task();
  } catch (error) {
    throw new XgecuWebUSBError(`Failed to ${action}.`, "WebUSBLifecycleFailed", error);
  }
}
