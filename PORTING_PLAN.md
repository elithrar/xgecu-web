# minipro-zig Porting Plan

## Goals

Port the existing C `minipro` CLI to Zig while preserving behavior, making the chip database queryable through SQLite, and improving the command-line interface without losing compatibility with existing workflows.

The port should be useful at every stage. Each milestone must produce either a working CLI feature, a reusable library component, or a verification tool that reduces risk for later hardware work.

The upstream C source is GPL-3.0-or-later, so a direct port that follows the C implementation is a derivative work and should keep GPL-compatible licensing.

## Source Inventory

Upstream source lives in `~/repos/minipro`.

Core C modules:

- `src/main.c`: CLI parsing and high-level operations.
- `src/minipro.c`, `src/minipro.h`: shared programmer API, handle state, endian helpers, CRC, dispatch through backend function pointers.
- `src/usb_nix.c`, `src/usb_win.c`, `src/usb.h`: USB transport.
- `src/tl866a.c`, `src/tl866iiplus.c`, `src/t48.c`, `src/t56.c`, `src/t76.c`: programmer-specific protocols.
- `src/database.c`, `src/database.h`, `src/xml.c`, `src/xml.h`: XML database parsing and device materialization.
- `infoic.xml`, `logicic.xml`, generated `algorithm.xml`: chip, logic, pin-map, configuration, and algorithm data.
- `src/ihex.c`, `src/srec.c`, `src/jedec.c`, `src/prom.c`, `src/bitbang.c`: file formats and special device operations.

Important observation: upstream has no checked-in tests, even though the Makefile defines `TESTS`. The Zig port needs an oracle harness that builds and runs the original C binary for behavioral comparison.

## Architecture

Use a small library-first design. The CLI should be a thin layer over stable Zig modules so tests can exercise behavior without shelling out for every case.

Proposed layout:

```text
build.zig
src/
  main.zig                 # CLI entrypoint
  cli.zig                  # argument parsing, command dispatch, output formatting
  commands/
    db.zig
    device.zig
    programmer.zig
    chip.zig
    logic.zig
  core/
    model.zig              # Device, Programmer, MemoryKind, voltages, flags
    errors.zig
    endian.zig
    crc.zig
  db/
    sqlite.zig             # SQLite wrapper and prepared statements
    schema.sql
    import_xml.zig         # XML -> normalized SQLite
    queries.zig            # search, info, count, chip-id lookup
  formats/
    bin.zig
    ihex.zig
    srec.zig
    jedec.zig
  programmer/
    transport.zig          # interface for USB and fake transports
    usb_libusb.zig
    session.zig            # open, identify, transaction lifecycle
    tl866a.zig
    tl866ii.zig
    t48.zig
    t56.zig
    t76.zig
  logic/
    vectors.zig
  test_support/
    oracle.zig             # C minipro invocation helpers
    fake_transport.zig
    fixtures.zig
tools/
  compare_cli.zig          # runs C and Zig commands, normalizes output, diffs
  import_db.zig            # standalone XML -> SQLite importer if useful
tests/
  fixtures/
  golden/
```

Key design choices:

- Keep the Zig data model close to upstream fields at first. Rename and refine only after parity is proven.
- Separate raw database values from decoded convenience fields. This makes oracle comparison easier and preserves unknown bits.
- Treat USB as a transport interface from day one. Hardware access, protocol tests, and recorded transcripts should all use the same protocol code.
- Keep SQLite access explicit through prepared statements. Avoid an ORM.
- Store original XML provenance and raw numeric attributes in SQLite. This gives us exact auditability when a decoded field is wrong.

## SQLite Database

SQLite replaces runtime XML parsing for normal CLI operations. XML import remains a build/tooling step and a compatibility path for custom database files.

Initial import inputs:

- `infoic.xml`: memory, MCU, PLD, SRAM, NAND, EMMC, VGA, and programmer-specific device data.
- `logicic.xml`: logic IC entries and vectors.
- `algorithm.xml`: optional generated T56/T76 algorithms. Do not require this file for database-only commands.

Schema principles:

