export type XgecuErrorCode = "Unknown" | "WebUSBUnavailable" | "WebUSBTransferFailed" | "WebUSBLifecycleFailed" | "UnsupportedProgrammer" | "ProgrammerMismatch" | "DeviceNotFound" | "ChipIdMismatch" | "Overcurrent" | "ProgrammerStatusError" | "VerifyFailed" | "AlgorithmUnavailable" | "PayloadBufferTooSmall" | "EmptyMemoryRegion" | "InputTooLarge" | "ProgrammerInBootloader" | "OperationAborted" | "OperationInProgress" | "InvalidInput" | "ShortRead";
export declare class XgecuWebUSBError extends Error {
    readonly code: XgecuErrorCode;
    readonly cause?: unknown | undefined;
    constructor(message: string, code?: XgecuErrorCode, cause?: unknown | undefined);
}
export declare class WebUSBUnavailableError extends XgecuWebUSBError {
    constructor();
}
export declare class WebUSBTransferError extends XgecuWebUSBError {
    constructor(message: string, cause?: unknown);
}
export declare function xgecuErrorFromUnknown(cause: unknown, fallback?: string): XgecuWebUSBError;
export declare function xgecuErrorCodeFromAbi(code: number): XgecuErrorCode;
//# sourceMappingURL=errors.d.ts.map