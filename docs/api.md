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

## `deviceList(query?)`

Returns target ROM/device metadata from the embedded T48/T56 catalog.

```ts
api.deviceList({ search: "W25", programmer: "t56", limit: 20 });
```

## `requestProgrammer()`

Shows the WebUSB chooser for supported XGecu USB IDs, opens the selected device, and claims interface 0.

## `readROM(options)`

Reads a memory region from the selected target.

```ts
const data = await api.readROM({
  programmer,
  device: "AT28C64B@DIP28",
  memory: "code",
  skipIdCheck: true
});
```

## `writeROM(options)`

Writes a memory image to the selected target.

```ts
await api.writeROM({
  programmer,
  device: "AT28C64B@DIP28",
  data,
  erase: true,
  verify: true,
  skipIdCheck: true
});
```

`erase` and `verify` default to `true`.