- Normalize entities users search: devices, aliases, manufacturers, programmers, packages, algorithms, configs, vectors.
- Preserve raw source attributes as integers or text.
- Use FTS for human search and exact indexes for protocol lookup.
- Make imports deterministic: same XML inputs produce byte-for-byte equivalent SQLite content after `VACUUM INTO` or normalized dump.

Draft schema:

```sql
PRAGMA foreign_keys = ON;

CREATE TABLE meta (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL
);

CREATE TABLE sources (
  id INTEGER PRIMARY KEY,
  kind TEXT NOT NULL CHECK (kind IN ('infoic', 'logicic', 'algorithm')),
  path TEXT,
  sha256 TEXT NOT NULL,
  imported_at TEXT NOT NULL,
  upstream_version TEXT
);

CREATE TABLE databases (
  id INTEGER PRIMARY KEY,
  source_id INTEGER NOT NULL REFERENCES sources(id),
  xml_type TEXT NOT NULL,
  programmer_family TEXT,
  ordinal INTEGER NOT NULL
);

CREATE TABLE manufacturers (
  id INTEGER PRIMARY KEY,
  database_id INTEGER NOT NULL REFERENCES databases(id),
  name TEXT NOT NULL,
  is_custom INTEGER NOT NULL CHECK (is_custom IN (0, 1)),
  ordinal INTEGER NOT NULL
);

CREATE TABLE devices (
  id INTEGER PRIMARY KEY,
  database_id INTEGER NOT NULL REFERENCES databases(id),
  manufacturer_id INTEGER REFERENCES manufacturers(id),
  canonical_name TEXT NOT NULL,
  chip_type INTEGER NOT NULL,
  protocol_id INTEGER NOT NULL,
  variant INTEGER NOT NULL,
  read_buffer_size INTEGER NOT NULL,
  write_buffer_size INTEGER NOT NULL,
  code_memory_size INTEGER NOT NULL,
  data_memory_size INTEGER NOT NULL,
  data_memory2_size INTEGER NOT NULL,
  page_size INTEGER NOT NULL,
  pages_per_block INTEGER NOT NULL DEFAULT 0,
  chip_id INTEGER NOT NULL,
  chip_id_bytes_count INTEGER,
  voltages_raw INTEGER NOT NULL,
  pulse_delay INTEGER NOT NULL,
  flags_raw INTEGER NOT NULL,
  chip_info INTEGER NOT NULL,
  pin_map_raw INTEGER NOT NULL,
  package_details_raw INTEGER NOT NULL,
  compare_mask INTEGER,
  blank_value INTEGER,
  config_ref TEXT,
  is_custom INTEGER NOT NULL CHECK (is_custom IN (0, 1)),
  ordinal INTEGER NOT NULL
);

CREATE TABLE device_aliases (
  device_id INTEGER NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
  alias TEXT NOT NULL,
  alias_normalized TEXT NOT NULL,
  ordinal INTEGER NOT NULL,
  PRIMARY KEY (device_id, alias)
);

CREATE VIRTUAL TABLE device_fts USING fts5(
  alias,
  canonical_name,
  manufacturer,
  content=''
);

CREATE TABLE device_programmers (
  device_id INTEGER NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
  programmer TEXT NOT NULL CHECK (programmer IN ('tl866a', 'tl866ii', 't48', 't56', 't76')),
  supported INTEGER NOT NULL CHECK (supported IN (0, 1)),
  only_flag INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (device_id, programmer)
);

CREATE TABLE decoded_flags (
  device_id INTEGER PRIMARY KEY REFERENCES devices(id) ON DELETE CASCADE,
  can_erase INTEGER NOT NULL,
  has_chip_id INTEGER NOT NULL,
  has_data_offset INTEGER NOT NULL,
  off_protect_before INTEGER NOT NULL,
  protect_after INTEGER NOT NULL,
  lock_bit_write_only INTEGER NOT NULL,
  has_calibration INTEGER NOT NULL,
  prog_support INTEGER NOT NULL,
  word_size INTEGER NOT NULL,
  data_org INTEGER NOT NULL,
  can_adjust_vpp INTEGER NOT NULL,
  can_adjust_vcc INTEGER NOT NULL,
  can_adjust_clock INTEGER NOT NULL,
  can_adjust_address INTEGER NOT NULL,
  custom_protocol INTEGER NOT NULL,
  has_power_down INTEGER NOT NULL,
  is_powerdown_disabled INTEGER NOT NULL,
  reversed_package INTEGER NOT NULL
);

CREATE TABLE decoded_voltages (
  device_id INTEGER PRIMARY KEY REFERENCES devices(id) ON DELETE CASCADE,
  vcc_index INTEGER NOT NULL,
  vdd_index INTEGER NOT NULL,
  vpp_index INTEGER NOT NULL
);

CREATE TABLE packages (
  device_id INTEGER PRIMARY KEY REFERENCES devices(id) ON DELETE CASCADE,
  pin_count INTEGER NOT NULL,
  adapter INTEGER NOT NULL,
  plcc INTEGER NOT NULL,
  icsp INTEGER NOT NULL,
  smd INTEGER NOT NULL
);

CREATE TABLE voltage_options (
  programmer TEXT NOT NULL,
  kind TEXT NOT NULL CHECK (kind IN ('vcc', 'vdd', 'vpp', 'bb_vcc', 'bb_vpp', 'logic_vcc')),
  label TEXT NOT NULL,
  value INTEGER NOT NULL,
  ordinal INTEGER NOT NULL,
  PRIMARY KEY (programmer, kind, label)
);

CREATE TABLE spi_clock_options (
  programmer TEXT NOT NULL,
  profile TEXT NOT NULL,
  label TEXT NOT NULL,
  value INTEGER NOT NULL,
  ordinal INTEGER NOT NULL,
  PRIMARY KEY (programmer, profile, label)
);

CREATE TABLE pin_maps (
  id INTEGER PRIMARY KEY,
  database_id INTEGER NOT NULL REFERENCES databases(id),
  map_index INTEGER NOT NULL,
  gnd_pins TEXT NOT NULL,
  masks TEXT NOT NULL,
  UNIQUE (database_id, map_index)
);

CREATE TABLE configurations (
  id INTEGER PRIMARY KEY,
  database_id INTEGER NOT NULL REFERENCES databases(id),
  name TEXT NOT NULL,
  kind TEXT NOT NULL CHECK (kind IN ('mcu', 'pld', 'gal')),
  raw_xml TEXT NOT NULL
);

CREATE TABLE config_fuses (
  configuration_id INTEGER NOT NULL REFERENCES configurations(id) ON DELETE CASCADE,
  ordinal INTEGER NOT NULL,
  name TEXT NOT NULL,
  mask INTEGER NOT NULL,
  default_value INTEGER NOT NULL,
  PRIMARY KEY (configuration_id, ordinal)
);

CREATE TABLE config_locks (
  configuration_id INTEGER NOT NULL REFERENCES configurations(id) ON DELETE CASCADE,
  ordinal INTEGER NOT NULL,
  name TEXT NOT NULL,
  mask INTEGER NOT NULL,
  default_value INTEGER NOT NULL,
  PRIMARY KEY (configuration_id, ordinal)
);

CREATE TABLE logic_vectors (
  device_id INTEGER NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
  vector_id TEXT NOT NULL,
  states TEXT NOT NULL,
  ordinal INTEGER NOT NULL,
  PRIMARY KEY (device_id, vector_id)
);

CREATE TABLE algorithms (
  id INTEGER PRIMARY KEY,
  source_id INTEGER REFERENCES sources(id),
  programmer TEXT NOT NULL CHECK (programmer IN ('t56', 't76')),
  name TEXT NOT NULL,
  gzip_base64 TEXT,
  bitstream BLOB,
  sha256 TEXT,
  UNIQUE (programmer, name)
);

CREATE INDEX idx_devices_chip_id ON devices(chip_id, chip_id_bytes_count);
CREATE INDEX idx_devices_protocol ON devices(protocol_id, variant);
CREATE INDEX idx_aliases_normalized ON device_aliases(alias_normalized);
CREATE INDEX idx_devices_type ON devices(chip_type);
```

