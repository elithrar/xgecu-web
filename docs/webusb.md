# WebUSB behavior

The JavaScript layer owns WebUSB permissions, opening, configuration selection, interface claiming, interface release, and async transfers. If a device is already open, the API still ensures configuration 1 is selected and interface 0 is claimed before ROM operations. The Wasm module never blocks on JavaScript promises; instead it exposes an operation state machine:

1. JS starts an operation such as `readROM`.
2. JS asks Wasm for the next transfer.
3. JS performs `USBDevice.transferOut()` or `USBDevice.transferIn()`.
4. JS passes the transfer result back into Wasm.
5. The loop repeats until Wasm reports completion.

The high-level browser API serializes ROM operations per programmer connection. A second `readROM` or `writeROM` call on the same device throws `XgecuWebUSBError` with `code === "OperationInProgress"` until the first operation completes.

Endpoint mapping:

| Purpose | WebUSB call |
| --- | --- |
| Command out | `transferOut(1, bytes)` |
| Command in | `transferIn(1, length)` |
| Payload out | `transferOut(2, bytes)` for T48 payloads |
| Payload in | `transferIn(2, length)` for T48 payloads |

T56 block reads and writes use endpoint 1 according to the current protocol implementation. T56 reads are capped to the protocol payload window before the extra status trailer is requested.

T56 transactions also require an algorithm bitstream. The Wasm ABI emits the T56 bitstream header transfer followed by the bitstream payload transfer before the normal begin-transaction packet. Catalog source records without a non-empty `t56AlgorithmHex` or `t56AlgorithmBase64` value are not advertised as T56-compatible.

Supported programmer hardware is limited to T48/T56. The browser chooser filters by XGecu VID/PID, then the Wasm session probe rejects unsupported programmer models.
The session probe also rejects bootloader mode before ROM operations begin.

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

Most browser apps should call `api.readROM()` and `api.writeROM()` instead of using this lower-level loop directly.

`performWebUSBTransfer()` validates WebUSB transfer statuses, short writes, and short reads. `WebUSBProgrammerConnection.close()` attempts to release interface 0 when this API claimed it, then closes the device even if interface release fails.
High-level browser APIs serialize ROM operations per programmer connection and throw package-owned `XgecuWebUSBError` objects for expected failures.
Wasm operations send a final `end_transaction` transfer on normal completion and attempt a best-effort `end_transaction` during abort or transfer failure cleanup.
