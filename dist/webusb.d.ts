import { DeviceDetail, DeviceListQuery, DeviceSummary, ProgrammerConnection, ProgrammerInfo, ReadROMOptions, USBDeviceLike, USBNavigatorLike, WriteROMOptions, XgecuWebUSB } from './types';
import { WasmBridge, UsbTransfer } from './wasm';
export declare class WebUSBProgrammerConnection implements ProgrammerConnection {
    readonly device: USBDeviceLike;
    private closed;
    private readonly state;
    constructor(device: USBDeviceLike);
    get opened(): boolean;
    get vendorId(): number;
    get productId(): number;
    get productName(): string | undefined;
    get manufacturerName(): string | undefined;
    get serialNumber(): string | undefined;
    get isClosed(): boolean;
    close(): Promise<void>;
}
export declare class BrowserXgecuWebUSB implements XgecuWebUSB {
    private readonly wasm;
    private readonly usb;
    constructor(wasm: WasmBridge, usb?: USBNavigatorLike);
    deviceList(query?: DeviceListQuery): DeviceSummary[];
    resolveDevice(name: string, programmer?: DeviceListQuery["programmer"]): DeviceDetail | null;
    getProgrammers(): Promise<ProgrammerInfo[]>;
    requestProgrammer(): Promise<ProgrammerConnection>;
    connectProgrammer(device: USBDeviceLike): Promise<ProgrammerConnection>;
    readROM(options: ReadROMOptions): Promise<Uint8Array>;
    writeROM(options: WriteROMOptions): Promise<void>;
}
export declare function createProgrammer(options?: {
    wasmUrl?: string | URL;
    usb?: USBNavigatorLike;
}): Promise<XgecuWebUSB>;
export declare function performWebUSBTransfer(device: USBDeviceLike, transfer: UsbTransfer): Promise<Uint8Array | void>;
//# sourceMappingURL=webusb.d.ts.map