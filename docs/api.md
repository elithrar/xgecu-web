# API overview

The package exposes a high-level browser API plus lower-level WebUSB/Wasm helpers for tests and custom integrations.

```ts
import { createProgrammer, XgecuWebUSBError, type ProgrammerConnection } from "xgecu-web";
```

High-level API methods return plain values and throw package-owned `XgecuWebUSBError` objects for expected WebUSB, catalog, and programmer errors. The error object includes a stable `code` for UI branching.

Internal Result handling preserves existing package error objects and wraps other
exceptions with their original `cause`. It does not expose Result or Panic as the
public error contract. Calls are single-attempt: permission requests, USB transfers,
erase/write operations, and cancellation cleanup are never automatically replayed.
After a failed close, retain the connection and explicitly retry cleanup before
reconnecting; a successful USB close does not clear hardware-cleanup quarantine.

## Core types

```ts
type ProgrammerKind = "auto" | "t48" | "t56" | "t76";
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
  supportsUnprotect: boolean;
  supportsProtect: boolean;
  supportsPinCheck: boolean;
  supportsT48: boolean;
  supportsT56: boolean;
  supportsT76: boolean;
  algorithms: readonly {
    programmer: "t56" | "t76";
    name: string;
    size: number;
    sha256: string;
  }[];
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

Common codes include `WebUSBUnavailable`, `WebUSBTransferFailed`, `WebUSBLifecycleFailed`, `UnsupportedProgrammer`, `ProgrammerMismatch`, `ProgrammerInBootloader`, `DeviceNotFound`, `ChipIdMismatch`, `Overcurrent`, `ProgrammerStatusError`, `VerifyFailed`, `TargetNotBlank`, `PinCheckUnavailable`, `ProtectionUnsupported`, `AlgorithmUnavailable`, `InvalidAlgorithm`, `InputTooLarge`, `InvalidInput`, `EmptyMemoryRegion`, `OperationInProgress`, `OperationAborted`, and `ShortRead`.

## `createProgrammer(options?)`

Loads the Wasm module and returns the high-level browser API. Initialization,
`deviceList()` and `resolveDevice()` do not require WebUSB or USB permission.
`getProgrammers()` and `requestProgrammer()` report `WebUSBUnavailable` when
the browser does not expose WebUSB.

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

T56 and T76 operations require an `AlgorithmProvider`. The package helper reads a user-selected local `algorithm.xml`; it does not upload the file or persist vendor payloads:

```ts
import { createAlgorithmXmlProvider, createProgrammer } from "xgecu-web";

const xml = await algorithmXmlFile.text();
const api = await createProgrammer({
  algorithmProvider: createAlgorithmXmlProvider(xml)
});
```

The provider and Wasm core both validate the decoded payload against the catalog requirement. Missing data throws `AlgorithmUnavailable`; a CRC, size, or SHA-256 mismatch throws `InvalidAlgorithm`.

## `deviceList(query?)`

Returns target ROM/device metadata from the generated embedded T48/T56/T76 catalog. The source metadata lives in `data/catalog.json`; `pnpm run generate:catalog` writes `src/catalog/generated.zig`.

```ts
const devices = api.deviceList({ search: "AT28", programmer: "t48", limit: 20 });
```

T56 and T76 results are listed only when the record includes the corresponding pinned algorithm requirement.

```ts
const t56Devices = api.deviceList({ programmer: "t56", limit: 20 });
const t76Devices = api.deviceList({ programmer: "t76", limit: 20 });
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

## `identifyProgrammer(programmer)`

Returns `"t48"`, `"t56"` or `"t76"` from the connected programmer's system-info
response, without starting a chip transaction. T48 and T56 share a USB product ID;
USB names and IDs alone do not identify the model. Use this before enabling
model-specific actions. This identifies the programmer, not the inserted chip.

The connection must be open and owned by this API. The query uses the same
per-device operation lock and quarantine checks as ROM operations. Unsupported,
bootloader, short, and contradictory model responses fail closed. ROM operations
still validate the model independently before accessing the chip.

```ts
const programmer = await api.requestProgrammer();
try {
  const kind = await api.identifyProgrammer(programmer);
  console.log(kind, api.resolveDevice("W27C257@DIP28", kind));
} finally {
  await programmer.close();
}
```

## `resolveDevice(name, programmer?)`

Resolves a canonical name or alias through the embedded catalog and returns full device metadata.

```ts
const target = api.resolveDevice("AT28C64B", "t48");
if (!target) throw new Error("Target is not in the catalog.");
console.log(target.canErase); // Programmer-issued electrical erase support.
console.log(target.supportsUnprotect, target.supportsProtect);
console.log(target.supportsPinCheck); // Explicit T48 contact check support.
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
Progress callbacks are emitted when the public phase, offset, or total changes; internal USB transfers that leave all three values unchanged do not produce duplicate events. Async callbacks are awaited, and a rejected callback aborts the operation.

## `checkPinContacts(options)`

Runs an explicit, non-programming contact check for catalogued T48 targets. The operation resets the pin drivers, enables input pulldowns, drives the catalogued ground pin through the T48 logic output, samples the contact mask, and resets the drivers on success or failure.

```ts
const result = await api.checkPinContacts({
  programmer,
  device: "AT28C64B@DIP28",
  programmerKind: "t48",
  signal: abortController.signal
});

