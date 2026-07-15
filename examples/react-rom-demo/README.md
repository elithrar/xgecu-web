# React ROM demo

Small Vite/React browser demo for the `xgecu-web` WebUSB API.

## Run

From the repository root:

```sh
pnpm install
pnpm build
pnpm demo:dev
```

Open the Vite URL in a Chromium-based browser on `localhost`. WebUSB requires a secure context (`https://` or `localhost`).

## Safety behavior

The demo is intentionally conservative:

- It requires a successful `readROM` before write is enabled.
- It provides a readback download link so the first backup can be saved before modification.
- It disables write when the selected image length does not match the readback length.
- It uses the target's `canErase` metadata, requires a blank readback for externally erased targets, and keeps `verify: true` explicit.
- It resets the readback/write confirmation when the selected device changes.
- It closes the programmer connection when the React component unmounts.

The `skipIdCheck` checkbox is for catalog bring-up or parts without a catalogued ID. Leave it disabled for normal programming unless you have independently confirmed the chip marking, package, orientation, adapter, and image size.
