# API overview

The package exposes a high-level browser API plus lower-level WebUSB/Wasm helpers for tests and custom integrations.

```ts
import { createProgrammer, XgecuWebUSBError, type ProgrammerConnection } from "xgecu-web";
```

High-level API methods return plain values and throw package-owned `XgecuWebUSBError` objects for expected WebUSB, catalog, and programmer errors. The error object includes a stable `code` for UI branching.

## Core types

```ts
type ProgrammerKind = "auto" | "t48" | "t56";
type MemoryKind = "code" | "data" | "user";

interface DeviceSummary {
  name: string;
  aliases: string[];
  chipType: "memory" | "mcu" | "pld" | "sram" | "logic" | "nand" | "emmc" | "vga";
  codeMemorySize: number;
  dataMemorySize: number;
  userMemorySize: number;
  packagePins: number;
  pageSize: number;
  chipId: number;
  chipIdBytesCount: number;
  blankValue: number;
  canErase: boolean;
  supportsT48: boolean;
  supportsT56: boolean;
}
```

`programmerKind` defaults to `"auto"` for ROM operations. `memory` defaults to `"code"`.

## Error handling

Catch `XgecuWebUSBError` around user-initiated operations and branch on `code` for app UI:

```ts
let programmer: ProgrammerConnection | undefined;
try {
  programmer = await api.requestProgrammer();
  const bytes = await api.readROM({ programmer, device: "AT28C64B@DIP28" });
  console.log(bytes.byteLength);
} catch (error) {
  if (error instanceof XgecuWebUSBError) {
    switch (error.code) {
      case "ChipIdMismatch":
        // Prompt the user to re-check the chip marking, package, orientation, and catalog entry.
        break;
      case "OperationInProgress":
        // Disable duplicate buttons while the current operation finishes.
        break;
      case "OperationAborted":
        // User-initiated cancellation.
        break;
      default:
        console.error(error.code, error.message);
    }
  } else {
    throw error;
  }
} finally {
  await programmer?.close();
}
```

Common codes include `WebUSBUnavailable`, `WebUSBTransferFailed`, `WebUSBLifecycleFailed`, `UnsupportedProgrammer`, `ProgrammerMismatch`, `ProgrammerInBootloader`, `DeviceNotFound`, `ChipIdMismatch`, `Overcurrent`, `ProgrammerStatusError`, `VerifyFailed`, `AlgorithmUnavailable`, `InputTooLarge`, `InvalidInput`, `EmptyMemoryRegion`, `OperationInProgress`, `OperationAborted`, and `ShortRead`.

## `createProgrammer(options?)`

Loads the Wasm module and returns the high-level browser API.

```ts
const api = await createProgrammer({
  wasmUrl: new URL("./xgecu_web.wasm", import.meta.url)
});
```

Omit `wasmUrl` when the bundler can resolve the package's default Wasm asset.
For bundlers that prefer package subpaths, use:

```ts
const api = await createProgrammer({
  wasmUrl: new URL("xgecu-web/xgecu_web.wasm", import.meta.url)
});
```

Use `usb` to inject a WebUSB-compatible object in tests:

```ts
const api = await createProgrammer({ usb: fakeUsb });
```

## `deviceList(query?)`

Returns target ROM/device metadata from the generated embedded T48/T56 catalog. The source metadata lives in `data/catalog.json`; `pnpm run generate:catalog` writes `src/catalog/generated.zig`.

```ts
const devices = api.deviceList({ search: "AT28", programmer: "t48", limit: 20 });
```

T56 results are listed only for catalog records that include a generated T56 algorithm payload.

```ts
const t56Devices = api.deviceList({ programmer: "t56", limit: 20 });
```

`search` defaults to an empty string, `programmer` defaults to `"auto"`, and `limit` defaults to `100`.

## `getProgrammers()`

Returns already-authorized WebUSB devices matching the XGecu USB ID. This does not show a chooser.

```ts
const programmers = await api.getProgrammers();
for (const programmer of programmers) {
  console.log(programmer.productName, programmer.opened);
}
```

Use `connectProgrammer(device)` with a `USBDevice` returned by `navigator.usb.getDevices()` when you want to reconnect without showing the chooser.

```ts
if (!navigator.usb) throw new Error("WebUSB is unavailable.");
const authorized = await navigator.usb.getDevices();
const existing = authorized.find((device) => device.vendorId === 0xa466 && device.productId === 0x0a53);
if (existing) {
  const programmer = await api.connectProgrammer(existing);
  try {
    // Use programmer with readROM/writeROM.
  } finally {
    await programmer.close();
  }
}
```

## `resolveDevice(name, programmer?)`

Resolves a canonical name or alias through the embedded catalog and returns full device metadata.

```ts
const target = api.resolveDevice("AT28C64B", "t48");
if (!target) throw new Error("Target is not in the catalog.");
console.log(target.canErase); // Programmer-issued electrical erase support.
```