Importer behavior:

- Split comma-separated `ic name` values into aliases and select the first as `canonical_name`, matching the C behavior.
- Preserve XML order in `ordinal` columns so list output can exactly match C initially.
- Decode flags, voltages, packages, programmer support, vectors, and pin maps during import.
- Keep raw values on `devices` so decoder bugs are easy to identify and fix.
- Validate imported counts against C `print_chip_count` and selected `list_devices` output.

## CLI Design

Provide modern subcommands while keeping legacy flags as aliases during the parity phase.

Recommended command shape:

```text
minipro-zig [global-options] <command> [command-options]

Global options:
  --db <path>                 SQLite database path
  --programmer <model>        tl866a, tl866ii, t48, t56, t76, auto
  --verbose
  --quiet
  --json
  --no-color
  --help
  --version

Database/device commands:
  db import --infoic <xml> --logicic <xml> [--algorithms <xml>] --out <db>
  db stats
  db query <sql>
  device list [--programmer <model>] [--type <kind>] [--custom]
  device search <term> [--programmer <model>] [--limit <n>]
  device info <device>
  device id <chip-id> [--pins <n>] [--programmer <model>]

Programmer commands:
  programmer list
  programmer detect
  programmer info
  programmer check
  programmer update <firmware-file>

Chip commands:
  chip read <device> <output> [--memory code|data|config|user|calibration] [--format bin|ihex|srec]
  chip write <device> <input> [--memory code|data|config|user] [--format bin|ihex|srec|jedec]
  chip verify <device> <input> [--memory code|data|config|user] [--format bin|ihex|srec|jedec]
  chip erase <device>
  chip blank <device> [--memory code|data|config|user]
  chip read-id <device>
  chip autodetect --package 8|16

Logic commands:
  logic test <device> [--vcc <voltage>] [--out <file>]
```

