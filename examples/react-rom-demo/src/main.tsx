import { StrictMode, useEffect, useMemo, useRef, useState } from "react";
import { createRoot } from "react-dom/client";
import { Badge } from "@cloudflare/kumo/components/badge";
import { Banner } from "@cloudflare/kumo/components/banner";
import { Button, LinkButton } from "@cloudflare/kumo/components/button";
import { Checkbox } from "@cloudflare/kumo/components/checkbox";
import { Input } from "@cloudflare/kumo/components/input";
import { LayerCard } from "@cloudflare/kumo/components/layer-card";
import { Select } from "@cloudflare/kumo/components/select";
import { Text } from "@cloudflare/kumo/components/text";
import { createProgrammer } from "xgecu-web";
import type { DeviceSummary, ProgrammerConnection, RomProgressEvent, XgecuWebUSB } from "xgecu-web";
import "@cloudflare/kumo/styles/standalone";
import "./styles.css";

type LogEntry = Record<string, unknown> & {
  timestamp: string;
  level: "info" | "error";
  event: string;
};

type Backup = {
  data: Uint8Array;
  target: string;
  connectionId: number;
};

const MAX_LOG_ENTRIES = 250;
let programmerApiPromise: Promise<XgecuWebUSB> | undefined;

function App() {
  const [api, setApi] = useState<XgecuWebUSB | null>(null);
  const [programmer, setProgrammer] = useState<ProgrammerConnection | null>(null);
  const [query, setQuery] = useState("AT28");
  const [selectedDevice, setSelectedDevice] = useState("AT28C64B@DIP28");
  const [backup, setBackup] = useState<Backup | null>(null);
  const [writeImage, setWriteImage] = useState<Uint8Array | null>(null);
  const [downloadUrl, setDownloadUrl] = useState<string | undefined>();
  const [skipIdCheck, setSkipIdCheck] = useState(false);
  const [confirmWrite, setConfirmWrite] = useState(false);
  const [status, setStatus] = useState("Loading Wasm...");
  const [busy, setBusy] = useState(false);
  const [logs, setLogs] = useState<LogEntry[]>([
    logEntry("info", "wasm_loading")
  ]);
  const operationSequence = useRef(0);
  const connectionSequence = useRef(0);
  const activeAbort = useRef<AbortController | null>(null);
  const activeOperation = useRef<Promise<unknown> | null>(null);
  const activeToken = useRef<symbol | null>(null);
  const pendingConnection = useRef<ProgrammerConnection | null>(null);
  const fileSequence = useRef(0);

  function appendLog(level: LogEntry["level"], event: string, fields: Record<string, unknown> = {}) {
    const entry = logEntry(level, event, fields);
    setLogs((current) => [...current.slice(-(MAX_LOG_ENTRIES - 1)), entry]);
    if (level === "error") console.error(entry);
    else console.info(entry);
  }

  useEffect(() => {
    let cancelled = false;
    programmerApiPromise ??= createProgrammer();
    programmerApiPromise
      .then((created) => {
        if (cancelled) return;
        setApi(created);
        setStatus("Ready. Connect a T48/T56 programmer to begin.");
        appendLog("info", "wasm_loaded");
      })
      .catch((error: unknown) => {
        if (cancelled) return;
        setStatus(errorMessage(error));
        appendLog("error", "wasm_load_failed", errorFields(error));
      });
    return () => {
      cancelled = true;
    };
  }, []);

  useEffect(() => {
    return () => {
      activeAbort.current?.abort();
      const settled = activeOperation.current ?? Promise.resolve();
      void settled.finally(async () => {
        await Promise.allSettled([
          pendingConnection.current?.close(),
          programmer?.close()
        ]);
      }).catch(() => undefined);
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
  const deviceItems = useMemo(
    () => Object.fromEntries(devices.map((device) => [device.name, `${device.name} (${device.codeMemorySize} bytes)`])),
    [devices]
  );
  const selectedSummary = useMemo(() => devices.find((device) => device.name === selectedDevice) ?? null, [devices, selectedDevice]);
  const canWrite = Boolean(
    api && programmer && writeImage && backup && !busy &&
    backup.target === selectedDevice && backup.connectionId === connectionSequence.current &&
    writeImage.byteLength === backup.data.byteLength && confirmWrite
  );

  useEffect(() => {
    if (deviceList.error) setStatus(deviceList.error.message);
  }, [deviceList.error]);

  useEffect(() => {
    if (!backup) {
      setDownloadUrl(undefined);
      return;
    }

    const url = URL.createObjectURL(new Blob([toArrayBuffer(backup.data)], { type: "application/octet-stream" }));
    setDownloadUrl(url);
    return () => URL.revokeObjectURL(url);
  }, [backup]);

  useEffect(() => {
    setBackup(null);
    setWriteImage(null);
    setConfirmWrite(false);
  }, [selectedDevice]);

  async function connect() {
    if (!api || activeToken.current) return;
    const token = Symbol("connect");
    activeToken.current = token;
    setBusy(true);
    setStatus("Requesting WebUSB device...");
    appendLog("info", "programmer_request_started");
    try {
      const operation = api.requestProgrammer();
      activeOperation.current = operation;
      const connection = await operation;
      pendingConnection.current = connection;
      await programmer?.close();
      connectionSequence.current += 1;
      setProgrammer(connection);
      pendingConnection.current = null;
      setBackup(null);
      setWriteImage(null);
      setConfirmWrite(false);
      setStatus(`Connected to ${connection.productName ?? "programmer"}.`);
      appendLog("info", "programmer_connected", programmerFields(connection));
    } catch (error) {
      setStatus(errorMessage(error));
      appendLog("error", "programmer_connection_failed", errorFields(error));
    } finally {
      if (pendingConnection.current) {
        await pendingConnection.current.close().catch(() => undefined);
        pendingConnection.current = null;
      }
      if (activeToken.current === token) {
        activeToken.current = null;
        activeOperation.current = null;
        setBusy(false);
      }
    }
  }

  async function readRom() {
    if (!api || !programmer || activeToken.current) return;
    const token = Symbol("read");
    activeToken.current = token;
    const target = selectedDevice;
    const connectionId = connectionSequence.current;
    const controller = new AbortController();
    const operationId = `read-${++operationSequence.current}`;
    const startedAt = performance.now();
    let lastProgress: RomProgressEvent | undefined;
    setBusy(true);
    setBackup(null);
    setConfirmWrite(false);
    activeAbort.current = controller;
    setStatus(`Reading ${selectedDevice}...`);
    appendLog("info", "rom_read_started", {
      operation_id: operationId,
      target_device: selectedDevice,
      memory: "code",
      expected_bytes: selectedSummary?.codeMemorySize,
      skip_id_check: skipIdCheck,
      programmer: programmerFields(programmer)
    });
    try {
      const operation = api.readROM({
        programmer,
        device: target,
        skipIdCheck,
        signal: controller.signal,
        onProgress: (event) => {
          lastProgress = event;
          setStatus(`${event.phase}: ${event.offset}/${event.total} bytes`);
          appendLog("info", "rom_read_progressed", progressFields(operationId, event));
        }
      });
      activeOperation.current = operation;
      const data = await operation;
      if (connectionId !== connectionSequence.current || target !== selectedDevice) return;
      setBackup({ data, target, connectionId });
      setStatus(`Read ${data.byteLength} bytes from ${target}.`);
      appendLog("info", "rom_read_completed", {
        operation_id: operationId,
        target_device: target,
        bytes_read: data.byteLength,
        duration_ms: Math.round(performance.now() - startedAt)
      });
    } catch (error) {
      setStatus(errorMessage(error));
      appendLog("error", "rom_read_failed", {
        operation_id: operationId,
        target_device: selectedDevice,
        memory: "code",
        expected_bytes: selectedSummary?.codeMemorySize,
        skip_id_check: skipIdCheck,
        duration_ms: Math.round(performance.now() - startedAt),
        last_progress: lastProgress,
        programmer: programmerFields(programmer),
        ...errorFields(error)
      });
    } finally {
      if (activeToken.current === token) {
        activeToken.current = null;
        activeAbort.current = null;
        activeOperation.current = null;
        setBusy(false);
      }
    }
  }

  async function writeRom() {
    if (!api || !programmer || !writeImage || !backup || !confirmWrite || activeToken.current) return;
    if (backup.target !== selectedDevice || backup.connectionId !== connectionSequence.current) return;
    if (writeImage.byteLength !== backup.data.byteLength) {
      setStatus(`Image size mismatch: expected ${backup.data.byteLength} bytes, got ${writeImage.byteLength}.`);
      return;
    }
    const token = Symbol("write");
    activeToken.current = token;
    const controller = new AbortController();
    const operationId = `write-${++operationSequence.current}`;
    const startedAt = performance.now();
    let lastProgress: RomProgressEvent | undefined;
    setBusy(true);
    activeAbort.current = controller;
    setStatus(`Writing ${writeImage.byteLength} bytes to ${selectedDevice}...`);
    appendLog("info", "rom_write_started", {
      operation_id: operationId,
      target_device: selectedDevice,
      memory: "code",
      image_bytes: writeImage.byteLength,
      erase: true,
      verify: true,
      skip_id_check: skipIdCheck,
      programmer: programmerFields(programmer)
    });
    try {
      const operation = api.writeROM({
        programmer,
        device: selectedDevice,
        data: writeImage,
        erase: true,
        verify: true,
        skipIdCheck,
        signal: controller.signal,
        onProgress: (event) => {
          lastProgress = event;
          setStatus(`${event.phase}: ${event.offset}/${event.total} bytes`);
          appendLog("info", "rom_write_progressed", progressFields(operationId, event));
        }
      });
      activeOperation.current = operation;
      await operation;
      setStatus("Write and verify complete.");
      appendLog("info", "rom_write_completed", {
        operation_id: operationId,
        target_device: selectedDevice,
        bytes_written: writeImage.byteLength,
        duration_ms: Math.round(performance.now() - startedAt)
      });
    } catch (error) {
      setStatus(errorMessage(error));
      appendLog("error", "rom_write_failed", {
        operation_id: operationId,
        target_device: selectedDevice,
        image_bytes: writeImage.byteLength,
        duration_ms: Math.round(performance.now() - startedAt),
        last_progress: lastProgress,
        programmer: programmerFields(programmer),
        ...errorFields(error)
      });
    } finally {
      if (activeToken.current === token) {
        activeToken.current = null;
        activeAbort.current = null;
        activeOperation.current = null;
        setBackup(null);
        setConfirmWrite(false);
        setBusy(false);
      }
    }
  }

  async function onFileSelected(file: File | undefined) {
    if (!file) return;
    const selection = ++fileSequence.current;
    setWriteImage(null);
    setConfirmWrite(false);
    const bytes = new Uint8Array(await file.arrayBuffer());
    if (selection !== fileSequence.current) return;
    setWriteImage(bytes);
    setStatus(`Loaded ${bytes.byteLength} bytes from ${file.name}.`);
    appendLog("info", "rom_image_loaded", { file_name: file.name, image_bytes: bytes.byteLength });
  }

  function setSelectedDeviceValue(value: unknown) {
    if (typeof value === "string") setSelectedDevice(value);
  }

  return (
    <main className="app-shell">
      <header className="hero">
        <Text variant="heading1" as="h1">XGecu T48/T56 WebUSB ROM Demo</Text>
        <div className="banner-stack">
          <Banner
            variant="alert"
            title="Write operations are destructive"
            description="Use HTTPS or localhost in a Chromium-based browser, and always read and save a backup before writing."
          />
          <Banner
            variant="secondary"
            title="Catalog status"
            description="The seed catalog currently contains T48 targets only; T56 operations require validated T56 catalog records and algorithm payloads."
          />
        </div>
      </header>

      <LayerCard className="panel">
        <LayerCard.Secondary className="panel-heading">
          <Text variant="heading3" as="h2">Programmer</Text>
          <Badge variant={programmer ? "success" : "neutral"} appearance="dot">
            {programmer ? "Connected" : "Disconnected"}
          </Badge>
        </LayerCard.Secondary>
        <LayerCard.Primary className="panel-body connect-panel">
          <Button variant="primary" disabled={!api || busy} loading={busy && !programmer} onClick={() => void connect()}>
            Connect programmer
          </Button>
          <Text variant="secondary">
            {programmer ? `Connected: ${programmer.productName ?? programmer.serialNumber ?? "T48/T56"}` : "No programmer connected"}
          </Text>
        </LayerCard.Primary>
      </LayerCard>

      <LayerCard className="panel">
        <LayerCard.Secondary>
          <Text variant="heading3" as="h2">Target Device</Text>
        </LayerCard.Secondary>
        <LayerCard.Primary className="panel-body">
          <div className="field-grid">
            <Input label="Search target devices" disabled={busy} value={query} onChange={(event) => setQuery(event.target.value)} />
            <Select
              label="Device"
              disabled={busy}
              value={selectedDevice}
              onValueChange={setSelectedDeviceValue}
              items={deviceItems}
            />
          </div>
          {selectedSummary ? (
            <Text variant="secondary">
              {selectedSummary.packagePins} pins, {selectedSummary.codeMemorySize} code bytes, page size {selectedSummary.pageSize}
              {selectedSummary.chipIdBytesCount ? `, chip ID 0x${selectedSummary.chipId.toString(16)}` : ", no catalogued chip ID"}.
            </Text>
          ) : (
            <Banner variant="error" title="Selected device is not in the current search results" />
          )}
        </LayerCard.Primary>
      </LayerCard>

      <LayerCard className="panel">
        <LayerCard.Secondary>
          <Text variant="heading3" as="h2">Read Backup</Text>
        </LayerCard.Secondary>
        <LayerCard.Primary className="panel-body actions">
          <Button variant="primary" disabled={!api || !programmer || busy} onClick={() => void readRom()}>
            Read ROM
          </Button>
          <LinkButton
            className="download-link"
            variant="secondary"
            download={`${backup?.target ?? selectedDevice}.bin`}
            href={downloadUrl}
            aria-disabled={!backup}
          >
            Download readback
          </LinkButton>
        </LayerCard.Primary>
      </LayerCard>

      <LayerCard className="panel">
        <LayerCard.Secondary>
          <Text variant="heading3" as="h2">Write ROM</Text>
        </LayerCard.Secondary>
        <LayerCard.Primary className="panel-body">
          <Input
            label="ROM image to write"
            disabled={busy}
            type="file"
            onChange={(event) => void onFileSelected(event.currentTarget.files?.[0])}
          />
          <div className="checkbox-stack">
            <Checkbox
              label="Skip chip ID check only if you have externally identified the chip"
              disabled={busy}
              checked={skipIdCheck}
              onCheckedChange={(checked) => {
                setSkipIdCheck(checked === true);
                setConfirmWrite(false);
              }}
            />
            <Checkbox
              label="I saved the readback, confirmed chip orientation, and verified the image length"
              disabled={busy}
              checked={confirmWrite}
              variant={confirmWrite ? "default" : "error"}
              onCheckedChange={(checked) => setConfirmWrite(checked === true)}
            />
          </div>
          {writeImage && backup && writeImage.byteLength !== backup.data.byteLength ? (
            <Banner
              variant="error"
              title="Image size mismatch"
              description={`Expected ${backup.data.byteLength} bytes, got ${writeImage.byteLength}.`}
            />
          ) : null}
          {!backup ? <Text variant="secondary">Read and download a backup before writing is enabled.</Text> : null}
          <Button variant="destructive" disabled={!canWrite} onClick={() => void writeRom()}>
            Write ROM with erase + verify
          </Button>
        </LayerCard.Primary>
      </LayerCard>

      <LayerCard className="panel diagnostics">
        <LayerCard.Secondary className="panel-heading">
          <Text variant="heading3" as="h2">Diagnostics</Text>
          <Button type="button" size="sm" variant="secondary" onClick={() => setLogs([])}>Clear logs</Button>
        </LayerCard.Secondary>
        <LayerCard.Primary className="panel-body">
          <Text bold>{status}</Text>
          <pre aria-label="Diagnostic log">{logs.map((entry) => JSON.stringify(entry)).join("\n")}</pre>
        </LayerCard.Primary>
      </LayerCard>
    </main>
  );
}

function logEntry(level: LogEntry["level"], event: string, fields: Record<string, unknown> = {}): LogEntry {
  return { timestamp: new Date().toISOString(), level, event, ...fields };
}

function progressFields(operationId: string, progress: RomProgressEvent): Record<string, unknown> {
  return {
    operation_id: operationId,
    phase: progress.phase,
    offset_bytes: progress.offset,
    total_bytes: progress.total,
    percent: progress.total === 0 ? 0 : Math.round((progress.offset / progress.total) * 1000) / 10
  };
}

function programmerFields(programmer: ProgrammerConnection): Record<string, unknown> {
  return {
    product_name: programmer.productName,
    manufacturer_name: programmer.manufacturerName,
    vendor_id: `0x${programmer.vendorId.toString(16).padStart(4, "0")}`,
    product_id: `0x${programmer.productId.toString(16).padStart(4, "0")}`,
    opened: programmer.opened
  };
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

function errorFields(error: unknown): Record<string, unknown> {
  if (!(error instanceof Error)) return { error: String(error) };
  const codedError = error as Error & { code?: unknown; cause?: unknown };
  return {
    error_name: error.name,
    error_code: codedError.code,
    error_message: error.message,
    error_cause: serializeCause(codedError.cause)
  };
}

function serializeCause(cause: unknown): unknown {
  if (!(cause instanceof Error)) return cause;
  const codedCause = cause as Error & { code?: unknown; cause?: unknown };
  return {
    name: cause.name,
    code: codedCause.code,
    message: cause.message,
    cause: serializeCause(codedCause.cause)
  };
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
