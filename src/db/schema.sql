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

CREATE TABLE config_gal (
  configuration_id INTEGER PRIMARY KEY REFERENCES configurations(id) ON DELETE CASCADE,
  fuses_size INTEGER NOT NULL,
  row_width INTEGER NOT NULL,
  ues_address INTEGER NOT NULL,
  ues_size INTEGER NOT NULL,
  powerdown_row INTEGER NOT NULL,
  acw_address INTEGER NOT NULL
);

CREATE TABLE config_gal_acw_bits (
  configuration_id INTEGER NOT NULL REFERENCES configurations(id) ON DELETE CASCADE,
  ordinal INTEGER NOT NULL,
  fuse_index INTEGER NOT NULL,
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
