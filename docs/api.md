# API overview

```ts
import { createProgrammer } from "@xgecu/webusb";
```

## `createProgrammer(options?)`

Loads the Wasm module and returns the browser API.

```ts
const api = await createProgrammer({
  wasmUrl: new URL("./xgecu_webusb.wasm", import.meta.url)
});
```

Omit `wasmUrl` when the bundler can resolve the package's default Wasm asset.

## `deviceList(query?)`

Returns target ROM/device metadata from the generated embedded T48/T56 catalog. The source metadata lives in `data/catalog.json`; `pnpm run generate:catalog` writes `src/catalog/generated.zig`.

```ts
const devices = api.deviceList({ search: "AT28", programmer: "t48", limit: 20 });
```

T56 results are listed only for catalog records that include a generated T56 algorithm payload.

```ts
const t56Devices = api.deviceList({ programmer: "t56", limit: 20 });
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
  memory: "code"
});
```

The returned `Uint8Array` length is the catalogued memory size for the selected memory region.

## `writeROM(options)`

Writes a memory image to the selected target.

```ts
await api.writeROM({
  programmer,
  device: "AT28C64B@DIP28",
  data,
  erase: true,
  verify: true
});
```

`erase` and `verify` default to `true`.
`skipIdCheck` is available for bring-up or devices without catalogued IDs, but should not be enabled for normal writes.

For a complete backup-then-write browser flow, including image length checks, see `docs/examples.md`.
