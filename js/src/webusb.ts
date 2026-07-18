import { Result } from "better-result";
import type { Result as BetterResult } from "better-result";
import { WebUSBTransferError, WebUSBUnavailableError, XgecuWebUSBError, xgecuErrorFromUnknown } from "./errors";
import type {
  DeviceDetail,
  DeviceListQuery,
  DeviceSummary,
  PinCheckOptions,
  PinCheckResult,
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
const deviceStates = new WeakMap<USBDeviceLike, DeviceState>();

interface DeviceState {
  claimed: boolean;
  lifecycleActive: boolean;
  openedByLibrary: boolean;
  operations: number;
  poisoned: boolean;
  references: number;
  sessionEstablished: boolean;
}

export class WebUSBProgrammerConnection implements ProgrammerConnection {
  private closed = false;
  private readonly state: DeviceState;

  constructor(readonly device: USBDeviceLike) {
    this.state = stateFor(device);
    this.state.references += 1;
  }

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
    return cleanUsbString(this.device.productName);
  }

  get manufacturerName(): string | undefined {
    return cleanUsbString(this.device.manufacturerName);
  }

  get serialNumber(): string | undefined {
    return cleanUsbString(this.device.serialNumber);
  }

  get isClosed(): boolean {
    return this.closed;
  }

  async close(): Promise<void> {
    if (this.closed) return;
    if (this.state.operations !== 0) {
      throw new XgecuWebUSBError("A programmer operation is still in progress for this programmer.", "OperationInProgress");
    }
    if (this.state.lifecycleActive) {
      throw new XgecuWebUSBError("A USB lifecycle operation is already in progress for this programmer.", "OperationInProgress");
    }
    if (this.state.references > 1) {
      this.state.references -= 1;
      this.closed = true;
      return;
    }
    this.state.lifecycleActive = true;
    try {
      try {
        if (this.device.opened && this.state.claimed) await this.device.releaseInterface?.(INTERFACE_NUMBER);
      } catch {
        // Closing is the cleanup path; a stale claimed-interface state should not keep the device open.
      }
      this.state.claimed = false;
      if (this.device.opened && (this.state.openedByLibrary || this.state.poisoned)) await this.device.close();
      if (this.state.poisoned && this.device.opened) {
        throw new XgecuWebUSBError("Failed to reset the programmer after transaction cleanup failed.", "WebUSBLifecycleFailed");
      }
      this.state.openedByLibrary = false;
      this.state.references = 0;
      this.state.poisoned = false;
      this.state.sessionEstablished = false;
      this.closed = true;
    } finally {
      this.state.lifecycleActive = false;
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
      return connectionFor(device);
    }));
  }

  async connectProgrammer(device: USBDeviceLike): Promise<ProgrammerConnection> {
    return unwrapInternal(await resultFromPromise(async () => {
      if (!isSupportedUsbId(device)) {
        throw new XgecuWebUSBError("USB device is not a supported T48/T56 programmer.", "UnsupportedProgrammer");
      }
      await openAndClaim(device);
      return connectionFor(device);
    }));
  }

  async readROM(options: ReadROMOptions): Promise<Uint8Array> {
    validateConnection(options.programmer);
    validateReadOptions(options);
    throwIfAborted(options.signal);
    const operation = {
      programmer: options.programmer,
      programmerKind: options.programmerKind ?? "auto",
      device: options.device,
      memory: options.memory ?? "code",
      skipIdCheck: options.skipIdCheck ?? false,
      continueOnIdMismatch: options.continueOnIdMismatch ?? false,
      signal: options.signal,
      onProgress: options.onProgress
    } as const;
    const usbDevice = operation.programmer.device;
    return withProgrammerOperation(usbDevice, async () => {
      await ensureReady(usbDevice);
      const handle = this.wasm.startReadROM({
        programmer: operation.programmerKind,
        device: operation.device,
        memory: operation.memory,
        skipIdCheck: operation.skipIdCheck,
        continueOnIdMismatch: operation.continueOnIdMismatch
      });
      return this.wasm.runOperation(handle, (transfer) => performWebUSBTransfer(usbDevice, transfer), {
        signal: operation.signal,
        onProgress: operation.onProgress,
        onCleanupFailure: () => markProgrammerPoisoned(usbDevice)
      });
    });
  }

  async checkPinContacts(options: PinCheckOptions): Promise<PinCheckResult> {
    validateConnection(options.programmer);
    validateDeviceName(options.device);
    validateEnum(options.programmerKind, ["auto", "t48"], "programmerKind");
    throwIfAborted(options.signal);
    const programmerKind = options.programmerKind ?? "auto";
    const usbDevice = options.programmer.device;
    return withProgrammerOperation(usbDevice, async () => {
      const device = this.wasm.resolveDevice(options.device, programmerKind);
      if (!device) throw new XgecuWebUSBError("Device not found or unsupported by requested programmer.", "DeviceNotFound");
      if (!device.supportsPinCheck) {
        throw new XgecuWebUSBError("Pin-contact checking is unavailable for this device and programmer.", "PinCheckUnavailable");
      }
      await ensureReady(usbDevice);
      const handle = this.wasm.startPinCheck({ programmer: programmerKind, device: options.device });
      const bytes = await this.wasm.runOperation(handle, (transfer) => performWebUSBTransfer(usbDevice, transfer), {
        signal: options.signal,
        onCleanupFailure: () => markProgrammerPoisoned(usbDevice)
      });
      return parsePinCheckResult(bytes);
    });
  }

  async writeROM(options: WriteROMOptions): Promise<void> {
    validateConnection(options.programmer);
    validateWriteOptions(options);
    throwIfAborted(options.signal);
    const operation = {
      programmer: options.programmer,
      programmerKind: options.programmerKind ?? "auto",
      device: options.device,
      data: options.data.slice(),
      memory: options.memory ?? "code",
      erase: options.erase ?? true,
      eraseNumFuses: options.eraseNumFuses ?? 0,
      erasePld: options.erasePld ?? 0,
      verify: options.verify ?? true,
      skipIdCheck: options.skipIdCheck ?? false,
      continueOnIdMismatch: options.continueOnIdMismatch ?? false,
      unprotectBefore: options.unprotectBefore ?? false,
      protectAfter: options.protectAfter ?? false,
      signal: options.signal,
      onProgress: options.onProgress
    } as const;
    if (operation.data.byteLength === 0) throw new XgecuWebUSBError("writeROM data must not be empty.", "InputTooLarge");
    const usbDevice = operation.programmer.device;
    return withProgrammerOperation(usbDevice, async () => {
      const device = this.wasm.resolveDevice(operation.device, operation.programmerKind);
      if (!device) throw new XgecuWebUSBError("Device not found or unsupported by requested programmer.", "DeviceNotFound");
      const size = memorySize(device, operation.memory);
      if (size === 0) throw new XgecuWebUSBError("Selected memory region is empty.", "EmptyMemoryRegion");
      if (operation.data.byteLength > size) throw new XgecuWebUSBError("writeROM data is larger than the selected memory region.", "InputTooLarge");
      if (operation.erase && operation.memory !== "code") {
        throw new XgecuWebUSBError("Erase writes are restricted to full code-memory images because erase scope is device-specific.", "InvalidInput");
      }
      if (operation.erase && operation.data.byteLength !== size) {
        throw new XgecuWebUSBError("writeROM data must match the selected memory region when erase is enabled.", "InputTooLarge");
      }
      if (operation.erase && !device.canErase) {
        throw new XgecuWebUSBError(
          "The selected device cannot be electrically erased. Externally erase and blank-check it, then write with erase: false.",
          "InvalidInput"
        );
      }
      if (operation.unprotectBefore && !device.supportsUnprotect) {
        throw new XgecuWebUSBError("The selected device does not support disabling protection before programming.", "ProtectionUnsupported");
      }
      if (operation.protectAfter && !device.supportsProtect) {
        throw new XgecuWebUSBError("The selected device does not support enabling protection after programming.", "ProtectionUnsupported");
      }
      await ensureReady(usbDevice);
      const handle = this.wasm.startWriteROM({
        programmer: operation.programmerKind,
        device: operation.device,
        memory: operation.memory,
        data: operation.data,
        erase: operation.erase,
        eraseNumFuses: operation.eraseNumFuses,
        erasePld: operation.erasePld,
        verify: operation.verify,
        skipIdCheck: operation.skipIdCheck,
        continueOnIdMismatch: operation.continueOnIdMismatch,
        unprotectBefore: operation.unprotectBefore,
        protectAfter: operation.protectAfter
      });
      await this.wasm.runOperation(handle, (transfer) => performWebUSBTransfer(usbDevice, transfer), {
        signal: operation.signal,
        onProgress: operation.onProgress,
        onCleanupFailure: () => markProgrammerPoisoned(usbDevice)
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
    let result;
    try {
      result = await device.transferOut(transfer.endpoint, toArrayBuffer(transfer.data));
    } catch (error) {
      throw new WebUSBTransferError(`USB transferOut(${transfer.endpoint}) failed.`, error);
    }
    if (result.status !== "ok") throw new WebUSBTransferError(`USB transferOut(${transfer.endpoint}) failed with ${result.status}.`);
    if (result.bytesWritten !== transfer.data.byteLength) {
      throw new WebUSBTransferError(`USB transferOut(${transfer.endpoint}) wrote ${result.bytesWritten} of ${transfer.data.byteLength} bytes.`);
    }
    return;
  }

  let result;
  try {
    result = await device.transferIn(transfer.endpoint, transfer.length);
  } catch (error) {
    throw new WebUSBTransferError(`USB transferIn(${transfer.endpoint}) failed.`, error);
  }
  if (result.status !== "ok") throw new WebUSBTransferError(`USB transferIn(${transfer.endpoint}) failed with ${result.status}.`);
  if (!result.data) throw new WebUSBTransferError(`USB transferIn(${transfer.endpoint}) returned no data.`);
  return new Uint8Array(result.data.buffer, result.data.byteOffset, result.data.byteLength).slice();
}

function toArrayBuffer(bytes: Uint8Array): ArrayBuffer {
  const copy = new Uint8Array(bytes.byteLength);
  copy.set(bytes);
  return copy.buffer;
}

async function ensureReady(device: USBDeviceLike): Promise<void> {
  await openAndClaim(device, true);
}

async function openAndClaim(device: USBDeviceLike, forOperation = false): Promise<void> {
  const state = stateFor(device);
  if (state.lifecycleActive || (!forOperation && state.operations !== 0)) {
    throw new XgecuWebUSBError("A USB lifecycle operation is already in progress for this programmer.", "OperationInProgress");
  }
  if (forOperation && !device.opened && state.sessionEstablished) {
    throw new XgecuWebUSBError("The programmer connection was lost. Reconnect before starting another operation.", "WebUSBLifecycleFailed");
  }
  if (forOperation && state.poisoned) {
    throw new XgecuWebUSBError("The programmer is in an unknown hardware state. Reconnect before starting another operation.", "WebUSBLifecycleFailed");
  }
  state.lifecycleActive = true;
  let openedHere = false;
  try {
    if (!forOperation && state.poisoned) {
      if (device.opened && state.claimed) await device.releaseInterface?.(INTERFACE_NUMBER).catch(() => undefined);
      state.claimed = false;
      if (device.opened) await lifecycle("reset the programmer after transaction cleanup failed", () => device.close());
      if (device.opened) {
        throw new XgecuWebUSBError("The programmer remained open after reset. Disconnect and reconnect it before continuing.", "WebUSBLifecycleFailed");
      }
      state.openedByLibrary = false;
      state.sessionEstablished = false;
    }
    if (!device.opened) {
      state.claimed = false;
      await lifecycle("open USB device", () => device.open());
      state.openedByLibrary = true;
      openedHere = true;
    }
    if (device.configuration?.configurationValue !== DEFAULT_CONFIGURATION) {
      await lifecycle("select USB configuration 1", () => device.selectConfiguration(DEFAULT_CONFIGURATION));
      state.claimed = false;
    }
    if (!state.claimed) {
      await lifecycle("claim USB interface 0", () => device.claimInterface(INTERFACE_NUMBER));
      state.claimed = true;
    }
    await ensureEndpointAlternate(device);
    state.poisoned = false;
    state.sessionEstablished = true;
  } catch (error) {
    if (state.claimed) await device.releaseInterface?.(INTERFACE_NUMBER).catch(() => undefined);
    state.claimed = false;
    if (openedHere && device.opened) await device.close().catch(() => undefined);
    if (openedHere) {
      state.openedByLibrary = false;
      state.sessionEstablished = false;
    }
    throw error;
  } finally {
    state.lifecycleActive = false;
  }
}

async function ensureEndpointAlternate(device: USBDeviceLike): Promise<void> {
  const interfaces = device.configuration?.interfaces;
  if (!interfaces) return;
  const usbInterface = interfaces.find((entry) => entry.interfaceNumber === INTERFACE_NUMBER);
  if (!usbInterface) throw new XgecuWebUSBError("USB configuration 1 does not expose interface 0.", "WebUSBLifecycleFailed");
  if (hasProgrammerEndpoints(usbInterface.alternate)) return;
  const alternate = usbInterface.alternates.find(hasProgrammerEndpoints) ??
    (hasCommandEndpoints(usbInterface.alternate) ? usbInterface.alternate : usbInterface.alternates.find(hasCommandEndpoints));
  if (!alternate) {
    throw new XgecuWebUSBError("USB interface 0 does not expose command endpoint 1 in both directions.", "WebUSBLifecycleFailed");
  }
  if (alternate === usbInterface.alternate) return;
  if (!device.selectAlternateInterface) {
    throw new XgecuWebUSBError("USB interface 0 requires an unsupported alternate setting.", "WebUSBLifecycleFailed");
  }
  await lifecycle("select USB interface 0 alternate", () => device.selectAlternateInterface!(INTERFACE_NUMBER, alternate.alternateSetting));
}

function hasProgrammerEndpoints(alternate: { readonly endpoints: readonly { readonly endpointNumber: number; readonly direction: "in" | "out"; readonly type: string }[] }): boolean {
  return [1, 2].every((endpointNumber) =>
    ["in", "out"].every((direction) => alternate.endpoints.some((endpoint) =>
      endpoint.endpointNumber === endpointNumber && endpoint.direction === direction && endpoint.type === "bulk"
    ))
  );
}

function hasCommandEndpoints(alternate: { readonly endpoints: readonly { readonly endpointNumber: number; readonly direction: "in" | "out"; readonly type: string }[] }): boolean {
  return ["in", "out"].every((direction) => alternate.endpoints.some((endpoint) =>
    endpoint.endpointNumber === 1 && endpoint.direction === direction && endpoint.type === "bulk"
  ));
}

function connectionFor(device: USBDeviceLike): ProgrammerConnection {
  return new WebUSBProgrammerConnection(device);
}

function stateFor(device: USBDeviceLike): DeviceState {
  let state = deviceStates.get(device);
  if (!state) {
    state = { claimed: false, lifecycleActive: false, openedByLibrary: false, operations: 0, poisoned: false, references: 0, sessionEstablished: false };
    deviceStates.set(device, state);
  }
  return state;
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
    productName: cleanUsbString(device.productName),
    manufacturerName: cleanUsbString(device.manufacturerName),
    serialNumber: cleanUsbString(device.serialNumber),
    vendorId: device.vendorId,
    productId: device.productId,
    opened: device.opened
  };
}

function cleanUsbString(value: string | undefined): string | undefined {
  if (value == null) return undefined;
  return value.split("\0", 1)[0].trim() || undefined;
}

function parsePinCheckResult(bytes: Uint8Array): PinCheckResult {
  let value: unknown;
  try {
    value = JSON.parse(new TextDecoder().decode(bytes));
  } catch (error) {
    throw new XgecuWebUSBError("The pin-contact check returned an invalid result.", "Unknown", error);
  }
  if (typeof value !== "object" || value === null) {
    throw new XgecuWebUSBError("The pin-contact check returned an invalid result.");
  }
  const result = value as Partial<PinCheckResult>;
  if (typeof result.passed !== "boolean" || !validDevicePins(result.checkedPins) || !validDevicePins(result.badPins)) {
    throw new XgecuWebUSBError("The pin-contact check returned an invalid result.");
  }
  return { passed: result.passed, checkedPins: result.checkedPins, badPins: result.badPins };
}

function validDevicePins(value: unknown): value is number[] {
  return Array.isArray(value) && value.every((pin) => Number.isInteger(pin) && pin >= 1 && pin <= 40);
}

function memorySize(device: DeviceDetail, memory: NonNullable<WriteROMOptions["memory"]>): number {
  switch (memory) {
    case "code":
      return device.codeMemorySize;
    case "data":
      return device.dataMemorySize;
    case "user":
      return device.userMemorySize;
  }
}

async function withProgrammerOperation<T>(device: USBDeviceLike, task: () => Promise<T>): Promise<T> {
  const state = stateFor(device);
  if (state.operations !== 0) {
    throw new XgecuWebUSBError("A programmer operation is already in progress for this programmer.", "OperationInProgress");
  }
  state.operations += 1;
  try {
    return unwrapInternal(Result.ok(await task()));
  } catch (error) {
    if (state.poisoned) await quarantineProgrammer(device, state);
    throw unwrapInternal(Result.err(xgecuErrorFromUnknown(error)));
  } finally {
    state.operations -= 1;
  }
}

function markProgrammerPoisoned(device: USBDeviceLike): void {
  stateFor(device).poisoned = true;
}

async function quarantineProgrammer(device: USBDeviceLike, state: DeviceState): Promise<void> {
  if (device.opened && state.claimed) await device.releaseInterface?.(INTERFACE_NUMBER).catch(() => undefined);
  if (device.opened) await device.close().catch(() => undefined);
  state.claimed = false;
  if (!device.opened) state.openedByLibrary = false;
  state.sessionEstablished = false;
}

function validateConnection(programmer: ProgrammerConnection): void {
  if (!(programmer instanceof WebUSBProgrammerConnection)) {
    throw new XgecuWebUSBError("Use WebUSBProgrammerConnection or a connection returned by the programmer API.", "WebUSBLifecycleFailed");
  }
  if (!isSupportedUsbId(programmer.device)) {
    throw new XgecuWebUSBError("USB device is not a supported T48/T56 programmer.", "UnsupportedProgrammer");
  }
  if (programmer.isClosed) {
    throw new XgecuWebUSBError("The programmer connection is closed.", "WebUSBLifecycleFailed");
  }
}

function validateDeviceName(device: unknown): asserts device is string {
  if (typeof device !== "string" || device.trim() === "") invalidInput("device must be a non-empty string");
}

function validateReadOptions(options: ReadROMOptions): void {
  validateEnum(options.programmerKind, ["auto", "t48", "t56"], "programmerKind");
  validateEnum(options.memory, ["code", "data", "user"], "memory");
  validateBooleans(options, ["skipIdCheck", "continueOnIdMismatch"]);
}

function validateWriteOptions(options: WriteROMOptions): void {
  if (!(options.data instanceof Uint8Array)) invalidInput("data must be a Uint8Array");
  validateEnum(options.programmerKind, ["auto", "t48", "t56"], "programmerKind");
  validateEnum(options.memory, ["code", "data", "user"], "memory");
  validateBooleans(options, ["erase", "verify", "skipIdCheck", "continueOnIdMismatch", "unprotectBefore", "protectAfter"]);
  validateByte(options.eraseNumFuses, "eraseNumFuses");
  validateByte(options.erasePld, "erasePld");
}

function validateEnum(value: unknown, allowed: readonly string[], name: string): void {
  if (value !== undefined && (typeof value !== "string" || !allowed.includes(value))) invalidInput(`${name} is invalid`);
}

function validateBooleans(options: object, names: readonly string[]): void {
  const values = options as Record<string, unknown>;
  for (const name of names) {
    if (values[name] !== undefined && typeof values[name] !== "boolean") invalidInput(`${name} must be a boolean`);
  }
}

function validateByte(value: unknown, name: string): void {
  if (value !== undefined && (typeof value !== "number" || !Number.isInteger(value) || value < 0 || value > 0xff)) {
    invalidInput(`${name} must be an integer from 0 to 255`);
  }
}

function invalidInput(message: string): never {
  throw new XgecuWebUSBError(message, "InvalidInput");
}

function throwIfAborted(signal: AbortSignal | undefined): void {
  if (signal?.aborted) throw new XgecuWebUSBError("Operation aborted.", "OperationAborted");
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
