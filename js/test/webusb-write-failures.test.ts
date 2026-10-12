import { readFileSync } from "node:fs";
import { afterEach, describe, expect, it, vi } from "vitest";
import { createProgrammer } from "../src/webusb";
import type { USBConfigurationLike, USBDeviceLike } from "../src/types";

// Exercise the public API and shipped Wasm, with USB fault injection only.
// No physical hardware or electrical qualification is involved.
function simulatedT48(fault: "erase" | "write" | "abort" | "cleanup", controller: AbortController) {
  const commands: number[] = [];
  const cause = new DOMException("Ambiguous USB transfer failure", "NetworkError");
  let command = new Uint8Array();
  let programmingBlocks = 0;
  let failed = false;
  const device = {
    opened: false as boolean, vendorId: 0xa466, productId: 0x0a53,
    configuration: null as USBConfigurationLike | null,
    async open() { device.opened = true; },
    async close() { device.opened = false; },
    async selectConfiguration(configurationValue) { device.configuration = { configurationValue }; },
    async claimInterface() {},
    async releaseInterface() {},
    async transferOut(endpoint, input) {
      const data = input instanceof ArrayBuffer
        ? new Uint8Array(input)
        : new Uint8Array(input.buffer, input.byteOffset, input.byteLength);
      if (endpoint === 1) {
        command = data.slice();
        commands.push(command[0]!);
        if (command[0] === 0x0e && fault === "erase") {
          failed = true;
          throw cause;
        }
        if (command[0] === 0x04 && failed && fault === "cleanup") throw new Error("END failed");
      } else {
        expect(endpoint).toBe(2);
        expect(command[0]).toBe(0x0c);
        programmingBlocks += 1;
        // A rejected transfer may already have reached the chip.
        failed = true;
        if (fault === "abort") controller.abort();
        else throw cause;
      }
      return { status: "ok", bytesWritten: data.byteLength };
    },
    async transferIn(endpoint, length) {
      const response = new Uint8Array(length);
      if (endpoint === 2) response.fill(0xff);
      else if (command[0] === 0x00) { response[4] = 1; response[6] = 7; }
      else if (command[0] === 0x05) { response[0] = 1; response[2] = 0xda; response[3] = 0x02; }
      return { status: "ok", data: new DataView(response.buffer) };
    },
  } satisfies USBDeviceLike;
  return { device, commands, cause, programmingBlocks: () => programmingBlocks };
}

afterEach(() => vi.unstubAllGlobals());

describe("write failures through the public API", () => {
  it.each(["erase", "write", "abort", "cleanup"] as const)(
    "does not replay a partially completed operation after %s failure",
    async (fault) => {
      vi.stubGlobal("fetch", async () => new Response(readFileSync(new URL("../../dist/xgecu_web.wasm", import.meta.url))));
      const controller = new AbortController();
      const fake = simulatedT48(fault, controller);
      const api = await createProgrammer({ usb: {
        getDevices: async () => [fake.device], requestDevice: async () => fake.device
      } });
      const programmer = await api.requestProgrammer();
      const write = api.writeROM({
        programmer, programmerKind: "t48", device: "W27C257@DIP28",
        data: new Uint8Array(32768).fill(0x5a), erase: true, verify: true,
        signal: controller.signal,
      });
      if (fault === "abort") {
        await expect(write).rejects.toMatchObject({ code: "OperationAborted" });
      } else if (fault === "cleanup") {
        await expect(write).rejects.toMatchObject({
          code: "WebUSBLifecycleFailed",
          cause: { code: "WebUSBTransferFailed", cause: fake.cause },
        });
      } else {
        await expect(write).rejects.toMatchObject({ code: "WebUSBTransferFailed", cause: fake.cause });
      }
      expect(fake.commands.filter(command => command === 0x0e)).toHaveLength(1);
      expect(fake.programmingBlocks()).toBe(fault === "erase" ? 0 : 1);
      expect(fake.commands.at(-1)).toBe(0x04); // END cleanup was attempted.
      // The operation lock must be released even on failure/cancellation.
      await programmer.close();
      expect(fake.device.opened).toBe(false);
      if (fault === "cleanup") {
        const count = fake.commands.length;
        await expect(api.connectProgrammer(fake.device)).rejects.toMatchObject({ code: "WebUSBLifecycleFailed" });
        expect(fake.commands).toHaveLength(count);
      }
    },
  );
});
