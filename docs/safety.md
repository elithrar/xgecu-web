# Hardware safety

Programming ROMs from a browser is powerful and destructive.

- Use `readROM` before `writeROM` to verify the programmer connection and target selection.
- Keep `verify: true` for write operations.
- Save the first readback under a unique filename before making changes.
- Compare the byte length of a patched image with the byte length of the readback before writing.
- Confirm the exact ROM package, orientation, and adapter before writing.
- Confirm that the selected catalog entry matches the chip marking. For example, selecting `AT28C64B@DIP28` is only appropriate for that compatible 28-pin EEPROM family and package.
- UV EPROM parts such as `M27C64A@DIP28` require external erasure and a full blank readback before programming. The API rejects `erase: true` when `canErase` is false.
- Leave chip ID checks enabled unless the catalog does not include an ID for the exact part and you have an external identification step.
- Choose `erase` explicitly from the resolved target's `canErase` metadata and keep `verify: true` enabled. Use `erase: false` for a non-electrically-erasable target only after external erasure and a blank readback.
- An erase write is restricted to code memory and must provide an image exactly matching that region. Data/user-memory and partial writes require explicit `erase: false`; device-specific algorithms may still affect adjacent state.
- Do not remove the device while an operation is running.
- Treat overcurrent/status errors as hardware faults and inspect the target before retrying.
- Treat verify failures as failed programming attempts; do not immediately retry without checking chip selection, voltage/package, adapter, and image size.
- WebUSB permission only grants access to the programmer. It does not confirm that the target chip is inserted correctly.
