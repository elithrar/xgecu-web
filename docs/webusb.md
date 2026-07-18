# WebUSB behavior

The JavaScript layer owns WebUSB permissions, opening, configuration selection, interface claiming, interface release, and async transfers. If a device is already open, the API still ensures configuration 1 is selected and interface 0 is claimed before programmer operations. The Wasm module never blocks on JavaScript promises; instead it exposes an operation state machine:

1. JS starts an operation such as `readROM`.
2. JS asks Wasm for the next transfer.
3. JS performs `USBDevice.transferOut()` or `USBDevice.transferIn()`.
4. JS passes the transfer result back into Wasm.
5. The loop repeats until Wasm reports completion.

The high-level browser API serializes operations per physical programmer. A second `checkPinContacts`, `readROM`, or `writeROM` call on the same device, or an attempt to close its connection during an operation, throws `XgecuWebUSBError` with `code === "OperationInProgress"` until the first operation completes.
An unexpected device close or physical disconnect invalidates the active connection for programmer operations. Reconnect explicitly before writing so applications can invalidate stale backups and confirmations.

Endpoint mapping:

| Purpose | WebUSB call |
| --- | --- |
| Command out | `transferOut(1, bytes)` |
| Command in | `transferIn(1, length)` |
| Payload out | `transferOut(2, bytes)` for T48 payloads |
| Payload in | `transferIn(2, length)` for T48 payloads |

T48 write commands retain the logical byte count but endpoint 2 payloads are padded to the catalogued write-buffer size. T48 reads shorter than 64 bytes request a 64-byte USB frame and consume only the logical byte count, matching minipro and T48 firmware behavior.
T56 block reads and writes use endpoint 1 according to the current protocol implementation. T56 reads are capped to the protocol payload window before the extra status trailer is requested.
When WebUSB descriptors are available, connection setup verifies that interface 0 exposes command endpoint 1 in both directions and prefers an alternate setting that also exposes T48 payload endpoint 2.

T56 transactions also require an algorithm bitstream. The Wasm ABI emits the T56 bitstream header transfer followed by the bitstream payload transfer before the normal begin-transaction packet. Catalog source records without a non-empty `t56AlgorithmHex` or `t56AlgorithmBase64` value are not advertised as T56-compatible.
The seed catalog currently contains no T56-compatible records, so high-level T56 ROM operations remain unavailable until validated T56 records and algorithm payloads are added.

Supported programmer hardware is limited to T48/T56. The browser chooser filters by XGecu VID/PID, then the Wasm session probe rejects unsupported programmer models.
The session probe also rejects bootloader mode before ROM operations begin.
The system-info probe requests the full 80-byte response buffer. A valid 63-byte T48 short packet is accepted by the protocol parser, while T56 can return the full response without truncation.

Example transfer loop shape:

```ts
import { BrowserXgecuWebUSB, WasmBridge, performWebUSBTransfer } from "xgecu-web";

const wasm = await WasmBridge.load();
const api = new BrowserXgecuWebUSB(wasm);
const programmer = await api.requestProgrammer();

try {
  const handle = wasm.startReadROM({
    programmer: "auto",
    device: "AT28C64B@DIP28",
    memory: "code",
    skipIdCheck: false,
    continueOnIdMismatch: false
  });

  const bytes = await wasm.runOperation(handle, (transfer) => {
    return performWebUSBTransfer(programmer.device, transfer);
  });

  console.log(`Read ${bytes.byteLength} bytes`);
} finally {
  await programmer.close();
}
```

Most browser apps should call `api.checkPinContacts()`, `api.readROM()`, and `api.writeROM()` instead of using this lower-level loop directly.

`performWebUSBTransfer()` validates WebUSB transfer statuses and exact OUT byte counts. Successful short IN packets are passed to Wasm because WebUSB's requested IN length is a maximum; the protocol state machine validates the minimum bytes required for each response. Programmer names, manufacturer names, and serial numbers are trimmed at the first NUL from USB string descriptors. `WebUSBProgrammerConnection.close()` releases interface 0 and closes devices opened by this API after all shared connection references are closed.
High-level browser APIs serialize programmer operations per physical programmer and throw package-owned `XgecuWebUSBError` objects for expected failures.
ROM operations send a final `end_transaction` transfer on normal completion and attempt an `end_transaction` during abort or transfer failure cleanup. T48 pin checks reset all pin drivers instead. A failed cleanup quarantines the high-level connection and requires an explicit reconnect. Each low-level Wasm operation handle can be run once; dispose an unstarted handle with `disposeOperation()`.
