/// <reference types="node" />
import { readFileSync } from "node:fs";
import { describe, expect, it, vi } from "vitest";
import { WasmBridge, type UsbTransfer, type WasmExports } from "../src/wasm";

async function bridge() {
  const { instance } = await WebAssembly.instantiate(
    readFileSync(new URL("../../dist/xgecu_web.wasm", import.meta.url)), {},
  );
  return new WasmBridge(instance.exports as unknown as WasmExports);
}

// Fault injection checks host cleanup only; it cannot prove socket power-down.
function simulatedT48(size: number, chipId: number, failBegin: number, failCleanup = false) {
  const memory = new Uint8Array(size).fill(0xff);
  const commands: number[] = [];
  let command = new Uint8Array();
  let begins = 0;
  let beginFailed = false;
  return { commands, transfer: async (transfer: UsbTransfer) => {
    if (transfer.direction === "out") {
      if (transfer.endpoint === 1) {
        command = transfer.data.slice();
        commands.push(command[0]!);
        if (command[0] === 0x03 && ++begins === failBegin) {
          beginFailed = true;
          // Transfer rejection cannot establish whether firmware received BEGIN.
          throw new Error("Ambiguous BEGIN transfer failure");
        }
        if (command[0] === 0x04 && beginFailed && failCleanup) throw new Error("END transfer failed");
        if (command[0] === 0x0e) memory.fill(0xff);
      } else {
        const view = new DataView(command.buffer);
        memory.set(transfer.data.subarray(0, view.getUint16(2, true)), view.getUint32(4, true));
      }
      return;
    }
    if (transfer.endpoint === 2) {
      const view = new DataView(command.buffer);
      const result = new Uint8Array(transfer.length);
      result.set(memory.subarray(view.getUint32(4, true), view.getUint32(4, true) + view.getUint16(2, true)));
      return result;
    }
    const response = new Uint8Array(transfer.length);
    if (command[0] === 0x00) { response[4] = 1; response[6] = 7; }
    if (command[0] === 0x05) { response[0] = 1; response[2] = chipId >>> 8; response[3] = chipId & 0xff; }
    return response;
  } };
}

const profiles = [
  { device: "W27C257", size: 32768, chipId: 0xda02, erase: true },
  { device: "M27C256B", size: 32768, chipId: 0x208d, erase: false },
  { device: "AT28C64B", size: 8192, chipId: 0, erase: true },
] as const;

describe.each(profiles)("$device T48 cleanup after ambiguous BEGIN", (profile) => {
  // Initial, post-ID, post-erase (if used), post-blank, and pre-verification.
  // AT28C64B has no chip-ID transaction in this catalog.
  const stages = Array.from({ length: (profile.erase ? 4 : 3) + (profile.chipId ? 1 : 0) }, (_, i) => i + 1);
  it.each(stages)("sends END if BEGIN number %i fails", async (failBegin) => {
    const api = await bridge();
    const fake = simulatedT48(profile.size, profile.chipId, failBegin);
    const onCleanupFailure = vi.fn();
    const handle = api.startWriteROM({
      programmer: "t48", device: profile.device, memory: "code",
      data: new Uint8Array(profile.size).fill(0x5a),
      erase: profile.erase, eraseNumFuses: 0, erasePld: 0, verify: true,
      skipIdCheck: false, continueOnIdMismatch: false, unprotectBefore: false, protectAfter: false,
    });
    await expect(api.runOperation(handle, fake.transfer, { onCleanupFailure }))
      .rejects.toThrow("Ambiguous BEGIN transfer failure");
    expect(fake.commands.at(-1)).toBe(0x04);
    expect(fake.commands.filter((command) => command === 0x03)).toHaveLength(failBegin);
    expect(onCleanupFailure).not.toHaveBeenCalled();
    await expect(api.runOperation(handle, fake.transfer)).rejects.toMatchObject({ code: "InvalidInput" });
  });

  it("reports unknown hardware state when END also fails", async () => {
    const api = await bridge();
    const fake = simulatedT48(profile.size, profile.chipId, 1, true);
    const onCleanupFailure = vi.fn();
    const handle = api.startReadROM({
      programmer: "t48", device: profile.device, memory: "code", skipIdCheck: false, continueOnIdMismatch: false,
    });
    await expect(api.runOperation(handle, fake.transfer, { onCleanupFailure }))
      .rejects.toMatchObject({ code: "WebUSBLifecycleFailed" });
    expect(fake.commands).toEqual([0x00, 0x03, 0x04]);
    expect(onCleanupFailure).toHaveBeenCalledOnce();
  });
});
