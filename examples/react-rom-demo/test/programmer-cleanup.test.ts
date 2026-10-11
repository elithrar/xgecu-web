import { readFileSync } from "node:fs";
import { afterEach, expect, it, vi } from "vitest";
import { createProgrammer, type USBDeviceLike } from "xgecu-web";
import { closeProgrammerConnection, hasPendingProgrammerCloses, retryProgrammerCloses, subscribeProgrammerCleanup } from "../src/programmer-cleanup";

afterEach(() => vi.restoreAllMocks());

async function setup() {
  vi.spyOn(globalThis, "fetch").mockResolvedValueOnce(new Response(
    readFileSync(new URL("../../../dist/xgecu_web.wasm", import.meta.url)),
  ));
  let failClose = false;
  const device: USBDeviceLike = {
    vendorId: 0xa466, productId: 0x0a53, opened: false, configuration: null,
    async open() { Object.assign(this, { opened: true }); },
    close: vi.fn(async () => {
      if (failClose) throw new DOMException("USB close rejected", "NetworkError");
      Object.assign(device, { opened: false });
    }),
    async selectConfiguration(configurationValue) { Object.assign(this, { configuration: { configurationValue } }); },
    async claimInterface() {},
    async releaseInterface() {},
    async transferOut(_endpoint, bytes) { return { status: "ok", bytesWritten: bytes.byteLength }; },
    async transferIn(_endpoint, length) { return { status: "ok", data: new DataView(new ArrayBuffer(length)) }; },
  };
  const api = await createProgrammer({ usb: { requestDevice: async () => device, getDevices: async () => [device] } });
  return { api, device, fail: (value: boolean) => { failClose = value; } };
}

it("retains a failed SDK close across consumer teardown and retries without leaking a USB reference", async () => {
  const { api, device, fail } = await setup();
  const connection = await api.requestProgrammer();
  const notifications: boolean[] = [];
  const unsubscribe = subscribeProgrammerCleanup(() => notifications.push(hasPendingProgrammerCloses()));
  try {
    fail(true);
    await expect(closeProgrammerConnection(connection)).rejects.toThrow("USB close rejected");
    expect(hasPendingProgrammerCloses()).toBe(true);
    await expect(retryProgrammerCloses()).rejects.toThrow("USB close rejected");
    expect(device.opened).toBe(true);
    fail(false);
    await retryProgrammerCloses();
    expect(hasPendingProgrammerCloses()).toBe(false);
    expect(device.opened).toBe(false);
    const next = await api.requestProgrammer();
    await closeProgrammerConnection(next);
    expect(device.opened).toBe(false);
    expect(device.close).toHaveBeenCalledTimes(4);
    expect(notifications[0]).toBe(true);
    expect(notifications.at(-1)).toBe(false);
  } finally {
    fail(false);
    await retryProgrammerCloses();
    unsubscribe();
  }
});

it("waits for a rejected active operation and joins concurrent cleanup retries", async () => {
  const { api, device } = await setup();
  const connection = await api.requestProgrammer();
  let rejectOperation!: (error: Error) => void;
  const settled = new Promise<void>((_resolve, reject) => { rejectOperation = reject; });
  const closing = closeProgrammerConnection(connection, settled);
  expect(hasPendingProgrammerCloses()).toBe(true);
  const retry = retryProgrammerCloses();
  expect(device.close).not.toHaveBeenCalled();
  rejectOperation(new Error("Operation cancelled"));
  await Promise.all([closing, retry]);
  expect(device.close).toHaveBeenCalledOnce();
  expect(device.opened).toBe(false);
  expect(hasPendingProgrammerCloses()).toBe(false);
});
