# xgecu-web

Browser WebUSB APIs for programming ROM devices with XGecu T48, T56, and T76 programmers.

This package is intentionally scoped to T48, T56, and T76 hardware, with a Zig core, a browser-oriented Wasm ABI, and a TypeScript WebUSB API.

The ROM-focused catalog includes specific 28-pin EEPROM and EPROM profiles used in automotive and vintage-computing work. T56 and T76 operations require a user-supplied local algorithm source; vendor payloads are not committed, bundled, downloaded, or redistributed by this project.

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
  const contacts = await api.checkPinContacts({
    programmer,
    device: "AT28C64B@DIP28"
  });
  if (!contacts.passed) throw new Error(`Check contact on pins: ${contacts.badPins.join(", ")}`);

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

For T56 or T76, let the user select a locally obtained `algorithm.xml` and pass a provider when creating the API:

```ts
import { createAlgorithmXmlProvider, createProgrammer } from "xgecu-web";

const algorithmFile = document.querySelector<HTMLInputElement>("#algorithm-xml")?.files?.[0];
if (!algorithmFile) throw new Error("Select algorithm.xml.");
const api = await createProgrammer({
  algorithmProvider: createAlgorithmXmlProvider(await algorithmFile.text())
});
```

The provider extracts only the catalog-requested algorithm, validates its CRC, expands the programmer-specific encoding, and checks the catalog-pinned size and SHA-256. The Wasm boundary independently repeats the size and digest validation before any algorithm upload.

See `examples/react-rom-demo` for a small React-only Vite app that can connect to a programmer, check supported T48 pin contacts, read a ROM, download the readback, and write a selected binary image with target-appropriate erase behavior plus verification after a backup and image-length check.

For a complete browser example that backs up and writes a 28-pin EEPROM, see `docs/examples.md`.
See `docs/t48-review.md` for the implementation comparison, addressed findings, and remaining limits.

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

- `src/programmer/t48.zig`, `src/programmer/t56.zig`, and `src/programmer/t76.zig` contain packet-level protocol code.
- `src/programmer/transport.zig` defines the host-neutral transport interface.
- `src/ops/rom.zig` exposes high-level read/write ROM operations for Zig callers.
- `src/wasm/abi.zig` exposes a browser-oriented ABI where JavaScript drives one WebUSB transfer at a time.
- `js/src/webusb.ts` maps ABI transfer requests to `USBDevice.transferOut()` and `USBDevice.transferIn()`.
- `data/catalog.json` is the source metadata for the browser catalog.
- `tools/generate-catalog.mjs` generates `src/catalog/generated.zig` from the catalog source.
- `src/catalog/catalog.zig` provides lookup/filter helpers over the generated static catalog.

## Chip catalog

Browser builds use a static catalog generated from `data/catalog.json` into `src/catalog/generated.zig`.

Each `DeviceRecord` contains the sourced protocol, voltage, package, timing, buffer, erase, ID, and pin-map fields needed by the applicable programmer. T56 and T76 entries contain only an algorithm name, decoded size, and SHA-256 requirement. Algorithm bytes never enter the catalog or generated bundle.

To update the catalog:

```sh
pnpm run generate:catalog
pnpm run check:catalog
```

The focused catalog covers the T48-only `W27C257@DIP28` and `W27E257@DIP28` electrically erasable 32 KiB EPROMs ([sources and qualification limits](docs/winbond-27x257.md)), `AT28C64B`, `AT28C256`, manufacturer-specific `27C64`, `27C128`, `27C256`, and `27C512` profiles. Generic aliases such as `27C64` and `27C512` are intentionally rejected because voltage, ID, timing, and algorithm attributes differ across manufacturers and variants.

The existing `M27C256B@DIP28` profile covers ST's windowed `M27C256B-10F1`
and `M27C256B-12F1` speed grades. Both require external UV erase; see the
[variant evidence and workflow](docs/st-m27c256b.md).

## Hardware safety

- `writeROM` is always hardware-affecting and potentially destructive; `erase: true` additionally erases targets whose catalog metadata has `canErase: true`. UV EPROMs require external erasure and explicit `erase: false`; the write operation performs a full blank check before programming.
- Run the explicit `checkPinContacts` operation when `supportsPinCheck` is true. A passing check improves contact confidence but does not identify the chip or replace package, orientation, and adapter inspection.
- Erase writes are restricted to code memory and require a full image exactly matching that region.
- Keep `verify: true` unless you have an external verification process.
- Read and save a backup before writing.
- Compare the patched image byte length with the readback byte length before writing.
- Confirm the exact package/adapter before writing.
- Leave chip ID checks enabled unless you have an independent target-identification step.
- Apply the resolved target's explicit write-protection metadata when programming.
- Browser permission prompts only grant access to the programmer; the library cannot detect an incorrectly inserted ROM.
- T56/T76 protocol and catalog tests use deterministic software transports and golden frames. They do not constitute physical hardware qualification.

### Credits

See [`attributions.md`](attributions.md) for credits, including the original `minipro` library and author.
