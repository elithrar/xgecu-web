# T48 32 KiB hardware-safety review

Review date: 2026-10-11. Scope: raw W27C257/W27E257 and M27C256B-10F1/-12F1
support in xgecu-web PR #17 and WorkbenchOS PR #122. The existing M27C64A and
AT28C64B 8 KiB paths were comparison controls, not evidence of successful
hardware qualification. No physical chip operations were performed.

Initial reviewed heads were xgecu-web `e0a1fb26b86557ec87b4739c1de1dfb2f3770a40`
and WorkbenchOS `162319b98ff1ac943625cad0cc7d899fe2a43b73`.

## Ranked findings and disposition

| Priority | Validated issue or evidence gap | Resolution |
| --- | --- | --- |
| High, electrical evidence gate | W27E257's exact MiniPro descriptor uses `0x0080`; MiniPro's generic VPP table labels `0x80` as 13.5 V, while Winbond requires 11.75–12.25 V programming. Its fixed firmware algorithm prevents establishing actual pin voltage from that table alone. | Withhold the entire new W27E257 catalog entry and aliases. Read/write cannot start for this name. Preserve the original descriptor as evidence; do not guess a voltage override or substitute W27C257. This is not a claim of measured overvoltage. |
| High, shared hardware-state recovery | After an END cleanup failure, software close/reopen cleared quarantine and allowed another operation without any hardware recovery command. WebUSB close releases the host session; it does not establish socket power-down. | Quarantine persists for that USBDevice for the page lifetime, across wrappers and API instances. Require the operator to disconnect USB power, then reload before reconnecting. UI guidance follows the same contract. |
| Medium, destructive programming guard | `canErase=true` allowed Winbond `erase:false` writes to skip blank checking, although EPROM programming only changes 1 to 0. A simulated `AA` target written with `55` became `00` before verification failed. | Separate `requiresBlankBeforeWrite` policy from electrical erase capability. Native Zig and Wasm check the entire selected region before programming, including prefix writes. AT28C64B byte-rewrite behavior is unchanged. |
| Medium, shared connection ownership | WorkbenchOS discarded a disconnected wrapper without closing it. A reconnect added another reference, so later Disconnect could leave USB open. | Await operation completion, close the discarded wrapper, and block reconnect during cleanup. A delayed-close regression covers the 32 KiB path. |
| Low, documentation accuracy | ST documentation named native `EraseUnsupported` as the browser error. | Document browser `InvalidInput` and native `EraseUnsupported` separately; electrical erase remains rejected. |

The voltage gate above is a deliberately conservative response to unresolved
source evidence. [Winbond provenance and selection limits](winbond-27x257.md)
contain the exact sources and the withheld descriptor. [ST evidence](st-m27c256b.md)
explains why both requested speed grades share the existing profile.

## Independent review passes

1. Four independent reviewers examined electrical/datasheet provenance,
   native/Wasm/WebUSB lifecycle, WorkbenchOS state and ownership, and regression
   credibility/maintainability. Candidates were reproduced or source-traced
   before fixes. An apparent BEGIN-cleanup gap was rejected: the state machine
   marks the transaction dirty before sending BEGIN, and injected transfer
   failures confirmed END cleanup. No change was made for that rejected finding.
2. Three fresh independent reviewers examined the fixes and remaining lifecycle,
   profile/blank-write, and UI surfaces. This pass found a test assertion using
   the wrong start-operation error text and stale UI reconnect guidance; both
   were corrected and independently rechecked. The final pass reported no
   further validated actionable findings in this reviewed scope.

Committed regression coverage includes:

- Exact 32,768-byte erase/write images; short, long and 64 KiB rejection; no
  padding or mirroring. The general library's existing explicit no-erase prefix
  API remains supported; WorkbenchOS always requires an exact full-chip image.
- Canonical ST profile reuse; electrical erase rejection; full-chip blank check
  immediately before ST programming, including a nonblank final byte.
- Winbond no-erase full/prefix writes check all 32 KiB; a nonblank final byte
  prevents every programming payload. The simulator models EPROM 1-to-0 writes.
- ID mismatch before erase, failed erase, last-byte verification corruption,
  unsupported protection/programmer/package requests and withheld W27E aliases.
- Initial/restarted BEGIN failures and failed END; single-use Wasm handles;
  poisoned-device reconnect refusal, including after wrapper close.
- Backup and exact-size gates, erase/verify confirmation, independent full
  SHA-256 readback, and delayed disconnected-wrapper cleanup in WorkbenchOS.

Additional independent software probes exercised 8,660 lifecycle fault cases
across W27C257 and M27C256B reads/writes: transfer rejection, cancellation and
failed cleanup at every transfer position, plus wrapper/close interleavings.
They observed either completed cleanup or a cleanup-failure notification and
single-use handle destruction. Another 90 cases covered status/overcurrent
injection before programming and odd-size no-erase prefixes with blank/nonblank
tails. These review probes use simulated USB, not physical chips.

## Existing comparison-path findings outside this change

Per the clarified scope, neither of these older 8 KiB issues was modified:

- M27C64A's source descriptor `0x4000`, with adjustable-voltage reporting enabled,
  maps to MiniPro labels VDD 5.5 V / VPP 12 V. ST's April 2006 Rev 3 datasheet
  specifies programming VCC 6 V ±0.25 V / VPP 12.5 V ±0.25 V. This is a
  programming-margin/retention evidence gap requiring a separate investigation;
  actual firmware output was not measured. Source: [ST manufacturer document](https://www.win-source.net/Product/ProductRuntimePdf?productId=575804),
  pages 9 and 14, and the pinned MiniPro voltage tables cited in the Winbond note.
- On profiles that support contact checking, a failed check followed by a
  canceled/errored retry can clear the known-failure UI gate. A fresh read/backup
  then permits review without another successful check. The reviewed new 32 KiB
  profiles do not advertise contact checking, so this reproduced older-path
  issue is reported separately rather than broadening this patch.

AT28C64B has no fixed silicon ID in this catalog; its identification bytes are
user-programmable memory, not a reliable automatic part detector. Its EEPROM
write/erase assumptions must not be applied to Winbond or ST EPROMs.

## Remaining qualification gates

- Confirm exact marking, package, orientation and adapter before any operation.
  Winbond C/E share ID `DA02`, and identification itself applies elevated A9
  voltage. ID checks do not make an unknown or mismatched chip safe to probe.
- Reconcile W27E257's fixed-algorithm voltage interpretation before enabling it.
- Instrument the actual T48 firmware's VCC/VPP/A9 levels, pin assignments,
  sequencing, pulse duration/repetition, erase/program verification margins,
  overcurrent response, and power-down after success/error/disconnect. ST's
  source voltage labels sit at its allowed programming maxima; calibration and
  overshoot need measurement.
- Verify readback and retention across the intended operating range using
  sacrificial parts. A matching hash at normal read voltage cannot prove
  programming margin, retention or automotive suitability.
- Cancellation occurs between USB transfers; a stalled transfer, browser crash,
  lost USB link or power loss can prevent software cleanup. USB close and even
  a successfully submitted END are not physical proof that socket power is off.

No finite source/simulation review establishes absolute safety. Vehicle hardware
compatibility and physical T48 qualification remain unverified. No merge or
deployment is authorized by this review.
