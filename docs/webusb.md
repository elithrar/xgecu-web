# WebUSB behavior

The JavaScript layer owns WebUSB permissions, opening, configuration selection, interface claiming, and async transfers. The Wasm module never blocks on JavaScript promises; instead it exposes an operation state machine:

1. JS starts an operation such as `readROM`.
2. JS asks Wasm for the next transfer.
3. JS performs `USBDevice.transferOut()` or `USBDevice.transferIn()`.
4. JS passes the transfer result back into Wasm.
5. The loop repeats until Wasm reports completion.

Endpoint mapping:

| Purpose | WebUSB call |
| --- | --- |
| Command out | `transferOut(1, bytes)` |
| Command in | `transferIn(1, length)` |
| Payload out | `transferOut(2, bytes)` for T48 payloads |
| Payload in | `transferIn(2, length)` for T48 payloads |

T56 block reads and writes use endpoint 1 according to the current protocol implementation.

Supported programmer hardware is limited to T48/T56. The browser chooser filters by XGecu VID/PID, then the Wasm session probe rejects unsupported programmer models.
