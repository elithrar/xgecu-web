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
- It exposes an explicit pin-contact check for catalogued T48 targets and reports device package pins that need inspection.
- It provides a readback download link so the first backup can be saved before modification.
- It disables write when the selected image length does not match the readback length.
- It uses the target's `canErase` metadata, requires a blank readback for externally erased targets, and keeps `verify: true` explicit.
- It resets the readback/write confirmation when the selected device changes.
- Disconnect closes the programmer connection. Component unmount first aborts and waits for active work, then closes its connections.
- If USB close fails, the demo retains the connection across unmounts and disables hardware actions until **Retry disconnect** succeeds. Failed cleanup is never discarded to permit another connection.

The `skipIdCheck` checkbox is for catalog bring-up or parts without a catalogued ID. Leave it disabled for normal programming unless you have independently confirmed the chip marking, package, orientation, adapter, and image size.

Run `pnpm --filter @xgecu/react-rom-demo test` for cleanup ownership regressions using the real SDK and simulated USB. These tests do not qualify physical programmer behavior.