Common chip operation flags:

- `--vpp <voltage>`, `--vcc <voltage>`, `--vdd <voltage>`
- `--pulse <usec>`
- `--spi-clock <mhz>`
- `--address <hex>` for I2C EEPROMs
- `--icsp`, `--icsp-no-vcc`
- `--pin-check`
- `--skip-id`, `--no-id-error`
- `--skip-erase`, `--erase-first`
- `--skip-verify`
- `--protect`, `--unprotect`
- `--allow-size-mismatch`, `--no-size-warning`

Legacy compatibility aliases:

- `-l`, `--list` -> `device list`
- `-L`, `--search` -> `device search`
- `-d`, `--get_info` -> `device info`
- `-Q`, `--query_supported` -> `programmer list`
- `-k`, `--presence_check` -> `programmer detect`
- `-p`, `--device` remains accepted for old-style commands.
- `-r`, `-w`, `-m`, `-E`, `-b`, `-D`, `-T`, `-F` remain accepted and translated into modern command structs.

CLI output policy:

- Default human output should be clear and stable.
- `--json` should be available for list, search, info, detect, stats, and ID lookup.
- Initial parity tests should compare legacy-compatible text output, not the improved modern output.

## Test Harness

The test harness must make the C implementation an executable oracle.

Build artifacts:

- Build upstream C `minipro` from `~/repos/minipro` into a known path under `zig-cache/oracle/` or `tools/oracle/`.
- Build Zig `minipro-zig` normally through `zig build`.
- Use the same XML fixture files for both binaries.
- Use a generated SQLite DB for Zig tests.

Test classes:

- Unit tests: endian load/store, CRC-32, flag decoding, voltage decoding, package decoding, name normalization, CLI parser, error formatting.
- Format tests: binary, Intel HEX, SREC, JEDEC parse/write round trips against fixtures and C behavior.
- Database importer tests: XML fixture import, full upstream import, deterministic output, expected row counts, alias splitting, logic vectors, pin maps, config records.
- Golden CLI tests: run C and Zig commands, normalize harmless differences, diff stdout, stderr, and exit status.
- Protocol tests: run backend operations against a fake transport with byte-level expectations.
- Hardware-in-loop tests: gated by environment variables and never part of default CI.

Oracle comparison commands to support early:

