export type XgecuErrorCode =
  | "Unknown"
  | "WebUSBUnavailable"
  | "WebUSBTransferFailed"
  | "WebUSBLifecycleFailed"
  | "UnsupportedProgrammer"
  | "ProgrammerMismatch"
  | "DeviceNotFound"
  | "ChipIdMismatch"
  | "Overcurrent"
  | "ProgrammerStatusError"
  | "VerifyFailed"
  | "AlgorithmUnavailable"
  | "PayloadBufferTooSmall"
  | "EmptyMemoryRegion"
  | "InputTooLarge"
  | "ProgrammerInBootloader"
  | "OperationAborted"
  | "OperationInProgress"
  | "InvalidInput"
  | "ShortRead"
  | "TargetNotBlank";

export class XgecuWebUSBError extends Error {
  constructor(message: string, readonly code: XgecuErrorCode = "Unknown", readonly cause?: unknown) {
    super(message);
    this.name = "XgecuWebUSBError";
  }
}

export class WebUSBUnavailableError extends XgecuWebUSBError {
  constructor() {
    super("WebUSB is not available in this browser context. Use a Chromium-based browser over HTTPS or localhost.", "WebUSBUnavailable");
    this.name = "WebUSBUnavailableError";
  }
}

export class WebUSBTransferError extends XgecuWebUSBError {
  constructor(message: string, cause?: unknown) {
    super(message, "WebUSBTransferFailed", cause);
    this.name = "WebUSBTransferError";
  }
}

export function xgecuErrorFromUnknown(cause: unknown, fallback = "XGecu operation failed."): XgecuWebUSBError {
  if (cause instanceof XgecuWebUSBError) return cause;
  if (cause instanceof Error) return new XgecuWebUSBError(cause.message || fallback, "Unknown", cause);
  return new XgecuWebUSBError(String(cause || fallback), "Unknown", cause);
}

export function xgecuErrorCodeFromAbi(code: number): XgecuErrorCode {
  switch (code) {
    case 10:
      return "UnsupportedProgrammer";
    case 11:
      return "ProgrammerMismatch";
    case 12:
      return "DeviceNotFound";
    case 13:
      return "ChipIdMismatch";
    case 14:
      return "Overcurrent";
    case 15:
      return "ProgrammerStatusError";
    case 16:
      return "VerifyFailed";
    case 17:
      return "AlgorithmUnavailable";
    case 18:
      return "PayloadBufferTooSmall";
    case 19:
      return "EmptyMemoryRegion";
    case 20:
      return "InputTooLarge";
    case 21:
      return "ProgrammerInBootloader";
    case 22:
      return "OperationAborted";
    case 23:
      return "WebUSBTransferFailed";
    case 24:
      return "ShortRead";
    case 25:
      return "TargetNotBlank";
    default:
      return "Unknown";
  }
}
