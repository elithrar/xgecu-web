export type ProgrammerKind = "auto" | "t48" | "t56";
export type MemoryKind = "code" | "data" | "user";
export type ChipType = "memory" | "mcu" | "pld" | "sram" | "logic" | "nand" | "emmc" | "vga";

export interface DeviceSummary {
  name: string;
  aliases: string[];
  chipType: ChipType;
  codeMemorySize: number;
  dataMemorySize: number;
  userMemorySize: number;
  packagePins: number;
  pageSize: number;
  chipId: number;
  chipIdBytesCount: number;
  blankValue: number;
  supportsT48: boolean;
  supportsT56: boolean;
}

export type DeviceDetail = DeviceSummary;

export interface DeviceListQuery {
  search?: string;
  programmer?: ProgrammerKind;
  limit?: number;
}

export interface ProgrammerInfo {
  productName?: string;
  manufacturerName?: string;
  serialNumber?: string;
  vendorId: number;
  productId: number;
  opened: boolean;
}

export interface ProgrammerConnection extends ProgrammerInfo {
  readonly device: USBDeviceLike;
  close(): Promise<void>;
}

export interface ReadROMOptions {
  programmer: ProgrammerConnection;
  device: string;
  memory?: MemoryKind;
  programmerKind?: ProgrammerKind;
  skipIdCheck?: boolean;
  continueOnIdMismatch?: boolean;
  signal?: AbortSignal;
  onProgress?: RomProgressHandler;
}

export interface WriteROMOptions {
  programmer: ProgrammerConnection;
  device: string;
  data: Uint8Array;
  memory?: MemoryKind;
  programmerKind?: ProgrammerKind;
  erase?: boolean;
  verify?: boolean;
  skipIdCheck?: boolean;
  continueOnIdMismatch?: boolean;
  unprotectBefore?: boolean;
  protectAfter?: boolean;
  signal?: AbortSignal;
  onProgress?: RomProgressHandler;
}

export type RomOperationPhase = "connecting" | "identifying" | "erasing" | "writing" | "reading" | "verifying" | "cleanup" | "done" | "failed";

export interface RomProgressEvent {
  phase: RomOperationPhase;
  offset: number;
  total: number;
}

export type RomProgressHandler = (event: RomProgressEvent) => void;

export interface XgecuWebUSB {
  deviceList(query?: DeviceListQuery): DeviceSummary[];
  resolveDevice(name: string, programmer?: ProgrammerKind): DeviceDetail | null;
  getProgrammers(): Promise<ProgrammerInfo[]>;
  requestProgrammer(): Promise<ProgrammerConnection>;
  connectProgrammer(device: USBDeviceLike): Promise<ProgrammerConnection>;
  readROM(options: ReadROMOptions): Promise<Uint8Array>;
  writeROM(options: WriteROMOptions): Promise<void>;
}

export interface USBDeviceLike {
  readonly opened: boolean;
  readonly vendorId: number;
  readonly productId: number;
  readonly productName?: string;
  readonly manufacturerName?: string;
  readonly serialNumber?: string;
  readonly configuration: unknown | null;
  open(): Promise<void>;
  close(): Promise<void>;
  selectConfiguration(configurationValue: number): Promise<void>;
  claimInterface(interfaceNumber: number): Promise<void>;
  releaseInterface?(interfaceNumber: number): Promise<void>;
  transferOut(endpointNumber: number, data: BufferSource): Promise<USBOutTransferResultLike>;
  transferIn(endpointNumber: number, length: number): Promise<USBInTransferResultLike>;
}

export interface USBOutTransferResultLike {
  readonly status: "ok" | "stall" | "babble";
  readonly bytesWritten?: number;
}

export interface USBInTransferResultLike {
  readonly status: "ok" | "stall" | "babble";
  readonly data?: DataView;
}

export interface USBNavigatorLike {
  requestDevice(options: { filters: Array<{ vendorId: number; productId?: number }> }): Promise<USBDeviceLike>;
  getDevices(): Promise<USBDeviceLike[]>;
}

declare global {
  interface Navigator {
    usb?: USBNavigatorLike;
  }
}
