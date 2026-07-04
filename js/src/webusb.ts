import { WebUSBTransferError, WebUSBUnavailableError, XgecuWebUSBError } from "./errors";
import type {
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
    await this.device.releaseInterface?.(INTERFACE_NUMBER);
    await this.device.close();
  }
}

export class BrowserXgecuWebUSB implements XgecuWebUSB {
  constructor(
    private readonly wasm: WasmBridge,
    private readonly usb: USBNavigatorLike = requireWebUSB()
  ) {}

  deviceList(query: DeviceListQuery = {}): DeviceSummary[] {
    return this.wasm.deviceList(query);
  }

  async getProgrammers(): Promise<ProgrammerInfo[]> {
    const devices = await this.usb.getDevices();
    return devices.filter(isSupportedUsbId).map(deviceInfo);
  }

  async requestProgrammer(): Promise<ProgrammerConnection> {
    const device = await this.usb.requestDevice({
      filters: [{ vendorId: XGECU_VENDOR_ID, productId: XGECU_PRODUCT_ID }]
    });
    if (!isSupportedUsbId(device)) {
      throw new XgecuWebUSBError("Selected USB device is not a supported T48/T56 programmer.");
    }
    await openAndClaim(device);
    return new WebUSBProgrammerConnection(device);
  }

  async readROM(options: ReadROMOptions): Promise<Uint8Array> {
    await ensureOpen(options.programmer.device);
    const handle = this.wasm.startReadROM({
      programmer: options.programmerKind ?? "auto",
      device: options.device,
      memory: options.memory ?? "code",
      skipIdCheck: options.skipIdCheck ?? false
    });
    return this.wasm.runOperation(handle, (transfer) => performWebUSBTransfer(options.programmer.device, transfer));
  }

  async writeROM(options: WriteROMOptions): Promise<void> {
    await ensureOpen(options.programmer.device);
    const handle = this.wasm.startWriteROM({
      programmer: options.programmerKind ?? "auto",
      device: options.device,
      memory: options.memory ?? "code",
      data: options.data,
      erase: options.erase ?? true,
      verify: options.verify ?? true,
      skipIdCheck: options.skipIdCheck ?? false
    });
    await this.wasm.runOperation(handle, (transfer) => performWebUSBTransfer(options.programmer.device, transfer));
  }
}

export async function createProgrammer(options: { wasmUrl?: string | URL; usb?: USBNavigatorLike } = {}): Promise<XgecuWebUSB> {
  const wasm = await WasmBridge.load(options.wasmUrl);
  return new BrowserXgecuWebUSB(wasm, options.usb ?? requireWebUSB());
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
  return new Uint8Array(result.data.buffer, result.data.byteOffset, result.data.byteLength).slice();
}

function toArrayBuffer(bytes: Uint8Array): ArrayBuffer {
  const copy = new Uint8Array(bytes.byteLength);
  copy.set(bytes);
  return copy.buffer;
}

async function ensureOpen(device: USBDeviceLike): Promise<void> {
  if (!device.opened) await openAndClaim(device);
}

async function openAndClaim(device: USBDeviceLike): Promise<void> {
  if (!device.opened) await device.open();
  if (device.configuration == null) await device.selectConfiguration(DEFAULT_CONFIGURATION);
  await device.claimInterface(INTERFACE_NUMBER);
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
