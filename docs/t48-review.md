# T48 implementation review

This review compares the T48 path with the local `minipro` source at revision `a8efaedc236c1d9718bd28299dfbb99536b010ff`, the revision recorded in the seed catalog. It focuses on protocol correctness and hardware safety for the catalogued AT28C64B and M27C64A targets.

## Findings addressed

- **Pin contact checking was missing.** Upstream `minipro` does not expose its `-z` contact test for T48, but its T48 backend provides the required reset, pulldown, logic-output, and pin-read commands. `checkPinContacts` now exposes those primitives as an explicit T48-only operation, maps ZIF positions back to package pins, reports bad contacts, treats overcurrent as a hard failure, and resets all drivers on success, failure, or abort.
- **Native T48 writes accepted blocks larger than the catalogued write buffer.** `writeBlock` now rejects empty or oversized blocks before sending a USB command. The high-level write paths continue to chunk images to the device buffer size.
- **Protection requests were not capability-gated.** Native, Wasm, and browser write entry points now reject `unprotectBefore` and `protectAfter` when catalog flags do not advertise those operations.

## Checked behavior

- T48 command bytes, endpoints, begin-transaction layout, read/write address and length fields, erase acknowledgement handling, and status/overcurrent checks match the local reference behavior for the supported ROM paths.
- Non-electrically-erasable writes still blank-check the full selected memory region immediately before programming.
- Reads and writes still end open transactions on normal completion, operation errors, transfer failures, and aborts. Pin checks use a separate driver-reset cleanup path because they do not open a programming transaction.
- The catalog remains the authority for package layout and programming parameters. Pin-check metadata is validated and generated with the rest of the catalog.

## Limits

- The contact check covers only pins in the catalogued mask. Ground and pins that are unsuitable for the low-current logic test are intentionally omitted.
- A passing contact check does not identify the target, prove orientation, or validate an adapter. Apps must still confirm the chip marking, package, orientation, and adapter before any write.
- The operation is explicit rather than automatic. Validate the sequence on physical T48 hardware before making it a required preflight step.
- Broader `minipro` device coverage, custom protocols, fuse operations, and T48 self-test commands remain outside the current ROM-focused public API.
