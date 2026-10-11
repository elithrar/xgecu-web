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

function t48(options: { badId?: boolean; failedErase?: boolean; corruptReadback?: boolean } = {}) {
  const memory = new Uint8Array(32768).fill(0x00);
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
        if (command[0] === 0x0e && !options.failedErase) memory.fill(0xff);
      } else {
        expect(transfer.endpoint).toBe(2);
        expect(command[0]).toBe(0x0c);
        // A full blank check must finish before the first programming payload.
        expect(blankBytesRead).toBe(32768);
        const view = new DataView(command.buffer);
        const address = view.getUint32(4, true);
        const length = view.getUint16(2, true);
        expect(length).toBe(128);
        expect(address + length).toBeLessThanOrEqual(memory.length);
        memory.set(transfer.data.subarray(0, length), address);
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
      expect(length).toBe(1024);
      expect(address + length).toBeLessThanOrEqual(memory.length);
      reads.push(address);
      if (commands.includes(0x0e) && !wrote) blankBytesRead += length;
      const result = memory.slice(address, address + length);
      if (options.corruptReadback && wrote && address === 0x7c00) result[1023]! ^= 1;
      return result;
    }
    const response = new Uint8Array(transfer.length);
    if (command[0] === 0x00) { response[4] = 1; response[6] = 7; }
    else if (command[0] === 0x05) {
      response[0] = 1;
      response[2] = 0xda;
      response[3] = options.badId ? 0xff : 0x02;
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

describe.each(["W27C257", "W27E257"])("%s shipped T48 profile", (device) => {
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