if (!result.passed) {
  throw new Error(`Check contact on device pins: ${result.badPins.join(", ")}`);
}
```

`checkedPins` and `badPins` use device package pin numbers, not T48 ZIF positions. Ground and other electrically unsuitable pins are omitted from `checkedPins`. A passing result increases confidence in physical contact; it does not identify the chip or prove its orientation. The method throws `PinCheckUnavailable` for unsupported targets or non-T48 programmers and treats overcurrent as a hard failure.

## `writeROM(options)`

Writes a memory image to the selected target. `data` must be a non-empty `Uint8Array`.
Always read and save a backup before writing, and compare the image length to the readback length before calling `writeROM`.

```ts
const abortController = new AbortController();
const target = api.resolveDevice("AT28C64B@DIP28", "t48");
if (!target) throw new Error("Target is not in the catalog.");
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
  erase: target.canErase,
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

`erase` and `verify` default to `true`. T76 writes require `verify: true` because that streaming protocol has no per-block status response; explicitly disabling it throws `VerifyRequired` after programmer identification and before BEGIN. Empty write data is rejected before any WebUSB operation starts. Because the protocol erase command does not identify a memory region, erase writes are restricted to `memory: "code"` and `data` must exactly match the code-memory size. Data/user-memory and other partial programming require explicit `erase: false`. After an electrical erase, the operation reads the full selected memory region and rejects the write unless every byte equals `blankValue`.
`DeviceSummary.canErase` reports whether the programmer can electrically erase the target. `writeROM` rejects erase requests when it is false. A UV EPROM must be externally erased and written with `erase: false`; immediately before programming, the operation reads the full selected memory region and throws `TargetNotBlank` unless every byte equals `blankValue`.
Electrically erasable EPROM profiles such as W27C257 also require a blank target even with explicit `erase: false`; the catalog records this separately from erase capability. Their full selected region is checked before programming, including prefix writes. EEPROM profiles such as AT28C64B retain in-place rewriting. W27E257 is withheld pending resolution of its voltage evidence.
`skipIdCheck` is available for bring-up or devices without catalogued IDs, but should not be enabled for normal writes.
`eraseNumFuses` and `erasePld` default to `0`; most ROM workflows should leave them at the default unless catalog/protocol work for a specific target requires non-zero values.
Hardware-affecting options are runtime-validated. Unknown enum values, non-boolean flags, and fuse/PLD values outside the integer range 0-255 throw `InvalidInput` before USB work begins.
`DeviceSummary.supportsUnprotect` and `DeviceSummary.supportsProtect` report catalogued capabilities. Unsupported requests throw `ProtectionUnsupported`. Keep `protectAfter` explicit because the library does not infer prior protection state or automatically re-protect a chip after writing. T76 is the exception for pre-write unprotection: targets carrying the sourced `off_protect_before` flag are always unprotected before erase and restarted in a fresh transaction because the T76 firmware can otherwise accept the write flow without programming the target.
Only one programmer operation may be active per physical programmer; overlapping calls and connection closes throw `OperationInProgress`.

For a complete backup-then-write browser flow, including image length checks, see `docs/examples.md`.

## Lower-level exports

Most applications should use `createProgrammer()`. The package also exports:

- `WasmBridge` for direct access to the Wasm ABI and operation state machine.
- `BrowserXgecuWebUSB` and `WebUSBProgrammerConnection` for custom construction.
- `performWebUSBTransfer()` for mapping a Wasm transfer request to `USBDevice.transferOut()`/`transferIn()`.
- Error classes: `XgecuWebUSBError`, `WebUSBUnavailableError`, and `WebUSBTransferError`.

Wasm operation handles are opaque, single-use tokens owned by the creating bridge, not raw Wasm pointers. A consumed or disposed token cannot run or dispose a later operation even when the Wasm allocator reuses its address. `WasmBridge.runOperation()` rejects duplicate runners and always destroys its handle in a `finally` block. Call `disposeOperation()` for an operation that was started but will not be run. If transaction cleanup fails after an operation error, the high-level API attempts to close the USB session and quarantines that device for the page lifetime. A software reconnect cannot clear this state. Disconnect USB power, then reload the page before reconnecting; the browser cannot verify that physical power was removed.
The native Zig `Transport` vtable reports the number of bytes transferred for command and payload I/O. Its public wrappers reject short sends, writes, and reads as `transport.Error.Io`, so adapters must not report success for a partial transfer.
