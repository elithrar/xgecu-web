# Winbond 32 KiB electrically erasable EPROMs on T48

`W27C257@DIP28` uses the existing T48 ROM operation engine.
**W27E257 is withheld from the usable catalog** pending the voltage evidence
described below. It must not be programmed using the W27C257 profile.
Read/backup first, select the exact marking, and write a **32,768-byte** image
with `erase: true` and `verify: true`. Electrical erase is part of rewriting:
the engine checks ID, erases, blank-checks the entire chip, writes, and verifies
in a fresh transaction. No padding, image mirroring, or 64 KiB substitution is
needed. Protection and pin-contact checking are not advertised for this profile.

Electrical erase capability is distinct from in-place EEPROM rewriting. Both
Winbond datasheets describe programming as changing bits only from 1 to 0;
changing 0 to 1 requires erasure. The catalog's `requiresBlankBeforeWrite: true`
is a host safety policy derived from that requirement, not a MiniPro firmware
descriptor field. Consequently, an explicit `erase: false` write still checks
the whole selected region for `0xff` before any programming payload, including
when the low-level API writes only a prefix. A nonblank byte produces
`TargetNotBlank`. AT28C64B EEPROM rewrites keep their existing behavior.

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

| Descriptor | W27C257 DIP28 | W27E257 DIP28 (withheld) |
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

## Why W27E257 is withheld

The pinned MiniPro [voltage tables](https://gitlab.com/DavidGriffith/minipro/-/blob/a8efaedc236c1d9718bd28299dfbb99536b010ff/src/database.c)
label VPP code `0x80` as 13.5 V, whereas the W27E257 datasheet specifies
11.75–12.25 V for programming (page 7). Its `chip_info=0` selects a fixed
firmware algorithm: MiniPro does not advertise adjustable voltage settings for
this profile. The host sources therefore do **not** establish the voltage the
T48 actually applies. This is an unresolved evidence conflict, not a measurement
or proof of overvoltage. Listed vendor support and matching XML fields do not
resolve it. Obtain authoritative firmware/vendor clarification or instrumented
qualification before enabling this profile; do not guess a replacement word.

Both Winbond parts report `DA 02`, so the ID cannot distinguish C from E.
Identification itself uses elevated voltage on A9. Confirm the exact marking,
package and orientation **before reading or identifying**, not just before writing.

## Part selection and limits

The supported DIP aliases are W27C257-10/-12. W27E257-10/-12/-15 are real DIP
ordering codes but are deliberately rejected along with the canonical W27E257
name. The **P** suffix denotes PLCC32 and is also rejected. T56/T76 and other
W27 packages/families are unsupported by this entry. AT28C256 has different pin assignments and is
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
