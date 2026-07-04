# Hardware safety

Programming ROMs from a browser is powerful and destructive.

- Use `readROM` before `writeROM` to verify the programmer connection and target selection.
- Keep `verify: true` for write operations.
- Confirm the exact ROM package, orientation, and adapter before writing.
- Do not remove the device while an operation is running.
- Treat overcurrent/status errors as hardware faults and inspect the target before retrying.
- WebUSB permission only grants access to the programmer. It does not confirm that the target chip is inserted correctly.
