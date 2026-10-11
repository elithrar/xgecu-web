# Winbond 32 KiB electrically erasable EPROMs on T48

`W27C257@DIP28` and `W27E257@DIP28` use the existing T48 ROM operation engine.
Read/backup first, select the exact marking, and write a **32,768-byte** image
with `erase: true` and `verify: true`. Electrical erase is part of rewriting:
the engine checks ID, erases, blank-checks the entire chip, writes, and verifies
in a fresh transaction. No padding, image mirroring, or 64 KiB substitution is
needed. Protection and pin-contact checking are not advertised for these profiles.

## Sources and descriptor provenance

- Winbond [W27C257, September 1998 revision A2](https://www.100y.com.tw/pdf_file/W27C257.pdf)
  and [W27E257, January 1997 revision A3](https://www.100y.com.tw/pdf_file/W27E257.pdf),
  pages 1–4, 6–12: 32,768 × 8, 28-pin 600 mil DIP, ID `DA 02`, 12 V
  programming, 14 V erase on VPP/A9, 100 µs programming pulses, 100 ms erase
  pulses. These are chip requirements; the T48 firmware controls pin voltages
  and pulse sequences. This change does not implement a host-side algorithm.
- XGecu [T48 V12.78 device list, January 19, 2025](https://www.epromirok.hu/downloads/t48_list.pdf#page=257),
  mirrored vendor document, page 257: separate W27C257 and W27E257 DIP28 entries.
  The live vendor TXT was unavailable during review; this establishes listed
  support, not qualification of a particular T48 firmware revision.
- MiniPro [infoic.xml at a8efaedc236c1d9718bd28299dfbb99536b010ff](https://gitlab.com/DavidGriffith/minipro/-/blob/a8efaedc236c1d9718bd28299dfbb99536b010ff/infoic.xml),
  exact **INFOIC2PLUS** records (the existing catalog provenance), and
  [T48 transport](https://gitlab.com/DavidGriffith/minipro/-/blob/a8efaedc236c1d9718bd28299dfbb99536b010ff/src/t48.c).
  MiniPro's current `3e2f4911fa86f72a57ae0ace777342e75da5e7cc` records agree.

| Descriptor | W27C257 DIP28 | W27E257 DIP28 |
| --- | --- | --- |
| protocol / variant | `0x07` / `0x3211` | `0x07` / `0x3211` |
| raw voltages | `0x0000` | `0x0080` |
| chip info / pin map | `0` / `0x0c16` | `0` / `0x0c16` |
| pulse delay / page size | `100` / `0` | `100` / `0` |
| read / write buffer | `1024` / `128` | `1024` / `128` |
| flags / ID | `0x78` / `0xda02` (2 bytes) | `0x78` / `0xda02` (2 bytes) |
| package / memory | `0x1c000000` / `0x8000` | `0x1c000000` / `0x8000` |

Raw voltage fields are firmware descriptor encodings, not volts. Preserve the
C/E difference and do not alias the two parts or borrow a UV EPROM descriptor.
No vendor algorithm payload is added. MiniPro is GPL-3.0-or-later; this change
records factual device/protocol parameters and source references without copying
MiniPro implementation code, XML blocks, or firmware into the Apache-2.0 package.

## Part selection and limits

Datasheet DIP suffixes are W27C257-10/-12 and W27E257-10/-12/-15; the **P**
suffix denotes PLCC32 and is intentionally not an alias. In particular,
W27E257-12 is DIP28, 120 ns. T56/T76 and other W27 packages/families are
unsupported by these entries. AT28C256 has different pin assignments and is
not a pin-compatible substitute for 27C256.

The DIP read pinout matches 27C256, but read VPP must be near VCC
(VCC − 0.7 V through VCC in both datasheets). The cited read specifications
cover 0–70 °C; absolute maximum temperature ratings are not operating grades.
Board voltages, timing, temperature and the exact chip marking still need checking.
No automotive or vehicle compatibility is claimed.

Catalog, packet and simulated transfer tests are software evidence only.
No physical T48/chip qualification has been performed. Qualification still
requires a real backup, erase/blank check, exact-size write, independent readback,
and confirmation of voltage/timing behavior for the actual device and firmware.