## `requestProgrammer()`

Shows the WebUSB chooser for supported XGecu USB IDs, opens the selected device, and claims interface 0.

Close the returned connection when your app is done with the programmer:

```ts
const programmer = await api.requestProgrammer();
try {
  // readROM or writeROM calls
} finally {
  await programmer.close();
}
```

## `readROM(options)`

Reads a memory region from the selected target.

```ts
const data = await api.readROM({
  programmer,
  device: "AT28C64B@DIP28",
  memory: "code",
  programmerKind: "t48",
  skipIdCheck: false,
  continueOnIdMismatch: false,
  signal: abortController.signal,
  onProgress: (event) => console.log(event.phase, event.offset, event.total)
});
```

The returned `Uint8Array` length is the catalogued memory size for the selected memory region.
Leave `skipIdCheck` at its default `false` unless you have an independent target-identification step.
Pass an `AbortSignal` as `signal` to cancel before the next USB transfer.
Progress callbacks are emitted when the public phase, offset, or total changes; internal USB transfers that leave all three values unchanged do not produce duplicate events.

## `writeROM(options)`

Writes a memory image to the selected target. `data` must be a non-empty `Uint8Array`.
Always read and save a backup before writing, and compare the image length to the readback length before calling `writeROM`.

```ts
const abortController = new AbortController();
const fileInput = document.querySelector<HTMLInputElement>("#rom-image")!;
const selectedImage = fileInput.files?.[0];
if (!selectedImage) throw new Error("Choose an image first.");
const data = new Uint8Array(await selectedImage.arrayBuffer());
const original = await api.readROM({
  programmer,
  device: "AT28C64B@DIP28",
  memory: "code",
  programmerKind: "t48"
});

if (data.byteLength !== original.byteLength) {
  throw new Error(`Image size mismatch: expected ${original.byteLength} bytes, got ${data.byteLength}.`);
}

const backupBytes = new Uint8Array(original).buffer;
const backupUrl = URL.createObjectURL(new Blob([backupBytes], { type: "application/octet-stream" }));
const backupLink = document.createElement("a");
backupLink.href = backupUrl;
backupLink.download = "AT28C64B-original.bin";
backupLink.click();
URL.revokeObjectURL(backupUrl);

if (!window.confirm("Confirm the backup was saved and the chip marking, package, orientation, and adapter are correct.")) {
  throw new Error("Write cancelled.");
}

await api.writeROM({
  programmer,
  device: "AT28C64B@DIP28",
  data,
  memory: "code",
  programmerKind: "t48",
  erase: true,
  eraseNumFuses: 0,
  erasePld: 0,
  verify: true,
  skipIdCheck: false,
  continueOnIdMismatch: false,
  unprotectBefore: false,
  protectAfter: false,
  signal: abortController.signal,
  onProgress: (event) => console.log(event.phase, event.offset, event.total)
});
```

`erase` and `verify` default to `true`. Empty write data is rejected before any WebUSB operation starts. Because the protocol erase command does not identify a memory region, erase writes are restricted to `memory: "code"` and `data` must exactly match the code-memory size. Data/user-memory and other partial programming require explicit `erase: false`.
`DeviceSummary.canErase` reports whether the programmer can electrically erase the target. `writeROM` rejects erase requests when it is false. A UV EPROM must be externally erased, read back as entirely `blankValue`, and written with `erase: false`.
`skipIdCheck` is available for bring-up or devices without catalogued IDs, but should not be enabled for normal writes.
`eraseNumFuses` and `erasePld` default to `0`; most ROM workflows should leave them at the default unless catalog/protocol work for a specific target requires non-zero values.
Hardware-affecting options are runtime-validated. Unknown enum values, non-boolean flags, and fuse/PLD values outside the integer range 0-255 throw `InvalidInput` before USB work begins.
Protected flash workflows can opt into `unprotectBefore` and `protectAfter` when the chip and catalog flags require it.
Only one ROM operation may be active per physical programmer; overlapping calls and connection closes throw `OperationInProgress`.

For a complete backup-then-write browser flow, including image length checks, see `docs/examples.md`.

## Lower-level exports

Most applications should use `createProgrammer()`. The package also exports:

- `WasmBridge` for direct access to the Wasm ABI and operation state machine.
- `BrowserXgecuWebUSB` and `WebUSBProgrammerConnection` for custom construction.
- `performWebUSBTransfer()` for mapping a Wasm transfer request to `USBDevice.transferOut()`/`transferIn()`.
- Error classes: `XgecuWebUSBError`, `WebUSBUnavailableError`, and `WebUSBTransferError`.

`WasmBridge.runOperation()` always destroys the Wasm operation handle in a `finally` block. If a transfer fails, the high-level API surfaces either a `WebUSBTransferError` or an `XgecuWebUSBError` with the Wasm error text.