```text
minipro -Q
minipro -l -q tl866a
minipro -l -q tl866ii
minipro -l -q t48
minipro -l -q t56
minipro -l -q t76
minipro -L AT28 -q tl866ii
minipro -d AT28C64B -q tl866ii
minipro -d 27C64@DIP28 -q tl866a
minipro -d ATMEGA48 -q tl866ii
```

Normalization rules:

- Strip build version lines unless the test explicitly covers `--version`.
- Normalize whitespace only where the C CLI depends on pager or terminal width.
- Keep device ordering strict.
- Keep exit status strict.
- Do not hide content differences in device info, IDs, sizes, flags, voltages, or package data.

Fake transport strategy:

- Define a `Transport` interface with `write`, `read`, `control`, `reset`, and timeout handling.
- Protocol backends receive a transport, not libusb directly.
- Tests provide scripted request/response transcripts.
- Record real USB sessions later for read ID, blank check, small EEPROM read/write, and failure states.

Hardware-in-loop strategy:

- Require explicit environment variables such as `MINIPRO_HIL=1`, `MINIPRO_PROGRAMMER=t48`, and `MINIPRO_DEVICE=AT28C64B`.
- Default to read-only HIL tests: detect, info, chip ID, blank check.
- Put destructive tests behind a second variable such as `MINIPRO_HIL_WRITE=1`.
- Always verify write tests by readback and compare checksums.

## Porting Phases

### Phase 0: Bootstrap

Deliverables:

- `build.zig` and basic project layout.
- Minimal CLI with `--help`, `--version`, and command parser tests.
- Upstream C oracle build integration.
- `tools/compare_cli` skeleton.

Verification:

- `zig build test`
- Oracle binary builds from `~/repos/minipro`.
- Compare `minipro -Q` once the Zig command exists.

### Phase 1: Core Types and Utilities

Deliverables:

- Zig equivalents for constants and core structs from `minipro.h`.
- Endian helpers equivalent to `format_int` and `load_int`.
- CRC-32 equivalent to C `crc_32`.
- Flag, voltage, and package decoders equivalent to `database.c`.

Verification:

- Unit tests from hand-picked upstream values.
- Property-style tests for endian helpers across widths used by protocols.
- C/Zig comparison for CRC on fixed binary fixtures.

### Phase 2: SQLite Importer and Read-Only Database CLI

Deliverables:

- XML streaming parser or small focused XML importer for `infoic.xml` and `logicic.xml`.
- SQLite schema and import command.
- `device list`, `device search`, `device info`, `db stats`.
- Legacy aliases for `-l`, `-L`, `-d`, `-q`, `--infoic`, `--logicic`.

Verification:

- Import full upstream XML.
- Compare counts against C `print_chip_count` behavior.
- Compare selected `-l`, `-L`, and `-d` outputs for all programmer families.
- Verify alias splitting for comma-separated chip names.

### Phase 3: File Formats

Deliverables:

- Raw binary read/write helpers.
- Intel HEX parser/writer.
- SREC parser/writer.
- JEDEC parser/writer for PLD paths.
- Shared memory image model with address, type, size, fill byte, and word-size handling.

Verification:

- Fixture round trips.
- Compare C and Zig parse results for representative HEX, SREC, and JEDEC files.
- Compare generated files byte-for-byte where the C output is deterministic.

### Phase 4: USB Transport and Programmer Detection

Deliverables:

- libusb integration for Unix/macOS.
- Transport interface and fake transport.
- Programmer detection, `programmer list`, `programmer detect`, `programmer info`.
- Initial session lifecycle: open, identify, reset, close.

Verification:

- Fake transport tests for detection paths.
- HIL detection test when hardware is present.
- Compare `-Q` and `-k` behavior against C.

### Phase 5: Read-Only Chip Operations

Deliverables:

- TL866A/TL866II/T48/T56/T76 read block paths, starting with the most common shared operations.
- Chip ID reading.
- Blank check.
- Pin check if protocol support is straightforward after read/status support.
- TL866II chip pin-contact execute can follow upstream `tl866iiplus_pin_test`. Keep T76 chip pin-contact execute disabled until hardware/transcript evidence clarifies the firmware response: upstream `t76_pin_test` receives 32 bytes from `T76_PIN_DETECTION` but does not consume them, so the visible code reports every mapped pin as bad contact.
- `chip read`, `chip read-id`, `chip blank`, legacy `-r`, `-D`, `-b`.

