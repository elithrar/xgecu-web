# xgecu-web

Browser WebUSB APIs for programming ROM devices with XGecu T48/T56 programmers.

This package is intentionally scoped to T48 and T56 hardware, with a Zig core, a browser-oriented Wasm ABI, and a TypeScript WebUSB API.

T56 protocol support is implemented, but the seed catalog currently contains no validated T56 device records or algorithm payloads. High-level T56 ROM operations remain unavailable until those records are added; current catalog-backed examples target T48.

## Install as a dependency

Install the tagged release directly from GitHub until the package is published to the npm registry. Run one of these commands from your application's root:

```sh
npm install "github:elithrar/xgecu-web#v0.1.0"
```

```sh
pnpm add "github:elithrar/xgecu-web#v0.1.0"
```

Both commands add `xgecu-web` to your application's dependencies and pin it to the `v0.1.0` tag.

## Build from source

Building requires Node.js 22, pnpm 9.15.4, and Zig 0.16.0. To build the tagged release:

```sh
git clone --branch v0.1.0 --depth 1 https://github.com/elithrar/xgecu-web.git
cd xgecu-web
corepack enable
pnpm install --frozen-lockfile
pnpm run build
pnpm run test
```

The browser package, TypeScript declarations, and Wasm module are written to `dist/`.

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
import { XgecuWebUSBError, createProgrammer, type ProgrammerConnection } from "xgecu-web";

const api = await createProgrammer();

const devices = api.deviceList({ search: "AT28", programmer: "t48" });
console.log(devices);

let programmer: ProgrammerConnection | undefined;
try {
  programmer = await api.requestProgrammer();
  const bytes = await api.readROM({
    programmer,
    device: "AT28C64B@DIP28",
    memory: "code",
    onProgress: ({ phase, offset, total }) => {
      console.log(`${phase}: ${offset}/${total}`);
    }
  });

  console.log(`Read ${bytes.byteLength} bytes`);
} catch (error) {
  if (error instanceof XgecuWebUSBError) {
    console.error(`${error.code}: ${error.message}`);
  }
  throw error;
} finally {
  await programmer?.close();
}
```

See `examples/react-rom-demo` for a small React-only Vite app that can connect to a programmer, read a ROM, download the readback, and write a selected binary image with target-appropriate erase behavior plus verification after a backup and image-length check.

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

- `writeROM` is always hardware-affecting and potentially destructive; `erase: true` additionally erases targets whose catalog metadata has `canErase: true`. UV EPROMs require external erasure, a blank readback, and explicit `erase: false`.
- Erase writes are restricted to code memory and require a full image exactly matching that region.
- Keep `verify: true` unless you have an external verification process.
- Read and save a backup before writing.
- Compare the patched image byte length with the readback byte length before writing.
- Confirm the exact package/adapter before writing.
- Leave chip ID checks enabled unless you have an independent target-identification step.
- Browser permission prompts only grant access to the programmer; the library cannot detect an incorrectly inserted ROM.

### Credits

See [`attributions.md`](attributions.md) for credits, including the original `minipro` library and author.
