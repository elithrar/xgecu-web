import { StrictMode, useEffect, useMemo, useState } from "react";
import { createRoot } from "react-dom/client";
import { createProgrammer } from "xgecu-web";
import type { DeviceSummary, ProgrammerConnection, XgecuWebUSB } from "xgecu-web";
import "./styles.css";

function App() {
  const [api, setApi] = useState<XgecuWebUSB | null>(null);
  const [programmer, setProgrammer] = useState<ProgrammerConnection | null>(null);
  const [query, setQuery] = useState("AT28");
  const [selectedDevice, setSelectedDevice] = useState("AT28C64B@DIP28");
  const [rom, setRom] = useState<Uint8Array | null>(null);
  const [writeImage, setWriteImage] = useState<Uint8Array | null>(null);
  const [downloadUrl, setDownloadUrl] = useState<string | undefined>();
  const [skipIdCheck, setSkipIdCheck] = useState(false);
  const [confirmWrite, setConfirmWrite] = useState(false);
  const [status, setStatus] = useState("Loading Wasm...");

  useEffect(() => {
    createProgrammer()
      .then((created) => {
        setApi(created);
        setStatus("Ready. Connect a T48/T56 programmer to begin.");
      })
      .catch((error: unknown) => setStatus(error instanceof Error ? error.message : String(error)));
  }, []);

  useEffect(() => {
    return () => {
      void programmer?.close();
    };
  }, [programmer]);

  const deviceList = useMemo(() => {
    if (!api) return { devices: [] as DeviceSummary[], error: null as Error | null };
    try {
      return { devices: api.deviceList({ search: query, limit: 25 }), error: null };
    } catch (error) {
      return { devices: [] as DeviceSummary[], error: error instanceof Error ? error : new Error(String(error)) };
    }
  }, [api, query]);
  const devices = deviceList.devices;
  const selectedSummary = useMemo(() => devices.find((device) => device.name === selectedDevice) ?? null, [devices, selectedDevice]);
  const canWrite = Boolean(api && programmer && writeImage && rom && writeImage.byteLength === rom.byteLength && confirmWrite);

  useEffect(() => {
    if (deviceList.error) setStatus(deviceList.error.message);
  }, [deviceList.error]);

  useEffect(() => {
    if (!rom) {
      setDownloadUrl(undefined);
      return;
    }

    const url = URL.createObjectURL(new Blob([toArrayBuffer(rom)], { type: "application/octet-stream" }));
    setDownloadUrl(url);
    return () => URL.revokeObjectURL(url);
  }, [rom]);

  useEffect(() => {
    setRom(null);
    setWriteImage(null);
    setConfirmWrite(false);
  }, [selectedDevice]);

  async function connect() {
    if (!api) return;
    setStatus("Requesting WebUSB device...");
    try {
      const connection = await api.requestProgrammer();
      await programmer?.close();
      setProgrammer(connection);
      setStatus(`Connected to ${connection.productName ?? "programmer"}.`);
    } catch (error) {
      setStatus(error instanceof Error ? error.message : String(error));
    }
  }

  async function readRom() {
    if (!api || !programmer) return;
    setStatus(`Reading ${selectedDevice}...`);
    try {
      const data = await api.readROM({
        programmer,
        device: selectedDevice,
        skipIdCheck,
        onProgress: (event) => setStatus(`${event.phase}: ${event.offset}/${event.total} bytes`)
      });
      setRom(data);
      setStatus(`Read ${data.byteLength} bytes from ${selectedDevice}.`);
    } catch (error) {
      setStatus(error instanceof Error ? error.message : String(error));
    }
  }

  async function writeRom() {
    if (!api || !programmer || !writeImage || !rom || !confirmWrite) return;
    if (writeImage.byteLength !== rom.byteLength) {
      setStatus(`Image size mismatch: expected ${rom.byteLength} bytes, got ${writeImage.byteLength}.`);
      return;
    }
    setStatus(`Writing ${writeImage.byteLength} bytes to ${selectedDevice}...`);
    try {
      await api.writeROM({
        programmer,
        device: selectedDevice,
        data: writeImage,
        erase: true,
        verify: true,
        skipIdCheck,
        onProgress: (event) => setStatus(`${event.phase}: ${event.offset}/${event.total} bytes`)
      });
      setStatus("Write and verify complete.");
    } catch (error) {
      setStatus(error instanceof Error ? error.message : String(error));
    }
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
        {selectedSummary ? (
          <p className="note">
            {selectedSummary.packagePins} pins, {selectedSummary.codeMemorySize} code bytes, page size {selectedSummary.pageSize}
            {selectedSummary.chipIdBytesCount ? `, chip ID 0x${selectedSummary.chipId.toString(16)}` : ", no catalogued chip ID"}.
          </p>
        ) : (
          <p className="warning">Selected device is not in the current search results.</p>
        )}
      </section>

      <section className="actions">
        <button disabled={!api || !programmer} onClick={() => void readRom()}>
          Read ROM
        </button>
        <a
          className={rom ? "button" : "button disabled"}
          download={`${selectedDevice}.bin`}
          href={downloadUrl}
        >
          Download readback
        </a>
      </section>

      <section>
        <label>
          ROM image to write
          <input type="file" onChange={(event) => void onFileSelected(event.currentTarget.files?.[0])} />
        </label>
        <label className="checkbox">
          <input type="checkbox" checked={skipIdCheck} onChange={(event) => setSkipIdCheck(event.currentTarget.checked)} />
          Skip chip ID check only if you have externally identified the chip
        </label>
        <label className="checkbox warning">
          <input type="checkbox" checked={confirmWrite} onChange={(event) => setConfirmWrite(event.currentTarget.checked)} />
          I saved the readback, confirmed chip orientation, and verified the image length
        </label>
        {writeImage && rom && writeImage.byteLength !== rom.byteLength ? (
          <p className="warning">Image size mismatch: expected {rom.byteLength} bytes, got {writeImage.byteLength}.</p>
        ) : null}
        {!rom ? <p className="note">Read and download a backup before writing is enabled.</p> : null}
        <button disabled={!canWrite} onClick={() => void writeRom()}>
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
