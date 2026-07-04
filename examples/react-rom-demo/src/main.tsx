import { StrictMode, useEffect, useMemo, useState } from "react";
import { createRoot } from "react-dom/client";
import { createProgrammer } from "@xgecu/webusb";
import type { DeviceSummary, ProgrammerConnection, XgecuWebUSB } from "@xgecu/webusb";
import "./styles.css";

function App() {
  const [api, setApi] = useState<XgecuWebUSB | null>(null);
  const [programmer, setProgrammer] = useState<ProgrammerConnection | null>(null);
  const [query, setQuery] = useState("AT28");
  const [selectedDevice, setSelectedDevice] = useState("AT28C64B@DIP28");
  const [rom, setRom] = useState<Uint8Array | null>(null);
  const [writeImage, setWriteImage] = useState<Uint8Array | null>(null);
  const [status, setStatus] = useState("Loading Wasm...");

  useEffect(() => {
    createProgrammer()
      .then((created) => {
        setApi(created);
        setStatus("Ready. Connect a T48/T56 programmer to begin.");
      })
      .catch((error: unknown) => setStatus(error instanceof Error ? error.message : String(error)));
  }, []);

  const devices: DeviceSummary[] = useMemo(() => api?.deviceList({ search: query, limit: 25 }) ?? [], [api, query]);

  async function connect() {
    if (!api) return;
    setStatus("Requesting WebUSB device...");
    const connection = await api.requestProgrammer();
    setProgrammer(connection);
    setStatus(`Connected to ${connection.productName ?? "programmer"}.`);
  }

  async function readRom() {
    if (!api || !programmer) return;
    setStatus(`Reading ${selectedDevice}...`);
    const data = await api.readROM({ programmer, device: selectedDevice, skipIdCheck: true });
    setRom(data);
    setStatus(`Read ${data.byteLength} bytes from ${selectedDevice}.`);
  }

  async function writeRom() {
    if (!api || !programmer || !writeImage) return;
    setStatus(`Writing ${writeImage.byteLength} bytes to ${selectedDevice}...`);
    await api.writeROM({
      programmer,
      device: selectedDevice,
      data: writeImage,
      erase: true,
      verify: true,
      skipIdCheck: true
    });
    setStatus("Write and verify complete.");
  }

  async function onFileSelected(file: File | undefined) {
    if (!file) return;
    const bytes = new Uint8Array(await file.arrayBuffer());
    setWriteImage(bytes);
    setStatus(`Loaded ${bytes.byteLength} bytes from ${file.name}.`);
  }

  return (
    <main>
      <h1>XGecu T48/T56 WebUSB ROM Demo</h1>
      <p className="note">Use HTTPS or localhost in a Chromium-based browser. Write operations are destructive.</p>

      <section>
        <button disabled={!api} onClick={() => void connect()}>
          Connect programmer
        </button>
        <span>{programmer ? `Connected: ${programmer.productName ?? programmer.serialNumber ?? "T48/T56"}` : "No programmer connected"}</span>
      </section>

      <section>
        <label>
          Search target devices
          <input value={query} onChange={(event) => setQuery(event.target.value)} />
        </label>
        <label>
          Device
          <select value={selectedDevice} onChange={(event) => setSelectedDevice(event.target.value)}>
            {devices.map((device) => (
              <option key={device.name} value={device.name}>
                {device.name} ({device.codeMemorySize} bytes)
              </option>
            ))}
          </select>
        </label>
      </section>

      <section className="actions">
        <button disabled={!api || !programmer} onClick={() => void readRom()}>
          Read ROM
        </button>
        <a
          className={rom ? "button" : "button disabled"}
          download={`${selectedDevice}.bin`}
          href={rom ? URL.createObjectURL(new Blob([toArrayBuffer(rom)], { type: "application/octet-stream" })) : undefined}
        >
          Download readback
        </a>
      </section>

      <section>
        <label>
          ROM image to write
          <input type="file" onChange={(event) => void onFileSelected(event.currentTarget.files?.[0])} />
        </label>
        <button disabled={!api || !programmer || !writeImage} onClick={() => void writeRom()}>
          Write ROM with erase + verify
        </button>
      </section>

      <pre>{status}</pre>
    </main>
  );
}

function toArrayBuffer(bytes: Uint8Array): ArrayBuffer {
  const copy = new Uint8Array(bytes.byteLength);
  copy.set(bytes);
  return copy.buffer;
}

createRoot(document.getElementById("root")!).render(
  <StrictMode>
    <App />
  </StrictMode>
);
