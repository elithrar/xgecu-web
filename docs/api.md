# API overview

The package exposes a high-level browser API plus lower-level WebUSB/Wasm helpers for tests and custom integrations.

```ts
import { createProgrammer } from "xgecu-web";
```

High-level API methods return `better-result` `Result` values for expected WebUSB, catalog, and programmer errors. Check `result.status` before using `result.value`; the error side is an `XgecuWebUSBError` with a stable `code`.

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
  supportsT48: boolean;
  supportsT56: boolean;
}
```

`programmerKind` defaults to `"auto"` for ROM operations. `memory` defaults to `"code"`.

## `createProgrammer(options?)`

Loads the Wasm module and returns the high-level browser API.

```ts
const apiResult = await createProgrammer({
  wasmUrl: new URL("./xgecu_web.wasm", import.meta.url)
});
if (apiResult.status === "error") throw apiResult.error;
const api = apiResult.value;
```

Omit `wasmUrl` when the bundler can resolve the package's default Wasm asset.
For bundlers that prefer package subpaths, use:

```ts
const wasmUrl = new URL("xgecu-web/xgecu_web.wasm", import.meta.url);
```

Use `usb` to inject a WebUSB-compatible object in tests:

```ts
const api = (await createProgrammer({ usb: fakeUsb })).unwrap();
```

## `deviceList(query?)`

Returns target ROM/device metadata from the generated embedded T48/T56 catalog. The source metadata lives in `data/catalog.json`; `pnpm run generate:catalog` writes `src/catalog/generated.zig`.

```ts
const devices = api.deviceList({ search: "AT28", programmer: "t48", limit: 20 });
if (devices.status === "error") throw devices.error;
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
if (programmers.status === "error") throw programmers.error;
for (const programmer of programmers.value) {
  console.log(programmer.productName, programmer.opened);
}
```

Use `connectProgrammer(device)` with a `USBDevice` returned by `navigator.usb.getDevices()` when you want to reconnect without showing the chooser.

## `resolveDevice(name, programmer?)`

Resolves a canonical name or alias through the embedded catalog and returns full device metadata.

```ts
const target = api.resolveDevice("AT28C64B", "t48");
if (target.status === "error") throw target.error;
if (!target.value) throw new Error("Target is not in the catalog.");
```

## `requestProgrammer()`

Shows the WebUSB chooser for supported XGecu USB IDs, opens the selected device, and claims interface 0.

Close the returned connection when your app is done with the programmer:

```ts
const requested = await api.requestProgrammer();
if (requested.status === "error") throw requested.error;
const programmer = requested.value;
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
  onProgress: (event) => console.log(event.phase, event.offset, event.total)
});
if (data.status === "error") throw data.error;
```

The returned `Uint8Array` length is the catalogued memory size for the selected memory region.
Leave `skipIdCheck` at its default `false` unless you have an independent target-identification step.
Pass an `AbortSignal` as `signal` to cancel before the next USB transfer.

## `writeROM(options)`

Writes a memory image to the selected target. `data` must be a non-empty `Uint8Array`.

```ts
const write = await api.writeROM({
  programmer,
  device: "AT28C64B@DIP28",
  data,
  memory: "code",
  programmerKind: "t48",
  erase: true,
  verify: true,
  skipIdCheck: false
});
if (write.status === "error") throw write.error;
```

`erase` and `verify` default to `true`. Empty write data is rejected before any WebUSB operation starts.
`skipIdCheck` is available for bring-up or devices without catalogued IDs, but should not be enabled for normal writes.
Protected flash workflows can opt into `unprotectBefore` and `protectAfter` when the chip and catalog flags require it.

For a complete backup-then-write browser flow, including image length checks, see `docs/examples.md`.

## Lower-level exports

Most applications should use `createProgrammer()`. The package also exports:

- `WasmBridge` for direct access to the Wasm ABI and operation state machine.
- `BrowserXgecuWebUSB` and `WebUSBProgrammerConnection` for custom construction.
- `performWebUSBTransfer()` for mapping a Wasm transfer request to `USBDevice.transferOut()`/`transferIn()`.
- Error classes: `XgecuWebUSBError`, `WebUSBUnavailableError`, and `WebUSBTransferError`.

`WasmBridge.runOperation()` always destroys the Wasm operation handle in a `finally` block. If a transfer fails, the high-level API surfaces either a `WebUSBTransferError` or an `XgecuWebUSBError` with the Wasm error text.
