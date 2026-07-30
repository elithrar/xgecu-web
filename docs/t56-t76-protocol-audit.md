# T48/T56/T76 ROM Protocol Audit

Audited 2026-07-29 and re-reviewed 2026-07-30 against draft PR [#15](https://github.com/elithrar/xgecu-web/pull/15).

## Scope and evidence

This audit covers the PR's parallel ROM path only: MiniPro protocol `0x07`, the ten 28-pin ROM/EEPROM/EPROM catalog entries, local algorithm extraction, native Zig, Wasm, and WebUSB. It does not claim general T56/T76 support for SPI, NAND, eMMC, MCU, logic, or adapter-specific protocols.

Evidence, strongest first:

- MiniPro source pinned by the generated catalog: [`a8efaedc`](https://gitlab.com/DavidGriffith/minipro/-/tree/a8efaedc236c1d9718bd28299dfbb99536b010ff). This is the byte-level reference used for the PR.
- Current MiniPro source inspected at [`cae74c06`](https://gitlab.com/DavidGriffith/minipro/-/tree/cae74c0607077d6260b24995f5e4c0d0b66a6a2e). Its newer T76 work adds model-specific protection ordering and changes several non-ROM protocols, while protocol `0x07` still uses the generic 64-byte BEGIN and bulk ROM path.
- XGecu's [download page](https://www.xgecu.com/download.html) and [official forum release thread](https://forums.xgecu.com/viewthread.php?tid=20). These show separate T56 and T76 software/catalog release trains and recurring algorithm fixes. They do not document USB packet layouts.
- Software-only packet tests in this repository. No T56 or T76 hardware trace was captured for this PR.

The official download page and forum mirror did not expose a single consistent "latest" version during this audit. Treat downloaded `algorithm.xml` files as versioned input, never as an interchangeable or stable data source.

## Post-consolidation guardrail parity

The authoritative capability table is `src/programmer/capabilities.zig`. Native Zig operations and the Wasm state machine consume it directly. The TypeScript/WebUSB layer only transports Wasm-requested USB transfers and maps public errors; it does not reimplement these protocol policies.

| Guardrail | T48 | T56 | T76 | Shared enforcement after re-review |
|---|---|---|---|---|
| Algorithm before BEGIN | None | Required; catalog size and SHA-256 | Required; catalog size and SHA-256 | One capability flag drives native and Wasm requirements; digest tests cover T56 and T76 |
| BEGIN status | Required | Required | Required | Shared status parser/validator; overcurrent and programmer status are hard failures |
| Read/blank/verify block status | Required after every block | Required after every block | Not emitted by firmware | One capability flag drives all three read surfaces in native and Wasm; missing T56 polls were added |
| Write block status | Required after every block | Required after every block | Not emitted by streaming protocol | One capability flag drives native and Wasm sequencing |
| Protection status | Required | Required | Not emitted | One capability flag drives native and Wasm sequencing |
| Erase response | Exact 8-byte opaque ACK or at least 13-byte status | At least 13-byte status | Full 64-byte status frame | One shared response validator; Wasm now rejects 13–63-byte T76 responses |
| Short command/payload transfer | Hard I/O failure | Hard I/O failure | Hard I/O failure | Native transport vtable returns actual counts and wrappers require exact lengths; WebUSB already rejects short transfers |
| Blank check | Full selected region before non-erasable writes and after electrical erase | Same, plus block status | Same, using streamed reads | Shared high-level operation policy and capability-driven status sequencing |
| Readback verification | Default on; caller may explicitly disable | Default on; caller may explicitly disable | Mandatory because block writes have no status response | Native and Wasm reject T76 `verify: false` with `VerifyRequired` before BEGIN |
| Verify comparison | Byte-for-byte over the requested write image | Same | Same | Core Zig owns comparison and failure; no weaker hash-only ROM verification path |
| Algorithm integrity | Not applicable | Size plus SHA-256 before upload | Size plus SHA-256 before upload | Native and Wasm both validate catalog requirements; browser provider validation is defense in depth |
| Cleanup failure | END failure quarantines native/WebUSB transport | Same | END or FPGA-reset failure quarantines transport | Native cleanup now closes on failure; WebUSB cleanup continues to close and quarantine |
| Allocation before destructive/stream init | Blank-check and verify storage reserved before BEGIN | Same | Same, plus frame allocated before first write initializer | Native now matches Wasm's preflight allocation; T76 never begins an un-verifiable write |
| Empty/oversized block | Rejected before transfer | Rejected before transfer | Rejected before transfer | T56 empty write rejection added; all model encoders retain address and size bounds |
| Contact check | Supported for catalogued mappings | Unavailable | Unavailable pending trustworthy sourced behavior | Capability table prevents native/Wasm drift; no unsupported T76 pin-test claim |

## Changes made in the 2026-07-30 pass

- Added the shared protocol capability and response-validation module, exported through the native Zig package and imported directly by the Wasm ABI.
- Added the missing T56 `0x39` poll after every ordinary read, blank-check read, and verify read.
- Required the complete 64-byte T76 erase response in Wasm, matching native Zig and MiniPro.
- Made native transports report actual command and payload transfer lengths and reject short transfers centrally.
- Quarantined native transports when END, pin reset, or T76 FPGA-reset cleanup fails instead of silently swallowing the failure.
- Made readback verification mandatory for T76 writes, where no per-block write status exists.
- Moved T76 frame allocation before its first write initializer and rejected empty T56 blocks before any command is sent.
- Moved native readback allocation before BEGIN so an allocation failure cannot strand a completed but unverified write.
- Added symmetric algorithm-digest coverage for T56 and T76 and focused native/Wasm regression tests for the guardrails above.

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
