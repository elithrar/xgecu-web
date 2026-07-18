// SPDX-License-Identifier: Apache-2.0
//! Shared byte-level constants for the T48/T56 USB protocols.
//!
//! These devices intentionally use the same command byte assignments for the
//! operations this library supports. Keeping them in one namespace makes the
//! Wasm state machine and native protocol implementations easier to audit
//! against each other.

pub const endpoint = struct {
    pub const command: u8 = 1;
    pub const payload: u8 = 2;
};

pub const command = struct {
    pub const begin_transaction: u8 = 0x03;
    pub const end_transaction: u8 = 0x04;
    pub const read_id: u8 = 0x05;
    pub const read_user: u8 = 0x06;
    pub const write_user: u8 = 0x07;
    pub const read_config: u8 = 0x08;
    pub const write_config: u8 = 0x09;
    pub const write_user_data: u8 = 0x0a;
    pub const read_user_data: u8 = 0x0b;
    pub const write_code: u8 = 0x0c;
    pub const read_code: u8 = 0x0d;
    pub const erase: u8 = 0x0e;
    pub const read_data: u8 = 0x10;
    pub const write_data: u8 = 0x11;
    pub const write_lock: u8 = 0x14;
    pub const read_lock: u8 = 0x15;
    pub const protect_off: u8 = 0x18;
    pub const protect_on: u8 = 0x19;
    pub const read_jedec: u8 = 0x1d;
    pub const write_jedec: u8 = 0x1e;
    pub const write_bitstream: u8 = 0x26;
    pub const logic_ic_test_vector: u8 = 0x28;
    pub const reset_pin_drivers: u8 = 0x2d;
    pub const set_pulldowns: u8 = 0x32;
    pub const read_pins: u8 = 0x35;
    pub const set_pin_output: u8 = 0x36;
    pub const autodetect: u8 = 0x37;
    pub const request_status: u8 = 0x39;
};

pub const packet = struct {
    pub const system_info_request_len: usize = 5;
    // T48 returns a 63-byte short packet; byte 62 is the last field used by T48/T56.
    pub const system_info_response_min_len: usize = 63;
    pub const system_info_response_len: usize = 80;
    pub const short_command_len: usize = 8;
    pub const begin_len: usize = 64;
    pub const status_len: usize = 32;
    pub const chip_id_len: usize = 32;
    pub const erase_len: usize = 15;
    pub const t48_erase_ack_len: usize = short_command_len;
    pub const t48_min_read_payload_len: usize = 64;
    pub const erase_response_len: usize = 64;
    pub const bitstream_header_len: usize = 8;
    pub const jedec_read_len: usize = 32;
    pub const jedec_write_len: usize = 64;
    pub const fuse_len: usize = 64;
    pub const logic_vector_len: usize = 32;
    pub const pin_driver_len: usize = 48;
    pub const pin_read_response_len: usize = 48;
    pub const pin_read_min_len: usize = 13;
    pub const main_zif_pin_count: u8 = 40;

    /// T56 firmware returns the requested read payload plus a small status
    /// trailer. The native protocol caps payloads to keep that frame bounded.
    pub const t56_read_status_slop: usize = 16;
    pub const t56_read_payload_max: usize = 64;
    pub const t56_padded_write_payload_max: usize = 4096;
};
