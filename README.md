# minipro-zig

`minipro-zig` is a Zig port of the upstream GPL `minipro` CLI for XGecu/TL866-compatible programmers. It keeps legacy command aliases where practical while moving chip databases into SQLite for faster, queryable access.

The port is still in progress. Read-only database commands, programmer detection/info, file formats, fake-transport protocol tests, and several opt-in chip operations are implemented. Destructive hardware operations require explicit `--execute` plus confirmation gates where applicable.

## Build

```sh
zig build
zig build test
```

The build links system `sqlite3` and `libusb-1.0`.

## Import Databases

Import upstream XML into a SQLite database:

```sh
./zig-out/bin/minipro-zig db import \
  --infoic ~/repos/minipro/infoic.xml \
  --logicic ~/repos/minipro/logicic.xml \
  --out devices.sqlite
```

If you have a generated `algorithm.xml`, include it for T56/T76 algorithm-aware operations:

```sh
./zig-out/bin/minipro-zig db import \
  --infoic ~/repos/minipro/infoic.xml \
  --logicic ~/repos/minipro/logicic.xml \
  --algorithms algorithm.xml \
  --out devices.sqlite
```

## Examples

```sh
./zig-out/bin/minipro-zig --db devices.sqlite -Q
./zig-out/bin/minipro-zig --db devices.sqlite -l -q t48
./zig-out/bin/minipro-zig --db devices.sqlite -L AT28 -q tl866ii
./zig-out/bin/minipro-zig --db devices.sqlite -d 'M27C64A@DIP28' -q t48
./zig-out/bin/minipro-zig programmer info
```

Chip operations default to dry-run. Add `--execute` only when hardware is connected and the selected device/package is correct.

```sh
./zig-out/bin/minipro-zig --db devices.sqlite chip read-id --device 'M27C64A@DIP28' --programmer t48 --execute
./zig-out/bin/minipro-zig --db devices.sqlite chip read --device 'M27C64A@DIP28' --programmer t48 --format bin --out readback.bin --execute
```

Destructive operations such as erase, write, protect, and unprotect require an exact confirmation:

```sh
./zig-out/bin/minipro-zig --db devices.sqlite chip erase --device 'AT28C64B' --programmer t48 --execute --confirm-destructive AT28C64B
```

## Oracle Comparisons

Build the upstream C oracle:

```sh
sh tools/build_oracle.sh
```

Compare C and Zig output with separate fixed prefixes:

```sh
./zig-out/bin/compare_cli \
  zig-cache/oracle/minipro-src/minipro \
  ./zig-out/bin/minipro-zig \
  --c-prefix --infoic ~/repos/minipro/infoic.xml --logicic ~/repos/minipro/logicic.xml \
  --zig-prefix --db devices.sqlite \
  -- -d '27C64@DIP28' -q tl866a
```

## Install Smoke Test

```sh
zig build --prefix /tmp/minipro-zig install
/tmp/minipro-zig/bin/minipro-zig --version
```

Install includes the `minipro-zig` and `compare_cli` binaries, README, Linux USB access notes, udev rules, man page, shell completions, and the SQLite schema used for database imports.

## Hardware Safety

- Default commands do not access hardware unless they document and require `--execute`.
- Write, erase, protect, and unprotect are destructive and require `--confirm-destructive <canonical-device>`.
- Prefer read-only checks first: `programmer info`, `chip read-id`, `chip blank`, and `chip read`.
- Verify writes by reading back and comparing checksums with the upstream C CLI when possible.
