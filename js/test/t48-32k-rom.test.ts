/// <reference types="node" />
import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import { WasmBridge, type UsbTransfer, type WasmExports } from "../src/wasm";

// Exercise the shipped Wasm catalog and operation engine, with USB simulated.
// This is not a physical chip model or evidence of electrical qualification.
async function bridge() {
  const { instance } = await WebAssembly.instantiate(
    readFileSync(new URL("../../dist/xgecu_web.wasm", import.meta.url)), {},
  );
  return new WasmBridge(instance.exports as unknown as WasmExports);
}

function t48(options: { chipId?: number; initialByte?: number; badId?: boolean; failedErase?: boolean; corruptReadback?: boolean; size?: number; readBufferSize?: number; byteRewrite?: boolean } = {}) {
  const memory = new Uint8Array(options.size ?? 32768).fill(options.initialByte ?? 0x00);
  const commands: number[] = [];
  const reads: number[] = [];
  const writes: number[] = [];
  let command = new Uint8Array();
  let wrote = false;
  let blankBytesRead = 0;
  return { memory, commands, reads, writes, transfer: async (transfer: UsbTransfer) => {
    if (transfer.direction === "out") {
      if (transfer.endpoint === 1) {
        command = transfer.data.slice();
        commands.push(command[0]!);
        if (command[0] === 0x0e) {
          blankBytesRead = 0;
          if (!options.failedErase) memory.fill(0xff);
        }
      } else {
        expect(transfer.endpoint).toBe(2);
        expect(command[0]).toBe(0x0c);
        // EPROM programming only clears bits; EEPROM has a byte-erase cycle.
        if (!options.byteRewrite) expect(blankBytesRead).toBe(memory.length);
        const view = new DataView(command.buffer);
        const address = view.getUint32(4, true);
        const length = view.getUint16(2, true);
        expect(length).toBe(128);
        expect(address + length).toBeLessThanOrEqual(memory.length);
        for (let i = 0; i < length; i += 1) {
          memory[address + i] = options.byteRewrite ? transfer.data[i]! : memory[address + i]! & transfer.data[i]!;
        }
        writes.push(address);
        wrote = true;
      }
      return;
    }
    if (transfer.endpoint === 2) {
      expect(command[0]).toBe(0x0d);
      const view = new DataView(command.buffer);
      const address = view.getUint32(4, true);
      const length = view.getUint16(2, true);
      expect(length).toBeLessThanOrEqual(options.readBufferSize ?? 1024);
      expect(address + length).toBeLessThanOrEqual(memory.length);
      reads.push(address);
      if (!wrote) blankBytesRead += length;
      const result = memory.slice(address, address + length);
      if (options.corruptReadback && wrote && address === 0x7c00) result[1023]! ^= 1;
      return result;
    }
    const response = new Uint8Array(transfer.length);
    if (command[0] === 0x00) { response[4] = 1; response[6] = 7; }
    else if (command[0] === 0x05) {
      response[0] = 1;
      const chipId = options.chipId ?? 0xda02;
      response[2] = chipId >>> 8;
      response[3] = options.badId ? 0xff : chipId & 0xff;
    }
    return response;
  } };
}

const writeOptions = {
  programmer: "t48" as const, memory: "code" as const,
  erase: true, verify: true, eraseNumFuses: 0, erasePld: 0,
  skipIdCheck: false, continueOnIdMismatch: false,
  unprotectBefore: false, protectAfter: false,
};

