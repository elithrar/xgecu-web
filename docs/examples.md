# Examples

These examples are written as browser application code. WebUSB requires a secure context, so run them on `https://` or `localhost` in a Chromium-based browser.

## 28-pin EEPROM backup and write

This example uses the catalogued `AT28C64B@DIP28` target as a concrete 28-pin EEPROM workflow. Use it as a template for an automotive ECU EEPROM workflow only after confirming the exact chip marking and package on the device. A 28-pin package does not guarantee that the part is an AT28C64B or that the programming voltages/pinout are compatible.

```ts
import { createProgrammer } from "xgecu-web";

const targetDevice = "AT28C64B@DIP28";

const api = await createProgrammer();

// Catalog queries are synchronous because the catalog is embedded in Wasm.
// This should include AT28C64B@DIP28 with the current seed catalog.
const matches = api.deviceList({ search: "AT28", programmer: "t48", limit: 10 });
const target = matches.find((device) => device.name === targetDevice);
if (!target) {
  throw new Error(`${targetDevice} is not in the generated catalog.`);
}
if (target.packagePins !== 28) {
  throw new Error(`${targetDevice} is catalogued as ${target.packagePins} pins, not 28.`);
}

// Shows the browser's WebUSB chooser, opens the selected programmer, and
// claims interface 0.
const programmer = await api.requestProgrammer();

try {
  // Always read and save a backup before writing an automotive EEPROM.
  const original = await api.readROM({
    programmer,
    device: targetDevice,
    memory: "code"
  });

  downloadBytes(original, "911-eeprom-original.bin");

  // Wire this to an <input type="file"> in your app.
  const input = document.querySelector<HTMLInputElement>("#patched-rom")!;
  const selected = input.files?.[0];
  if (!selected) throw new Error("Choose a patched EEPROM image first.");

  const patched = new Uint8Array(await selected.arrayBuffer());
  if (patched.byteLength !== original.byteLength) {
    throw new Error(`Image size mismatch: expected ${original.byteLength} bytes, got ${patched.byteLength}.`);
  }

  await api.writeROM({
    programmer,
    device: targetDevice,
    memory: "code",
    data: patched,
    erase: true,
    verify: true
  });

  console.log("EEPROM write and verify completed.");
} finally {
  await programmer.close();
}

function downloadBytes(bytes: Uint8Array, filename: string): void {
  const buffer = new ArrayBuffer(bytes.byteLength);
  const copy = new Uint8Array(buffer);
  copy.set(bytes);

  const url = URL.createObjectURL(new Blob([buffer], { type: "application/octet-stream" }));
  const anchor = document.createElement("a");
  anchor.href = url;
  anchor.download = filename;
  anchor.click();
  setTimeout(() => URL.revokeObjectURL(url), 0);
}
```

Minimal HTML for the patched image input:

```html
<input id="patched-rom" type="file" accept=".bin,application/octet-stream" />
```

Keep these checks in your app:

- Match the catalog entry to the chip marking and package before calling `writeROM`.
- Keep `verify: true`.
- Compare the patched image length to the readback length before writing.
- Do not set `skipIdCheck` unless the catalog lacks an ID for the exact chip and you have another way to confirm the device.
- If your chip is not listed by `deviceList`, add it to `data/catalog.json`, run `pnpm run generate:catalog`, and run `pnpm run check:catalog`.