Verification:

- Fake transport transcripts for read ID and read blocks.
- HIL read tests on safe EEPROMs.
- Compare readback files and checksums against C for the same chip.

### Phase 6: Write, Verify, Erase, Protect

Deliverables:

- Erase, write block, verify, protect/unprotect flows.
- Size mismatch handling equivalent to `-s` and `-S`.
- ID-check controls equivalent to `-x` and `-y`.
- Voltage, pulse, SPI clock, and I2C address option handling.
- Legacy `-w`, `-m`, `-E`, `-e`, `-v`, `-u`, `-P`, `--vpp`, `--vcc`, `--vdd`, `--pulse`, `--spi_clock`, `--address`.

Verification:

- Fake transport tests for operation ordering and failure cleanup.
- HIL write tests only with explicit opt-in and known sacrificial devices.
- C/Zig comparison: write with C, verify with Zig; write with Zig, verify/read with C.

### Phase 7: Logic ICs, Bitbang, PROM, and Special Paths

Deliverables:

- Logic vector execution from SQLite.
- `logic test` and legacy `-T`.
- Bitbang and PROM custom protocol support.
- Pin map resolution from SQLite.

Verification:

- Database/vector parser tests.
- Fake transport tests for vector execution order.
- HIL tests with known logic ICs where available.

### Phase 8: T56/T76 Algorithms

Deliverables:

- `algorithm.xml` import support.
- Base64 + gzip decode, bitstream storage or lazy extraction.
- Algorithm name resolution equivalent to `get_algorithm`.
- Upload path integrated with T56/T76 operations.

Verification:

- Compare resolved algorithm names for selected devices against C.
- Compare decoded bitstream hashes against C extraction.
- HIL smoke tests for T56/T76 only when hardware and legal algorithm files are present.

### Phase 9: Packaging and Release Quality

Deliverables:

- Man page or generated help docs.
- Shell completions.
- Install rules for binary, SQLite DB, udev rules, and docs.
- CI matrix for Linux and macOS.
- Optional static builds where Zig and dependencies allow it.

Verification:

- Fresh checkout build.
- Full non-HIL test suite.
- Database import determinism check.
- CLI compatibility suite against upstream C.

## Verification Matrix

Every ported feature gets at least one direct C comparison before being marked complete.

```text
Feature                 C oracle                         Zig target
Supported programmers   minipro -Q                       programmer list
Device list             minipro -l -q <model>            device list --programmer <model>
Search                  minipro -L <term> -q <model>     device search <term> --programmer <model>
Device info             minipro -d <chip> -q <model>     device info <chip> --programmer <model>
Chip ID lookup          minipro -a 8/16                  chip autodetect --package 8/16
Read ID                 minipro -p <chip> -D             chip read-id <chip>
Read                    minipro -p <chip> -r <file>      chip read <chip> <file>
Write                   minipro -p <chip> -w <file>      chip write <chip> <file>
Verify                  minipro -p <chip> -m <file>      chip verify <chip> <file>
Blank check             minipro -p <chip> -b             chip blank <chip>
Erase                   minipro -p <chip> -E             chip erase <chip>
Logic test              minipro -p <chip> -T             logic test <chip>
```

Completion rule:

- Parser-only features require unit tests and golden CLI comparisons.
- Database features require C oracle comparisons on full upstream XML.
- Hardware features require fake transport tests first and HIL tests second.
- Destructive hardware features require cross-verification with C readback or verify.

## Immediate Next Steps

1. Add `build.zig`, `src/main.zig`, and a tiny parser that supports `--help`, `--version`, and `programmer list`.
2. Add an oracle build step or script that builds `~/repos/minipro/minipro` without modifying upstream source.
3. Add `tools/compare_cli` and the first golden comparison: C `minipro -Q` vs Zig `programmer list`.
4. Implement core constants, endian helpers, CRC, and decoder unit tests.
5. Implement the SQLite schema and importer for a tiny XML fixture before importing full `infoic.xml`.
