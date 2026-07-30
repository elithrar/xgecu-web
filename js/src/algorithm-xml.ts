import { XgecuWebUSBError } from "./errors";
import type { AlgorithmProvider, AlgorithmRequirement } from "./types";

const ALGORITHM_HEADER_SIZE = 8;
const T56_ALIGNMENT = 0x200;

/**
 * Creates a local-only provider from an algorithm.xml file obtained by the user.
 * The XML and decoded payloads remain in the caller's browser process.
 */
export function createAlgorithmXmlProvider(xml: string): AlgorithmProvider {
  if (typeof xml !== "string" || xml.length === 0) {
    throw new XgecuWebUSBError("algorithm.xml must be a non-empty string.", "InvalidAlgorithm");
  }
  const cache = new Map<string, Promise<Uint8Array>>();
  return async (requirement) => {
    const key = `${requirement.programmer}:${requirement.name}:${requirement.sha256}`;
    let pending = cache.get(key);
    if (!pending) {
      pending = decodeRequirement(xml, requirement);
      cache.set(key, pending);
    }
    try {
      return (await pending).slice();
    } catch (error) {
      cache.delete(key);
      throw error;
    }
  };
}

async function decodeRequirement(xml: string, requirement: AlgorithmRequirement): Promise<Uint8Array> {
  const sectionName = requirement.programmer === "t56" ? "algorithms_T56" : "algorithms_T76";
  const section = extractSection(xml, sectionName);
  const encoded = extractBitstream(section, requirement.name);
  const compressed = decodeBase64(encoded);
  // T76's word-run encoding can be up to twice the expanded size, plus its header.
  const maxInflatedSize = requirement.programmer === "t76" ? requirement.size * 2 + ALGORITHM_HEADER_SIZE : requirement.size;
  const inflated = await inflateGzip(compressed, maxInflatedSize);
  validateCrc(inflated);
  const payload = requirement.programmer === "t56" ? padT56(inflated) : expandT76(inflated);
  if (payload.byteLength !== requirement.size) {
    throw new XgecuWebUSBError(
      `${requirement.programmer.toUpperCase()} ${requirement.name} decoded to ${payload.byteLength} bytes; the catalog requires ${requirement.size}.`,
      "InvalidAlgorithm"
    );
  }
  const sha256 = await digestSha256(payload);
  if (sha256 !== requirement.sha256.toLowerCase()) {
    throw new XgecuWebUSBError(
      `${requirement.programmer.toUpperCase()} ${requirement.name} does not match the catalog digest.`,
      "InvalidAlgorithm"
    );
  }
  return payload;
}

function extractSection(xml: string, name: string): string {
  const open = `<${name}>`;
  const close = `</${name}>`;
  const start = xml.indexOf(open);
  const end = start < 0 ? -1 : xml.indexOf(close, start + open.length);
  if (start < 0 || end < 0) {
    throw new XgecuWebUSBError(`algorithm.xml does not contain ${name}.`, "InvalidAlgorithm");
  }
  return xml.slice(start + open.length, end);
}

function extractBitstream(section: string, name: string): string {
  const escapedName = name.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const tag = section.match(new RegExp(`<algorithm\\b(?=[^>]*\\bname="${escapedName}")(?=[^>]*\\bbitstream="([^"]+)")[^>]*>`, "s"));
  if (!tag?.[1]) {
    throw new XgecuWebUSBError(`algorithm.xml does not contain ${name}.`, "AlgorithmUnavailable");
  }
  return tag[1].replace(/\s+/g, "");
}

function decodeBase64(encoded: string): Uint8Array {
  try {
    const binary = atob(encoded);
    const bytes = new Uint8Array(binary.length);
    for (let index = 0; index < binary.length; index += 1) bytes[index] = binary.charCodeAt(index);
    return bytes;
  } catch (error) {
    throw new XgecuWebUSBError("The algorithm payload is not valid base64.", "InvalidAlgorithm", error);
  }
}

