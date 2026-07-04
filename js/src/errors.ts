export class XgecuWebUSBError extends Error {
  constructor(message: string, readonly cause?: unknown) {
    super(message);
    this.name = "XgecuWebUSBError";
  }
}

export class WebUSBUnavailableError extends XgecuWebUSBError {
  constructor() {
    super("WebUSB is not available in this browser context. Use a Chromium-based browser over HTTPS or localhost.");
    this.name = "WebUSBUnavailableError";
  }
}

export class WebUSBTransferError extends XgecuWebUSBError {
  constructor(message: string) {
    super(message);
    this.name = "WebUSBTransferError";
  }
}