describe("W27C257 shipped T48 profile", () => {
  const device = "W27C257";
  it("reads and rewrites all 32768 bytes with erase, blank check and verification", async () => {
    const api = await bridge();
    const fake = t48();
    expect(api.deviceList({ programmer: "t48", search: device })).toMatchObject([{
      name: `${device}@DIP28`, codeMemorySize: 32768, packagePins: 28,
      canErase: true, supportsT48: true, supportsT56: false, supportsT76: false,
      supportsProtect: false, supportsUnprotect: false, supportsPinCheck: false,
    }]);
    const read = api.startReadROM({ ...writeOptions, device });
    expect(await api.runOperation(read, fake.transfer)).toEqual(fake.memory);
    const image = Uint8Array.from({ length: 32768 }, (_, i) => (i ^ (i >>> 8)) & 0xff);
    const write = api.startWriteROM({ ...writeOptions, device, data: image });
    await api.runOperation(write, fake.transfer);
    expect(fake.memory).toEqual(image);
    expect(fake.commands.filter((c) => c === 0x0e)).toHaveLength(1);
    expect(fake.commands.filter((c) => c === 0x05)).toHaveLength(2);
    expect(fake.commands).not.toContain(0x18);
    expect(fake.commands).not.toContain(0x19);
    expect(fake.writes).toEqual(Array.from({ length: 256 }, (_, i) => i * 128));
    expect(fake.reads).toEqual(Array.from({ length: 96 }, (_, i) => (i % 32) * 1024));
    expect(fake.commands.at(-1)).toBe(0x04);
  });

  it.each([32767, 32769, 65536])("rejects %i-byte erase/write before powering the chip", async (length) => {
    const api = await bridge();
    expect(() => api.startWriteROM({ ...writeOptions, device, data: new Uint8Array(length) }))
      .toThrow("InputTooLarge");
  });

  it.each([128, 32768])("blank-checks the full chip before an explicit no-erase %i-byte write", async (length) => {
    const api = await bridge();
    const fake = t48({ initialByte: 0xff });
    const image = new Uint8Array(length).fill(0x5a);
    await api.runOperation(api.startWriteROM({ ...writeOptions, device, erase: false, data: image }), fake.transfer);
    expect(fake.memory.subarray(0, length)).toEqual(image);
    expect(fake.memory.subarray(length).every((byte) => byte === 0xff)).toBe(true);
    expect(fake.commands).not.toContain(0x0e);
    expect(fake.writes).toEqual(Array.from({ length: length / 128 }, (_, i) => i * 128));
    expect(fake.reads).toEqual([
      ...Array.from({ length: 32 }, (_, i) => i * 1024),
      ...Array.from({ length: Math.ceil(length / 1024) }, (_, i) => i * 1024),
    ]);
    expect(fake.commands.at(-1)).toBe(0x04);
  });

  it.each([128, 32768])("refuses a no-erase %i-byte write when the final chip byte is nonblank", async (length) => {
    const api = await bridge();
    const fake = t48({ initialByte: 0xff });
    fake.memory[32767] = 0;
    await expect(api.runOperation(api.startWriteROM({
      ...writeOptions, device, erase: false, data: new Uint8Array(length),
    }), fake.transfer)).rejects.toMatchObject({ code: "TargetNotBlank" });
    expect(fake.writes).toHaveLength(0);
    expect(fake.commands).not.toContain(0x0e);
    expect(fake.memory[0]).toBe(0xff);
    expect(fake.commands.at(-1)).toBe(0x04);
  });

  it.each([
    [{ badId: true }, "ChipIdMismatch"],
    [{ failedErase: true }, "TargetNotBlank"],
    [{ corruptReadback: true }, "VerifyFailed"],
  ] as const)("fails closed for %j", async (fault, code) => {
    const api = await bridge();
    const fake = t48(fault);
    const handle = api.startWriteROM({ ...writeOptions, device, data: new Uint8Array(32768).fill(0x5a) });
    await expect(api.runOperation(handle, fake.transfer)).rejects.toMatchObject({ code });
    if (code !== "VerifyFailed") expect(fake.writes).toHaveLength(0);
    if (code === "ChipIdMismatch") expect(fake.commands).not.toContain(0x0e);
    expect(fake.commands.at(-1)).toBe(0x04);
  });

  it("rejects unsourced programmer profiles and protection operations", async () => {
    const api = await bridge();
    expect(api.resolveDevice(`${device}P-12`, "t48")).toBeNull();
    expect(api.resolveDevice(device, "t56")).toBeNull();
    expect(api.resolveDevice(device, "t76")).toBeNull();
    for (const protection of [{ unprotectBefore: true }, { protectAfter: true }]) {
      expect(() => api.startWriteROM({ ...writeOptions, ...protection, device, data: new Uint8Array(32768) }))
        .toThrow("ProtectionUnsupported");
    }
  });
});