async function inflateGzip(compressed: Uint8Array, maxInflatedSize: number): Promise<Uint8Array> {
  if (typeof DecompressionStream === "undefined") {
    throw new XgecuWebUSBError("This browser cannot decompress algorithm.xml payloads.", "InvalidAlgorithm");
  }
  try {
    const stream = new Blob([ownedArrayBuffer(compressed)]).stream().pipeThrough(new DecompressionStream("gzip"));
    const reader = stream.getReader();
    const chunks: Uint8Array[] = [];
    let size = 0;
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      size += value.byteLength;
      if (size > maxInflatedSize) {
        await reader.cancel();
        throw new XgecuWebUSBError("The decompressed algorithm payload exceeds the catalog size.", "InvalidAlgorithm");
      }
      chunks.push(value);
    }
    const inflated = new Uint8Array(size);
    let offset = 0;
    for (const chunk of chunks) {
      inflated.set(chunk, offset);
      offset += chunk.byteLength;
    }
    return inflated;
  } catch (error) {
    if (error instanceof XgecuWebUSBError) throw error;
    throw new XgecuWebUSBError("The algorithm payload is not valid gzip data.", "InvalidAlgorithm", error);
  }
}

function validateCrc(payload: Uint8Array): void {
  if (payload.byteLength < ALGORITHM_HEADER_SIZE) {
    throw new XgecuWebUSBError("The algorithm payload header is truncated.", "InvalidAlgorithm");
  }
  const expected = readU32(payload, 4);
  let actual = 0xffffffff;
  for (let index = ALGORITHM_HEADER_SIZE; index < payload.byteLength; index += 1) {
    actual = (actual ^ payload[index]) >>> 0;
    for (let bit = 0; bit < 8; bit += 1) {
      actual = ((actual >>> 1) ^ (actual & 1 ? 0xedb88320 : 0)) >>> 0;
    }
  }
  if (actual !== expected) {
    throw new XgecuWebUSBError("The algorithm payload CRC is invalid.", "InvalidAlgorithm");
  }
}

function padT56(payload: Uint8Array): Uint8Array {
  const padding = T56_ALIGNMENT - (payload.byteLength % T56_ALIGNMENT);
  const out = new Uint8Array(payload.byteLength + padding);
  out.set(payload);
  return out;
}

function expandT76(payload: Uint8Array): Uint8Array {
  if (payload.byteLength < ALGORITHM_HEADER_SIZE) {
    throw new XgecuWebUSBError("The T76 algorithm payload header is truncated.", "InvalidAlgorithm");
  }
  const out = new Uint8Array(readU32(payload, 0));
  if (out.byteLength === 0) throw new XgecuWebUSBError("The T76 algorithm payload declares an empty bitstream.", "InvalidAlgorithm");
  let inputOffset = ALGORITHM_HEADER_SIZE;
  let outputOffset = 0;
  while (inputOffset < payload.byteLength) {
    if (inputOffset + 2 > payload.byteLength) invalidT76Encoding();
    const value = readU16(payload, inputOffset);
    inputOffset += 2;
    if (value !== 0) {
      if (outputOffset + 2 > out.byteLength) invalidT76Encoding();
      out[outputOffset] = value & 0xff;
      out[outputOffset + 1] = value >>> 8;
      outputOffset += 2;
      continue;
    }
    if (inputOffset + 2 > payload.byteLength) invalidT76Encoding();
    const zeroBytes = readU16(payload, inputOffset) * 2;
    inputOffset += 2;
    if (outputOffset + zeroBytes > out.byteLength) invalidT76Encoding();
    outputOffset += zeroBytes;
  }
  if (outputOffset !== out.byteLength && outputOffset + 1 !== out.byteLength) invalidT76Encoding();
  return out;
}

function invalidT76Encoding(): never {
  throw new XgecuWebUSBError("The T76 algorithm payload has an invalid run-length encoding.", "InvalidAlgorithm");
}

async function digestSha256(bytes: Uint8Array): Promise<string> {
  if (!globalThis.crypto?.subtle) {
    throw new XgecuWebUSBError("Web Crypto is required to validate algorithm payloads.", "InvalidAlgorithm");
  }
  const digest = new Uint8Array(await globalThis.crypto.subtle.digest("SHA-256", ownedArrayBuffer(bytes)));
  return Array.from(digest, (byte) => byte.toString(16).padStart(2, "0")).join("");
}

function readU16(bytes: Uint8Array, offset: number): number {
  return bytes[offset] | (bytes[offset + 1] << 8);
}

function readU32(bytes: Uint8Array, offset: number): number {
  return (bytes[offset] | (bytes[offset + 1] << 8) | (bytes[offset + 2] << 16) | (bytes[offset + 3] << 24)) >>> 0;
}

function ownedArrayBuffer(bytes: Uint8Array): ArrayBuffer {
  const copy = new Uint8Array(bytes.byteLength);
  copy.set(bytes);
  return copy.buffer;
}
