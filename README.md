# xgecu-web

Browser WebUSB APIs for programming ROM devices with XGecu T48/T56 programmers.

This package is intentionally scoped to T48 and T56 hardware, with a Zig core, a browser-oriented Wasm ABI, and a TypeScript WebUSB API.

## Install/build from source

```sh
pnpm install
pnpm build
pnpm test
```

Useful pnpm scripts:

```sh
pnpm build            # build Wasm + browser JS package
pnpm build:zig        # compile Zig library tests and Wasm module
pnpm build:wasm       # build xgecu_web.wasm
pnpm build:js         # build the TypeScript browser package
pnpm generate:catalog # regenerate src/catalog/generated.zig from data/catalog.json
pnpm check:catalog    # verify generated catalog output is up to date
pnpm test             # run Zig + JS tests
pnpm test:zig         # run Zig unit tests
pnpm test:js          # run Vitest tests
pnpm typecheck        # typecheck the TypeScript library
pnpm demo:dev         # run the React ROM demo app
pnpm demo:build       # build the React ROM demo app
pnpm demo:typecheck   # typecheck the React ROM demo app
pnpm ci               # run the local CI command set
```

The Zig library and Wasm ABI can also be built directly with Zig after the generated catalog is up to date:

```sh
pnpm run generate:catalog
zig build test
zig build wasm -Doptimize=ReleaseSmall
```

`pnpm build` runs the Wasm build first, then compiles the TypeScript browser package with Vite.

## Browser usage

WebUSB requires a Chromium-based browser and a secure context: HTTPS or `localhost`.

```ts
import { createProgrammer } from "xgecu-web";

const apiResult = await createProgrammer();
if (apiResult.status === "error") throw apiResult.error;
const api = apiResult.value;

const devices = api.deviceList({ search: "AT28", programmer: "t48" });
if (devices.status === "error") throw devices.error;
console.log(devices.value);

const requested = await api.requestProgrammer();
if (requested.status === "error") throw requested.error;
const programmer = requested.value;

try {
  const read = await api.readROM({
    programmer,
    device: "AT28C64B@DIP28",
    memory: "code"
  });
  if (read.status === "error") throw read.error;

  console.log(`Read ${read.value.byteLength} bytes`);
} finally {
  await programmer.close();
}
```

See `examples/react-rom-demo` for a small React-only Vite app that can connect to a programmer, read a ROM, download the readback, and write a selected binary image with erase + verify.

For a complete browser example that backs up and writes a 28-pin EEPROM, see `docs/examples.md`.

## Zig API

Other Zig programs can import the package module and provide their own transport:

```zig
const xgecu = @import("xgecu-zig");

const summaries = try xgecu.rom.deviceList(allocator, "AT28", .t48, 25);
defer allocator.free(summaries);

const bytes = try xgecu.rom.readROM(allocator, transport, "AT28C64B@DIP28", .{
    .programmer = .t48,
});
defer allocator.free(bytes);
```

## Architecture

- `src/programmer/t48.zig` and `src/programmer/t56.zig` contain packet-level protocol code.
- `src/programmer/transport.zig` defines the host-neutral transport interface.
- `src/ops/rom.zig` exposes high-level read/write ROM operations for Zig callers.
- `src/wasm/abi.zig` exposes a browser-oriented ABI where JavaScript drives one WebUSB transfer at a time.
- `js/src/webusb.ts` maps ABI transfer requests to `USBDevice.transferOut()` and `USBDevice.transferIn()`.
- `data/catalog.json` is the source metadata for the browser catalog.
- `tools/generate-catalog.mjs` generates `src/catalog/generated.zig` from the catalog source.
- `src/catalog/catalog.zig` provides lookup/filter helpers over the generated static catalog.

## Chip catalog

Browser builds use a static catalog generated from `data/catalog.json` into `src/catalog/generated.zig`.

Each `DeviceRecord` contains the protocol fields needed by the T48/T56 packet layer. T56 entries must also include a non-empty `t56AlgorithmHex` or `t56AlgorithmBase64` payload in the JSON source; entries without that payload do not advertise T56 support and will be rejected if a T56 programmer is auto-detected.

To update the catalog:

```sh
pnpm run generate:catalog
pnpm run check:catalog
```

The current JSON source is intentionally small seed data and should be expanded or replaced by imported T48/T56-only metadata before broad device support is published.

## Hardware safety

- `writeROM` is destructive when `erase` is enabled.
- Keep `verify: true` unless you have an external verification process.
- Prefer `readROM` first to confirm WebUSB access and target selection.
- Confirm the exact package/adapter before writing.
- Browser permission prompts only grant access to the programmer; the library cannot detect an incorrectly inserted ROM.

### Credits

See [`attributions.md`](attributions.md) for credits, including the original `minipro` library and author.