it.each(["W27E257", "W27E257@DIP28", "W27E257-10", "W27E257-12", "W27E257-15"])(
  "rejects withheld %s before creating an operation", async (device) => {
    const api = await bridge();
    expect(api.resolveDevice(device, "t48")).toBeNull();
    expect(() => api.startReadROM({ ...writeOptions, device })).toThrow("device not found or unsupported");
    expect(() => api.startWriteROM({ ...writeOptions, device, data: new Uint8Array(32768) }))
      .toThrow("device not found or unsupported");
  },
);

it("preserves AT28C64B EEPROM rewriting without a full-chip erase or blank requirement", async () => {
  const api = await bridge();
  const fake = t48({ size: 8192, readBufferSize: 512, initialByte: 0, byteRewrite: true });
  const image = new Uint8Array(128).fill(0x5a);
  await api.runOperation(api.startWriteROM({
    ...writeOptions, device: "AT28C64B", erase: false, data: image,
  }), fake.transfer);
  expect(fake.memory.subarray(0, 128)).toEqual(image);
  expect(fake.memory.subarray(128).every((byte) => byte === 0)).toBe(true);
  expect(fake.commands).not.toContain(0x0e);
  expect(fake.writes).toEqual([0]);
  expect(fake.reads).toEqual([0]); // Requested verification only; no pre-write blank check.
  expect(fake.commands.at(-1)).toBe(0x04);
});

// ST's -10F1 and -12F1 grades use this same existing canonical profile;
// access speed is not a different programming algorithm (see the source note).
describe("M27C256B@DIP28 for -10F1 and -12F1 UV parts", () => {
  const device = "M27C256B@DIP28";

  it("rejects electrical erase and preserves the existing ST profile", async () => {
    const api = await bridge();
    expect(api.resolveDevice(device, "t48")).toMatchObject({
      codeMemorySize: 32768, packagePins: 28, chipId: 0x208d, chipIdBytesCount: 2,
      canErase: false, supportsT48: true,
      supportsUnprotect: false, supportsProtect: false,
    });
    expect(() => api.startWriteROM({ ...writeOptions, device, data: new Uint8Array(32768) }))
      .toThrow("EraseUnsupported");
  });

  it("blank-checks all 32 KiB before writing an externally erased part and verifies every byte", async () => {
    const api = await bridge();
    const fake = t48({ chipId: 0x208d, initialByte: 0xff });
    const image = Uint8Array.from({ length: 32768 }, (_, i) => (i ^ (i >>> 8)) & 0xff);
    await api.runOperation(api.startWriteROM({ ...writeOptions, device, erase: false, data: image }), fake.transfer);
    expect(fake.memory).toEqual(image);
    expect(fake.commands).not.toContain(0x0e);
    expect(fake.writes).toEqual(Array.from({ length: 256 }, (_, i) => i * 128));
    expect(fake.reads).toEqual(Array.from({ length: 64 }, (_, i) => (i % 32) * 1024));
    expect(fake.commands.at(-1)).toBe(0x04);
  });

  it("refuses programming when the final byte is not UV-erased", async () => {
    const api = await bridge();
    const fake = t48({ chipId: 0x208d, initialByte: 0xff });
    fake.memory[32767] = 0;
    const write = api.startWriteROM({ ...writeOptions, device, erase: false, data: new Uint8Array(32768) });
    await expect(api.runOperation(write, fake.transfer)).rejects.toMatchObject({ code: "TargetNotBlank" });
    expect(fake.commands).not.toContain(0x0e);
    expect(fake.writes).toHaveLength(0);
    expect(fake.commands.at(-1)).toBe(0x04);
  });
});
