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
| Payload in | `transferIn(2, length)` for T48 and T76 payloads |
| T76 payload out | `transferOut(5, frame)` |

T48 write commands retain the logical byte count but endpoint 2 payloads are padded to the catalogued write-buffer size. T48 reads shorter than 64 bytes request a 64-byte USB frame and consume only the logical byte count, matching minipro and T48 firmware behavior.
T56 block reads and writes use endpoint 1 according to the current protocol implementation. T56 reads are capped to the protocol payload window before the extra status trailer is requested.
T76 sends one 16-byte initializer before a code-memory read or write sequence. Consecutive reads arrive on endpoint 2; each write block is a 16-byte header plus data on endpoint 5. T76 does not use per-block status polling.
When WebUSB descriptors are available, connection setup selects the model-specific bulk endpoint set. T48/T56 retains an endpoint 1-only fallback because those models share a USB product ID and T56 moves block payloads over the command endpoint.

T56 and T76 transactions require a user-local algorithm bitstream. Catalog records pin the required name, decoded size, and SHA-256 but never contain payload bytes. `createAlgorithmXmlProvider()` can decode a user-selected local `algorithm.xml`; the browser and Wasm validation layers reject missing, corrupt, or mismatched payloads before upload.
The T56 ABI emits a header followed by the padded bitstream. T76 uses acknowledged begin/end frames with 504-byte chunks and resets the FPGA during final or abort cleanup.

Supported programmer hardware is limited to T48/T56 (`0xa466:0x0a53`) and T76 (`0xa466:0x1a86`). The browser chooser filters by those USB IDs, then the Wasm session probe rejects unsupported programmer models.
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
ROM operations send a final `end_transaction` transfer on normal completion and attempt an `end_transaction` during abort or transfer failure cleanup. T76 operations additionally reset the FPGA; T48 pin checks reset all pin drivers instead. A failed cleanup quarantines the high-level connection and requires an explicit reconnect. Each low-level Wasm operation handle can be run once; dispose an unstarted handle with `disposeOperation()`.
