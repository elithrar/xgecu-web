# T56/T76 ROM Protocol Audit

Audited 2026-07-29 against draft PR [#15](https://github.com/elithrar/xgecu-web/pull/15), commit `cec804cabbd5f4fdf087cc93eea2707c7d82c015`.

## Scope and evidence

This audit covers the PR's parallel ROM path only: MiniPro protocol `0x07`, the ten 28-pin ROM/EEPROM/EPROM catalog entries, local algorithm extraction, native Zig, Wasm, and WebUSB. It does not claim general T56/T76 support for SPI, NAND, eMMC, MCU, logic, or adapter-specific protocols.

Evidence, strongest first:

- MiniPro source pinned by the generated catalog: [`a8efaedc`](https://gitlab.com/DavidGriffith/minipro/-/tree/a8efaedc236c1d9718bd28299dfbb99536b010ff). This is the byte-level reference used for the PR.
- Current MiniPro source inspected at [`cae74c06`](https://gitlab.com/DavidGriffith/minipro/-/tree/cae74c0607077d6260b24995f5e4c0d0b66a6a2e). Its newer T76 work adds model-specific protection ordering and changes several non-ROM protocols, while protocol `0x07` still uses the generic 64-byte BEGIN and bulk ROM path.
- XGecu's [download page](https://www.xgecu.com/download.html) and [official forum release thread](https://forums.xgecu.com/viewthread.php?tid=20). These show separate T56 and T76 software/catalog release trains and recurring algorithm fixes. They do not document USB packet layouts.
- Software-only packet tests in this repository. No T56 or T76 hardware trace was captured for this PR.

The official download page and forum mirror did not expose a single consistent "latest" version during this audit. Treat downloaded `algorithm.xml` files as versioned input, never as an interchangeable or stable data source.

## Protocol differences and sharp edges

| Area | T56 | T76 | Review result |
|---|---|---|---|
| USB identity | Shares VID/PID `04d8:0a53` with T48; system-info response is authoritative | Distinct PID `04d8:1a86` | Endpoint selection matches; auto mode preflights shared-PID system info before loading an algorithm |
| Endpoints | EP1 command in/out | EP1 command in/out, EP2 code read, EP5 code write | Matches MiniPro and WebUSB alternate checks |
| Algorithm format | Gzip payload is CRC-checked and padded to the next 512-byte boundary, including a full 512-byte pad when already aligned | Gzip payload is CRC-checked, then the zero-run word stream is expanded to its declared size | Local parser and pinned SHA-256/size validation match MiniPro behavior |
| Algorithm upload | `0x26` 8-byte header, then the complete padded payload on EP1 | `0x26` BEGIN and ACK; full 512-byte EP1 frames containing 8-byte headers plus up to 504 data bytes; END and ACK | Packet construction matches for protocol `0x07` |
| BEGIN | 64-byte `0x03`; algorithm number is the high variant byte | 64-byte `0x03` for protocol `0x07`; newer 128-byte paths are protocol-specific and out of scope | Matches the scoped MiniPro path |
| Status | `0x39` after BEGIN and after each read/write block | `0x39` after BEGIN; no per-block or protection-command poll, while erase returns its own 64-byte response | Matches MiniPro's explicit T76 restriction |
| Code read | 8-byte command per block; EP1 read asks for 16 extra bytes to tolerate the firmware off-by-one behavior | One 16-byte initializer at address zero with block count, followed by EP2 payload reads | Matches, including the T56 64-byte payload cap |
| Code write | 8-byte command followed by a write-buffer-sized, zero-padded EP1 payload; status per block | One 16-byte initializer at address zero, then EP5 frames with a 16-byte header plus data; no status poll per block | Matches; partial final blocks carry their real data length |
| Erase | 15-byte `0x0e`, 64-byte response | 16-byte `0x0e`, 64-byte response | Matches |
| Protection | Generic protection commands remain explicit write options | Catalog-flagged targets are unprotected before erase, the transaction is restarted, and no protection-command status is polled; protect-after remains explicit | Matches current MiniPro's vendor-derived ordering |
| End/cleanup | 8-byte `0x04`; no documented FPGA reset command | 8-byte `0x04`, then `0x26 0xaf` with magic `0xaa55ddee` when closing the FPGA session | T76 success and abort cleanup are present and quarantine the WebUSB connection if cleanup fails |

## Resolved review findings

### Algorithm upload lifecycle

MiniPro's T56 and T76 implementations explicitly skip another bitstream upload after the first upload in a session. The initial PR revision repeated the T56/T76 upload after chip-ID checking, erase, blank-check, and before verification in both native Zig and the Wasm state machine.

This is resolved. Native Zig now separates the initial upload from BEGIN-only transaction restarts. The Wasm state machine follows the same lifecycle after chip-ID checking, erase, blank-check, and before verification. T76 still resets the FPGA when the public operation finishes or aborts.

Tests assert that a loaded T56/T76 transaction emits only BEGIN and the required status command, and that each Wasm restart proceeds directly to BEGIN instead of another upload.

### Shared T48/T56 USB identity

In the initial PR revision, WebUSB requested the T56 algorithm before Wasm read the programmer's system-info response whenever an algorithm provider existed and the shared T48/T56 PID was connected. An actual T48 could therefore fail because a T56-only resource was missing or malformed even though T48 requires no algorithm.

This is resolved. In `auto` mode, WebUSB now performs the system-info transfer first and delegates response parsing to the same Zig session parser used by ROM operations. It loads a T56 algorithm only when that response identifies a T56, caches the detected model for the open device, and retains the operation-time model and bootloader checks.

Tests cover both shared-PID outcomes: a T48 does not call the algorithm provider, while a T56 resolves and passes the T56 algorithm to Wasm.

### T76 protection ordering

Current MiniPro records a vendor-derived T76 requirement for protected parallel ROMs: protect-off must happen before erase and in its own transaction. The initial PR revision followed the generic path, which placed optional unprotection after erase and polled status after T76 protection commands.

This is resolved. Native Zig and Wasm now perform catalog-required T76 unprotection before erase regardless of the generic option, restart with the already-loaded algorithm, and do not issue a protection-command status poll. Re-protection remains an explicit caller choice.

Tests assert the protect-off, END, BEGIN, status, and erase ordering, and that protect-on proceeds directly to final transaction cleanup.

## Remaining validation gap: no physical T56/T76 ROM trace

The packet encoders and state machines have deterministic tests, but neither the PR nor this audit produced a USB capture from a real T56/T76 reading, erasing, programming, and verifying one supported 28-pin device.

Before marking the draft ready:

- Capture at least one T56 and one T76 read flow and compare the ordered transfers with MiniPro.
- On an electrically erasable target, exercise erase, blank-check, write, and full readback verification.
- Interrupt one operation after BEGIN and one during bulk transfer; confirm END/reset cleanup and a successful subsequent operation without replugging.
- Exercise T48 with `programmerKind: "auto"` while an algorithm provider is configured.

## Review disposition

The protocol field layouts are consistent with both the pinned and current MiniPro ROM28P paths. The repeated-upload lifecycle, shared-PID auto-selection, and T76 protection-ordering findings are resolved and covered by software tests.

The draft should remain open until the physical-device validation above is complete. XGecu release notes reinforce the need for model- and version-pinned algorithms, but do not independently validate the packet implementation.
