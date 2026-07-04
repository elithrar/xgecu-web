# Hardware safety

Programming ROMs from a browser is powerful and destructive.

- Use `readROM` before `writeROM` to verify the programmer connection and target selection.
- Keep `verify: true` for write operations.
- Save the first readback under a unique filename before making changes.
- Compare the byte length of a patched image with the byte length of the readback before writing.
- Confirm the exact ROM package, orientation, and adapter before writing.
- Confirm that the selected catalog entry matches the chip marking. For example, selecting `AT28C64B@DIP28` is only appropriate for that compatible 28-pin EEPROM family and package.
- Leave chip ID checks enabled unless the catalog does not include an ID for the exact part and you have an external identification step.
- Do not remove the device while an operation is running.
- Treat overcurrent/status errors as hardware faults and inspect the target before retrying.
- WebUSB permission only grants access to the programmer. It does not confirm that the target chip is inserted correctly.
