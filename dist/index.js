//#region js/src/errors.ts
var e = class extends Error {
	code;
	cause;
	constructor(e, t = "Unknown", n) {
		super(e), this.code = t, this.cause = n, this.name = "XgecuWebUSBError";
	}
}, t = class extends e {
	constructor() {
		super("WebUSB is not available in this browser context. Use a Chromium-based browser over HTTPS or localhost.", "WebUSBUnavailable"), this.name = "WebUSBUnavailableError";
	}
}, n = class extends e {
	constructor(e, t) {
		super(e, "WebUSBTransferFailed", t), this.name = "WebUSBTransferError";
	}
};
function r(t, n = "XGecu operation failed.") {
	return t instanceof e ? t : t instanceof Error ? new e(t.message || n, "Unknown", t) : new e(String(t || n), "Unknown", t);
}
function i(e) {
	switch (e) {
		case 10: return "UnsupportedProgrammer";
		case 11: return "ProgrammerMismatch";
		case 12: return "DeviceNotFound";
		case 13: return "ChipIdMismatch";
		case 14: return "Overcurrent";
		case 15: return "ProgrammerStatusError";
		case 16: return "VerifyFailed";
		case 17: return "AlgorithmUnavailable";
		case 18: return "PayloadBufferTooSmall";
		case 19: return "EmptyMemoryRegion";
		case 20: return "InputTooLarge";
		case 21: return "ProgrammerInBootloader";
		case 22: return "OperationAborted";
		case 23: return "WebUSBTransferFailed";
		case 24: return "ShortRead";
		case 25: return "TargetNotBlank";
		case 26: return "PinCheckUnavailable";
		case 27: return "ProtectionUnsupported";
		case 28: return "InvalidAlgorithm";
		default: return "Unknown";
	}
}
//#endregion
//#region js/src/algorithm-xml.ts
var a = 8, o = 512;
function s(t) {
	if (typeof t != "string" || t.length === 0) throw new e("algorithm.xml must be a non-empty string.", "InvalidAlgorithm");
	let n = /* @__PURE__ */ new Map();
	return async (e) => {
		let r = `${e.programmer}:${e.name}:${e.sha256}`, i = n.get(r);
		i || (i = c(t, e), n.set(r, i));
		try {
			return (await i).slice();
		} catch (e) {
			throw n.delete(r), e;
		}
	};
}
async function c(t, n) {
	let r = await ne(te(ee(l(t, n.programmer === "t56" ? "algorithms_T56" : "algorithms_T76"), n.name)), n.programmer === "t76" ? n.size * 2 + a : n.size);
	re(r);
	let i = n.programmer === "t56" ? ie(r) : ae(r);
	if (i.byteLength !== n.size) throw new e(`${n.programmer.toUpperCase()} ${n.name} decoded to ${i.byteLength} bytes; the catalog requires ${n.size}.`, "InvalidAlgorithm");
	if (await oe(i) !== n.sha256.toLowerCase()) throw new e(`${n.programmer.toUpperCase()} ${n.name} does not match the catalog digest.`, "InvalidAlgorithm");
	return i;
}
function l(t, n) {
	let r = `<${n}>`, i = `</${n}>`, a = t.indexOf(r), o = a < 0 ? -1 : t.indexOf(i, a + r.length);
	if (a < 0 || o < 0) throw new e(`algorithm.xml does not contain ${n}.`, "InvalidAlgorithm");
	return t.slice(a + r.length, o);
}
function ee(t, n) {
	let r = n.replace(/[.*+?^${}()|[\]\\]/g, "\\$&"), i = t.match(RegExp(`<algorithm\\b(?=[^>]*\\bname="${r}")(?=[^>]*\\bbitstream="([^"]+)")[^>]*>`, "s"));
	if (!i?.[1]) throw new e(`algorithm.xml does not contain ${n}.`, "AlgorithmUnavailable");
	return i[1].replace(/\s+/g, "");
}
function te(t) {
	try {
		let e = atob(t), n = new Uint8Array(e.length);
		for (let t = 0; t < e.length; t += 1) n[t] = e.charCodeAt(t);
		return n;
	} catch (t) {
		throw new e("The algorithm payload is not valid base64.", "InvalidAlgorithm", t);
	}
}
async function ne(t, n) {
	if (typeof DecompressionStream > "u") throw new e("This browser cannot decompress algorithm.xml payloads.", "InvalidAlgorithm");
	try {
		let r = new Blob([ce(t)]).stream().pipeThrough(new DecompressionStream("gzip")).getReader(), i = [], a = 0;
		for (;;) {
			let { done: t, value: o } = await r.read();
			if (t) break;
			if (a += o.byteLength, a > n) throw await r.cancel(), new e("The decompressed algorithm payload exceeds the catalog size.", "InvalidAlgorithm");
			i.push(o);
		}
		let o = new Uint8Array(a), s = 0;
		for (let e of i) o.set(e, s), s += e.byteLength;
		return o;
	} catch (t) {
		throw t instanceof e ? t : new e("The algorithm payload is not valid gzip data.", "InvalidAlgorithm", t);
	}
}
function re(t) {
	if (t.byteLength < a) throw new e("The algorithm payload header is truncated.", "InvalidAlgorithm");
	let n = se(t, 4), r = 4294967295;
	for (let e = a; e < t.byteLength; e += 1) {
		r = (r ^ t[e]) >>> 0;
		for (let e = 0; e < 8; e += 1) r = (r >>> 1 ^ (r & 1 ? 3988292384 : 0)) >>> 0;
	}
	if (r !== n) throw new e("The algorithm payload CRC is invalid.", "InvalidAlgorithm");
}
function ie(e) {
	let t = o - e.byteLength % o, n = new Uint8Array(e.byteLength + t);
	return n.set(e), n;
}
function ae(t) {
	if (t.byteLength < a) throw new e("The T76 algorithm payload header is truncated.", "InvalidAlgorithm");
	let n = new Uint8Array(se(t, 0));
	if (n.byteLength === 0) throw new e("The T76 algorithm payload declares an empty bitstream.", "InvalidAlgorithm");
	let r = a, i = 0;
	for (; r < t.byteLength;) {
		r + 2 > t.byteLength && u();
		let e = d(t, r);
		if (r += 2, e !== 0) {
			i + 2 > n.byteLength && u(), n[i] = e & 255, n[i + 1] = e >>> 8, i += 2;
			continue;
		}
		r + 2 > t.byteLength && u();
		let a = d(t, r) * 2;
		r += 2, i + a > n.byteLength && u(), i += a;
	}
	return i !== n.byteLength && i + 1 !== n.byteLength && u(), n;
}
function u() {
	throw new e("The T76 algorithm payload has an invalid run-length encoding.", "InvalidAlgorithm");
}
async function oe(t) {
	if (!globalThis.crypto?.subtle) throw new e("Web Crypto is required to validate algorithm payloads.", "InvalidAlgorithm");
	let n = new Uint8Array(await globalThis.crypto.subtle.digest("SHA-256", ce(t)));
	return Array.from(n, (e) => e.toString(16).padStart(2, "0")).join("");
}
function d(e, t) {
	return e[t] | e[t + 1] << 8;
}
function se(e, t) {
	return (e[t] | e[t + 1] << 8 | e[t + 2] << 16 | e[t + 3] << 24) >>> 0;
}
function ce(e) {
	let t = new Uint8Array(e.byteLength);
	return t.set(e), t.buffer;
}
//#endregion
//#region js/src/wasm.ts
var f = new TextEncoder(), p = new TextDecoder(), m = 1, le = 5, ue = 80, de = class t {
	exports;
	operations = /* @__PURE__ */ new Map();
	constructor(e) {
		this.exports = e;
	}
	static async load(n) {
		let r = n ?? new URL(
			/* @vite-ignore */
			"./xgecu_web.wasm",
			import.meta.url
		), i = await fetch(r);
		if (!i.ok) throw new e(`Failed to load xgecu_web.wasm: HTTP ${i.status}.`);
		let a = await WebAssembly.instantiate(await i.arrayBuffer(), {});
		return new t(a.instance.exports);
	}
	deviceList(e = {}) {
		let t = f.encode(e.search ?? "");
		return this.withBytes(t, (n) => {
			let r = this.exports.mp_device_list(n, t.byteLength, _(e.programmer ?? "auto"), e.limit ?? 100);
			return this.throwIfError(r), JSON.parse(p.decode(this.resultBytes()));
		});
	}
	resolveDevice(e, t = "auto") {
		let n = f.encode(e);
		return this.withBytes(n, (e) => {
			let r = this.exports.mp_device_detail(e, n.byteLength, _(t));
			return this.throwIfError(r), JSON.parse(p.decode(this.resultBytes()));
		});
	}
	programmerFromSystemInfo(t) {
		if (!(t instanceof Uint8Array)) throw new e("Programmer system info must be a Uint8Array.", "InvalidInput");
		return this.withBytes(t, (n) => {
			switch (this.exports.mp_programmer_from_system_info(n, t.byteLength)) {
				case 1: return "t48";
				case 2: return "t56";
				case 3: return "t76";
				default: throw new e(this.lastError() || "Unsupported programmer system info.", "UnsupportedProgrammer");
			}
		});
	}
	async identifyProgrammer(t) {
		await t({
			direction: "out",
			endpoint: m,
			data: new Uint8Array(le)
		});
		let n = await t({
			direction: "in",
			endpoint: m,
			length: ue
		});
		if (!(n instanceof Uint8Array)) throw new e("The programmer returned no system info.", "UnsupportedProgrammer");
		return this.programmerFromSystemInfo(n);
	}
	startReadROM(t) {
		let n = _(t.programmer), r = fe(t.memory);
		h(t.skipIdCheck, "skipIdCheck"), h(t.continueOnIdMismatch, "continueOnIdMismatch");
		let i = f.encode(t.device);
		return this.withBytes(i, (a) => this.withBytes(t.t56Algorithm ?? /* @__PURE__ */ new Uint8Array(), (o) => this.withBytes(t.t76Algorithm ?? /* @__PURE__ */ new Uint8Array(), (s) => {
			let c = this.exports.mp_start_read_rom(n, a, i.byteLength, r, +!!t.skipIdCheck, +!!t.continueOnIdMismatch, o, t.t56Algorithm?.byteLength ?? 0, s, t.t76Algorithm?.byteLength ?? 0);
			if (c === 0) throw new e(this.lastError() || "Failed to start readROM operation.");
			return this.registerOperation(c);
		})));
	}
	startPinCheck(t) {
		let n = _(t.programmer), r = f.encode(t.device);
		return this.withBytes(r, (t) => {
			let i = this.exports.mp_start_pin_check(n, t, r.byteLength);
			if (i === 0) throw new e(this.lastError() || "Failed to start pin-contact check.", "PinCheckUnavailable");
			return this.registerOperation(i);
		});
	}
	startWriteROM(t) {
		let n = _(t.programmer), r = fe(t.memory);
		if (!(t.data instanceof Uint8Array)) throw new e("data must be a Uint8Array.", "InvalidInput");
		for (let [e, n] of [
			["erase", t.erase],
			["verify", t.verify],
			["skipIdCheck", t.skipIdCheck],
			["continueOnIdMismatch", t.continueOnIdMismatch],
			["unprotectBefore", t.unprotectBefore],
			["protectAfter", t.protectAfter]
		]) h(n, e);
		g(t.eraseNumFuses, "eraseNumFuses"), g(t.erasePld, "erasePld");
		let i = f.encode(t.device);
		return this.withBytes(i, (a) => this.withBytes(t.data, (o) => this.withBytes(t.t56Algorithm ?? /* @__PURE__ */ new Uint8Array(), (s) => this.withBytes(t.t76Algorithm ?? /* @__PURE__ */ new Uint8Array(), (c) => {
			let l = this.exports.mp_start_write_rom(n, a, i.byteLength, r, o, t.data.byteLength, +!!t.erase, t.eraseNumFuses, t.erasePld, +!!t.verify, +!!t.skipIdCheck, +!!t.continueOnIdMismatch, +!!t.unprotectBefore, +!!t.protectAfter, s, t.t56Algorithm?.byteLength ?? 0, c, t.t76Algorithm?.byteLength ?? 0);
			if (l === 0) throw new e(this.lastError() || "Failed to start writeROM operation.");
			return this.registerOperation(l);
		}))));
	}
	disposeOperation(t) {
		let n = this.operations.get(t);
		if (n) {
			if (n === "running") throw new e("The Wasm operation is currently running.", "OperationInProgress");
			this.operations.delete(t), this.exports.mp_operation_destroy(t);
		}
	}
	async runOperation(t, n, r = {}) {
		let i = this.operations.get(t);
		if (i === "running") throw new e("The Wasm operation is already running.", "OperationInProgress");
		if (i !== "ready") throw new e("The Wasm operation handle is invalid or already consumed.", "InvalidInput");
		this.operations.set(t, "running");
		let a, o = async () => {
			if (!r.onProgress) return;
			let e = this.operationProgress(t);
			a?.phase === e.phase && a.offset === e.offset && a.total === e.total || (a = e, await r.onProgress(e));
		};
		try {
			for (;;) {
				if (r.signal?.aborted) throw new e("Operation aborted.", "OperationAborted");
				let i = this.exports.mp_operation_next(t);
				if (i === 0) return this.throwIfError(this.exports.mp_operation_result(t)), await o(), this.operationResultBytes(t).slice();
				if (i === 1) {
					let e = this.exports.mp_transfer_endpoint(t), r = this.memoryBytes(this.exports.mp_transfer_ptr(t), this.exports.mp_transfer_len(t)).slice();
					try {
						await n({
							direction: "out",
							endpoint: e,
							data: r
						});
					} catch (e) {
						throw this.exports.mp_operation_complete(t, 1, 0, 0), e;
					}
					if (this.exports.mp_operation_complete(t, 0, 0, 0) !== 0) throw this.operationError(t);
					await o();
					continue;
				}
				if (i === 2) {
					let e = this.exports.mp_transfer_endpoint(t), r = this.exports.mp_transfer_len(t), i;
					try {
						i = await n({
							direction: "in",
							endpoint: e,
							length: r
						});
					} catch (e) {
						throw this.exports.mp_operation_complete(t, 1, 0, 0), e;
					}
					let a = i instanceof Uint8Array ? i : /* @__PURE__ */ new Uint8Array(), s = 0;
					if (this.withBytes(a, (e) => {
						s = this.exports.mp_operation_complete(t, 0, e, a.byteLength);
					}), s !== 0) throw this.operationError(t);
					await o();
					continue;
				}
				throw this.operationError(t);
			}
		} catch (i) {
			if (this.exports.mp_operation_abort(t), !await this.drainCleanupBestEffort(t, n)) {
				try {
					r.onCleanupFailure?.();
				} catch {}
				throw new e("The programmer operation failed and its hardware cleanup could not be completed. Reconnect the programmer before continuing.", "WebUSBLifecycleFailed", i);
			}
			throw i;
		} finally {
			this.operations.delete(t), this.exports.mp_operation_destroy(t);
		}
	}
	memoryBytes(e, t) {
		return new Uint8Array(this.exports.memory.buffer, e, t);
	}
	withBytes(t, n) {
		if (t.byteLength === 0) return n(0);
		let r = this.exports.mp_alloc(t.byteLength);
		if (r === 0) throw new e("Wasm allocation failed.");
		this.memoryBytes(r, t.byteLength).set(t);
		try {
			return n(r);
		} finally {
			this.exports.mp_free(r, t.byteLength);
		}
	}
	resultBytes() {
		return this.memoryBytes(this.exports.mp_result_ptr(), this.exports.mp_result_len());
	}
	operationResultBytes(e) {
		return this.memoryBytes(this.exports.mp_operation_result_ptr(e), this.exports.mp_operation_result_len(e));
	}
	lastError() {
		let e = this.exports.mp_last_error_ptr(), t = this.exports.mp_last_error_len();
		return e === 0 || t === 0 ? "" : p.decode(this.memoryBytes(e, t));
	}
	throwIfError(t) {
		if (t !== 0) throw new e(this.lastError() || "Wasm call failed.");
	}
	operationError(t) {
		let n = this.exports.mp_operation_error_code(t), r = this.exports.mp_operation_error_ptr(t), a = this.exports.mp_operation_error_len(t);
		return new e(r === 0 || a === 0 ? this.lastError() || "Wasm operation failed." : p.decode(this.memoryBytes(r, a)), i(n));
	}
	operationProgress(e) {
		return {
			phase: pe(this.exports.mp_operation_phase(e)),
			offset: this.exports.mp_operation_offset(e),
			total: this.exports.mp_operation_total(e)
		};
	}
	registerOperation(t) {
		let n = t;
		if (this.operations.has(n)) throw new e("Wasm returned an operation handle that is already active.");
		return this.operations.set(n, "ready"), n;
	}
	async drainCleanupBestEffort(e, t) {
		try {
			return await this.drainCleanup(e, t);
		} catch {
			return !1;
		}
	}
	async drainCleanup(e, t) {
		for (let n = 0; n < 4; n += 1) {
			let n = this.exports.mp_operation_next(e);
			if (n === 0 || n === 3) return !0;
			if (n === 1) {
				await t({
					direction: "out",
					endpoint: this.exports.mp_transfer_endpoint(e),
					data: this.memoryBytes(this.exports.mp_transfer_ptr(e), this.exports.mp_transfer_len(e)).slice()
				}), this.exports.mp_operation_complete(e, 0, 0, 0);
				continue;
			}
			if (n === 2) {
				let n = await t({
					direction: "in",
					endpoint: this.exports.mp_transfer_endpoint(e),
					length: this.exports.mp_transfer_len(e)
				}), r = n instanceof Uint8Array ? n : /* @__PURE__ */ new Uint8Array();
				this.withBytes(r, (t) => {
					this.exports.mp_operation_complete(e, 0, t, r.byteLength);
				});
			}
		}
		return !1;
	}
};
function h(t, n) {
	if (typeof t != "boolean") throw new e(`${n} must be a boolean.`, "InvalidInput");
}
function g(t, n) {
	if (typeof t != "number" || !Number.isInteger(t) || t < 0 || t > 255) throw new e(`${n} must be an integer from 0 to 255.`, "InvalidInput");
}
function _(t) {
	switch (t) {
		case "auto": return 0;
		case "t48": return 1;
		case "t56": return 2;
		case "t76": return 3;
		default: throw new e("Invalid programmer kind.", "InvalidInput");
	}
}
function fe(t) {
	switch (t) {
		case "code": return 0;
		case "data": return 1;
		case "user": return 2;
		default: throw new e("Invalid memory kind.", "InvalidInput");
	}
}
function pe(e) {
	switch (e) {
		case 1: return "connecting";
		case 2: return "identifying";
		case 3: return "erasing";
		case 4: return "writing";
		case 5: return "reading";
		case 6: return "verifying";
		case 7: return "cleanup";
		case 8: return "done";
		case 9: return "failed";
		default: return "connecting";
	}
}
//#endregion
//#region node_modules/.pnpm/better-result@2.9.2/node_modules/better-result/dist/index.mjs
function v(e, t) {
	return e === 2 ? ((...e) => e.length >= 2 ? t(e[0], e[1]) : (n) => t(n, e[0])) : e === 3 ? ((...e) => e.length >= 3 ? t(e[0], e[1], e[2]) : (n) => t(n, e[0], e[1])) : e === 4 ? ((...e) => e.length >= 4 ? t(e[0], e[1], e[2], e[3]) : (n) => t(n, e[0], e[1], e[2])) : ((...n) => n.length >= e ? t(...n) : (e) => t(e, ...n));
}
var me = (e) => e instanceof Error ? {
	name: e.name,
	message: e.message,
	stack: e.stack
} : e, he = class e extends Error {
	_tag = "Panic";
	static is(t) {
		return t instanceof e;
	}
	constructor(e) {
		if (super(e.message, e.cause === void 0 ? void 0 : { cause: e.cause }), Object.assign(this, e), Object.setPrototypeOf(this, new.target.prototype), this.name = "Panic", e.cause instanceof Error && e.cause.stack) {
			let t = e.cause.stack.replace(/\n/g, "\n  ");
			this.stack = `${this.stack}\nCaused by: ${t}`;
		}
	}
	toJSON() {
		return {
			...this,
			_tag: this._tag,
			name: this.name,
			message: this.message,
			cause: me(this.cause),
			stack: this.stack
		};
	}
	*[Symbol.iterator]() {
		return yield* C(this), y("Unreachable: Err yielded in Panic but generator continued", this);
	}
}, y = (e, t) => {
	throw new he({
		message: e,
		cause: t
	});
}, b = (e, t) => {
	try {
		return e();
	} catch (e) {
		throw y(t, e);
	}
}, x = async (e, t) => {
	try {
		return await e();
	} catch (e) {
		throw y(t, e);
	}
}, ge = class e {
	status = "ok";
	constructor(e) {
		this.value = e;
	}
	isOk() {
		return !0;
	}
	isErr() {
		return !1;
	}
	map(t) {
		return b(() => new e(t(this.value)), "map callback threw");
	}
	mapError(e) {
		return this;
	}
	tryRecover(e) {
		return this;
	}
	tryRecoverAsync(e) {
		return Promise.resolve(this);
	}
	andThen(e) {
		return b(() => e(this.value), "andThen callback threw");
	}
	andThenAsync(e) {
		return x(() => e(this.value), "andThenAsync callback threw");
	}
	match(e) {
		return b(() => e.ok(this.value), "match ok handler threw");
	}
	unwrap(e) {
		return this.value;
	}
	unwrapOr(e) {
		return this.value;
	}
	tap(e) {
		return b(() => (e(this.value), this), "tap callback threw");
	}
	tapAsync(e) {
		return x(async () => (await e(this.value), this), "tapAsync callback threw");
	}
	tapError(e) {
		return this;
	}
	tapErrorAsync(e) {
		return Promise.resolve(this);
	}
	tapBoth(e) {
		return b(() => (e.ok(this.value), this), "tapBoth ok callback threw");
	}
	tapBothAsync(e) {
		return x(async () => (await e.ok(this.value), this), "tapBothAsync ok callback threw");
	}
	*[Symbol.iterator]() {
		return this.value;
	}
}, _e = class e {
	status = "error";
	constructor(e) {
		this.error = e;
	}
	isOk() {
		return !1;
	}
	isErr() {
		return !0;
	}
	map(e) {
		return this;
	}
	mapError(t) {
		return b(() => new e(t(this.error)), "mapError callback threw");
	}
	tryRecover(e) {
		return b(() => e(this.error), "tryRecover callback threw");
	}
	tryRecoverAsync(e) {
		return x(() => e(this.error), "tryRecoverAsync callback threw");
	}
	andThen(e) {
		return this;
	}
	andThenAsync(e) {
		return Promise.resolve(this);
	}
	match(e) {
		return b(() => e.err(this.error), "match err handler threw");
	}
	unwrap(e) {
		return y(e ?? `Unwrap called on Err: ${String(this.error)}`, this.error);
	}
	unwrapOr(e) {
		return e;
	}
	tap(e) {
		return this;
	}
	tapError(e) {
		return b(() => (e(this.error), this), "tapError callback threw");
	}
	tapAsync(e) {
		return Promise.resolve(this);
	}
	tapErrorAsync(e) {
		return x(async () => (await e(this.error), this), "tapErrorAsync callback threw");
	}
	tapBoth(e) {
		return b(() => (e.err(this.error), this), "tapBoth err callback threw");
	}
	tapBothAsync(e) {
		return x(async () => (await e.err(this.error), this), "tapBothAsync err callback threw");
	}
	*[Symbol.iterator]() {
		return yield this, y("Unreachable: Err yielded in Result.gen but generator continued", this.error);
	}
};
function S(e) {
	return new ge(e);
}
var ve = (e) => e.status === "ok", C = (e) => new _e(e), ye = (e) => e.status === "error", be = (e) => e instanceof Error ? {
	name: e.name,
	message: e.message,
	stack: e.stack
} : e, xe = Object.assign((e) => () => {
	class t extends Error {
		_tag = e;
		static is(e) {
			return e instanceof t;
		}
		constructor(t) {
			let n = t && "message" in t && typeof t.message == "string" ? t.message : void 0, r = t && "cause" in t ? t.cause : void 0;
			if (super(n, r === void 0 ? void 0 : { cause: r }), t && Object.assign(this, t), Object.setPrototypeOf(this, new.target.prototype), this.name = e, r instanceof Error && r.stack) {
				let e = r.stack.replace(/\n/g, "\n  ");
				this.stack = `${this.stack}\nCaused by: ${e}`;
			}
		}
		toJSON() {
			return {
				...this,
				_tag: this._tag,
				name: this.name,
				message: this.message,
				cause: be(this.cause),
				stack: this.stack
			};
		}
		*[Symbol.iterator]() {
			return yield* C(this), y("Unreachable: Err yielded in TaggedError but generator continued", this);
		}
	}
	return t;
}, { is: (e) => e instanceof Error && "_tag" in e && typeof e._tag == "string" }), Se = class extends xe("UnhandledException")() {
	constructor(e) {
		let t = e.cause instanceof Error ? `Unhandled exception: ${e.cause.message}` : `Unhandled exception: ${String(e.cause)}`;
		super({
			message: t,
			cause: e.cause
		});
	}
}, Ce = class extends xe("ResultDeserializationError")() {
	constructor(e) {
		super({
			message: "Failed to deserialize value as Result: expected { status: \"ok\", value } or { status: \"error\", error }",
			value: e.value
		});
	}
}, we = (e, t) => {
	try {
		return e();
	} catch (e) {
		throw y(t, e);
	}
}, Te = (e, t) => {
	let n = () => {
		if (typeof e == "function") try {
			return S(e());
		} catch (e) {
			return C(new Se({ cause: e }));
		}
		try {
			return S(e.try());
		} catch (t) {
			try {
				return C(e.catch(t));
			} catch (e) {
				throw y("Result.try catch handler threw", e);
			}
		}
	}, r = t?.retry?.times ?? 0, i = n();
	for (let e = 0; e < r && i.status === "error"; e++) i = n();
	return i;
}, Ee = async (e, t) => {
	let n = async () => {
		if (typeof e == "function") try {
			return S(await e());
		} catch (e) {
			return C(new Se({ cause: e }));
		}
		try {
			return S(await e.try());
		} catch (t) {
			try {
				return C(await e.catch(t));
			} catch (e) {
				throw y("Result.tryPromise catch handler threw", e);
			}
		}
	}, r = t?.retry;
	if (!r) return n();
	let i = (e) => {
		switch (r.backoff) {
			case "constant": return r.delayMs;
			case "linear": return r.delayMs * (e + 1);
			case "exponential": return r.delayMs * 2 ** e;
		}
	}, a = (e) => new Promise((t) => setTimeout(t, e)), o = await n(), s = r.shouldRetry ?? (() => !0);
	for (let e = 0; e < r.times && o.status === "error"; e++) {
		let t = o.error;
		if (!we(() => s(t), "shouldRetry predicate threw")) break;
		await a(i(e)), o = await n();
	}
	return o;
}, De = v(2, (e, t) => e.map(t)), Oe = v(2, (e, t) => e.mapError(t)), ke = v(2, (e, t) => e.tryRecover(t)), Ae = v(2, (e, t) => e.andThen(t)), je = v(2, (e, t) => e.tryRecoverAsync(t)), Me = v(2, (e, t) => e.andThenAsync(t)), Ne = v(2, (e, t) => e.match(t)), Pe = v(2, (e, t) => e.tap(t)), Fe = v(2, (e, t) => e.tapAsync(t)), Ie = v(2, (e, t) => e.tapError(t)), Le = v(2, (e, t) => e.tapErrorAsync(t)), Re = v(2, (e, t) => e.tapBoth(t)), ze = v(2, (e, t) => e.tapBothAsync(t)), Be = (e, t) => e.unwrap(t);
function Ve(e) {
	if (!(typeof e == "object" && e && "status" in e && (e.status === "ok" || e.status === "error"))) return y("Result.gen body must return Result.ok() or Result.err(), got: " + (e === null ? "null" : typeof e == "object" ? JSON.stringify(e) : String(e)));
}
var He = v(2, (e, t) => e.unwrapOr(t)), Ue = ((e, t) => {
	let n = e.call(t);
	if (Symbol.asyncIterator in n) return (async () => {
		let e = n, t;
		try {
			t = await e.next();
		} catch (e) {
			throw y("generator body threw", e);
		}
		if (Ve(t.value), !t.done) try {
			await e.return?.(void 0);
		} catch (e) {
			throw y("generator cleanup threw", e);
		}
		return t.value;
	})();
	let r = n, i;
	try {
		i = r.next();
	} catch (e) {
		throw y("generator body threw", e);
	}
	if (Ve(i.value), !i.done) try {
		r.return?.(void 0);
	} catch (e) {
		throw y("generator cleanup threw", e);
	}
	return i.value;
});
async function* We(e) {
	return yield* await e;
}
function Ge(e) {
	return typeof e == "object" && !!e && "status" in e && (e.status === "ok" && "value" in e || e.status === "error" && "error" in e);
}
var Ke = (e) => e.status === "ok" ? {
	status: "ok",
	value: e.value
} : {
	status: "error",
	error: e.error
}, w = (e) => Ge(e) ? e.status === "ok" ? new ge(e.value) : new _e(e.error) : C(new Ce({ value: e })), T = {
	ok: S,
	isOk: ve,
	err: C,
	isError: ye,
	try: Te,
	tryPromise: Ee,
	map: De,
	mapError: Oe,
	tryRecover: ke,
	andThen: Ae,
	tryRecoverAsync: je,
	andThenAsync: Me,
	match: Ne,
	tap: Pe,
	tapAsync: Fe,
	tapError: Ie,
	tapErrorAsync: Le,
	tapBoth: Re,
	tapBothAsync: ze,
	unwrap: Be,
	unwrapOr: He,
	gen: Ue,
	await: We,
	serialize: Ke,
	deserialize: w,
	hydrate: (e) => w(e),
	partition: (e) => {
		let t = [], n = [];
		for (let r of e) r.status === "ok" ? t.push(r.value) : n.push(r.error);
		return [t, n];
	},
	flatten: (e) => e.status === "ok" ? e.value : e
}, E = 42086, D = 2643, O = 6790, k = 0, A = 1, j = /* @__PURE__ */ new WeakMap(), M = class {
	device;
	closed = !1;
	state;
	constructor(e) {
		this.device = e, this.state = L(e), this.state.references += 1;
	}
	get opened() {
		return this.device.opened;
	}
	get vendorId() {
		return this.device.vendorId;
	}
	get productId() {
		return this.device.productId;
	}
	get productName() {
		return B(this.device.productName);
	}
	get manufacturerName() {
		return B(this.device.manufacturerName);
	}
	get serialNumber() {
		return B(this.device.serialNumber);
	}
	get isClosed() {
		return this.closed;
	}
	async close() {
		if (!this.closed) {
			if (this.state.operations !== 0) throw new e("A programmer operation is still in progress for this programmer.", "OperationInProgress");
			if (this.state.lifecycleActive) throw new e("A USB lifecycle operation is already in progress for this programmer.", "OperationInProgress");
			if (this.state.references > 1) {
				--this.state.references, this.closed = !0;
				return;
			}
			this.state.lifecycleActive = !0;
			try {
				try {
					this.device.opened && this.state.claimed && await this.device.releaseInterface?.(k);
				} catch {}
				if (this.state.claimed = !1, this.device.opened && (this.state.openedByLibrary || this.state.poisoned) && await this.device.close(), this.state.poisoned && this.device.opened) throw new e("Failed to reset the programmer after transaction cleanup failed.", "WebUSBLifecycleFailed");
				this.state.openedByLibrary = !1, this.state.references = 0, this.state.poisoned = !1, this.state.sessionEstablished = !1, this.state.detectedProgrammer = void 0, this.closed = !0;
			} finally {
				this.state.lifecycleActive = !1;
			}
		}
	}
}, qe = class {
	wasm;
	usb;
	algorithmProvider;
	constructor(e, t = R(), n) {
		this.wasm = e, this.usb = t, this.algorithmProvider = n;
	}
	deviceList(e = {}) {
		return Q(st(() => this.wasm.deviceList(e)));
	}
	resolveDevice(e, t = "auto") {
		return Q(st(() => this.wasm.resolveDevice(e, t)));
	}
	async getProgrammers() {
		return Q(await Z(async () => (await this.usb.getDevices()).filter(z).map($e)));
	}
	async requestProgrammer() {
		return Q(await Z(async () => {
			let t = await this.usb.requestDevice({ filters: [{
				vendorId: E,
				productId: D
			}, {
				vendorId: E,
				productId: O
			}] });
			if (!z(t)) throw new e("Selected USB device is not a supported T48/T56/T76 programmer.", "UnsupportedProgrammer");
			return await F(t), I(t);
		}));
	}
	async connectProgrammer(t) {
		return Q(await Z(async () => {
			if (!z(t)) throw new e("USB device is not a supported T48/T56/T76 programmer.", "UnsupportedProgrammer");
			return await F(t), I(t);
		}));
	}
	async readROM(t) {
		q(t.programmer), rt(t), X(t.signal);
		let n = {
			programmer: t.programmer,
			programmerKind: t.programmerKind ?? "auto",
			device: t.device,
			memory: t.memory ?? "code",
			skipIdCheck: t.skipIdCheck ?? !1,
			continueOnIdMismatch: t.continueOnIdMismatch ?? !1,
			signal: t.signal,
			onProgress: t.onProgress
		}, r = n.programmer.device;
		return G(r, async () => {
			let t = this.wasm.resolveDevice(n.device, n.programmerKind);
			if (!t) throw new e("Device not found or unsupported by requested programmer.", "DeviceNotFound");
			let i = H(t, n.memory);
			if (i === 0) throw new e("Selected memory region is empty.", "EmptyMemoryRegion");
			await P(r);
			let a = await W(this.wasm, r, n.programmerKind, this.algorithmProvider), o = await U(this.algorithmProvider, t, a), s = this.wasm.startReadROM({
				programmer: n.programmerKind,
				device: n.device,
				memory: n.memory,
				skipIdCheck: n.skipIdCheck,
				continueOnIdMismatch: n.continueOnIdMismatch,
				...o
			}), c = await this.wasm.runOperation(s, (e) => N(r, e), {
				signal: n.signal,
				onProgress: n.onProgress,
				onCleanupFailure: () => K(r)
			});
			if (c.byteLength !== i) {
				let t = c.byteLength < i ? "ShortRead" : "InvalidInput";
				throw new e(`readROM returned ${c.byteLength} of ${i} expected bytes for the selected memory region.`, t);
			}
			return c;
		});
	}
	async checkPinContacts(t) {
		q(t.programmer), nt(t.device), J(t.programmerKind, ["auto", "t48"], "programmerKind"), X(t.signal);
		let n = t.programmerKind ?? "auto", r = t.programmer.device;
		return G(r, async () => {
			let i = this.wasm.resolveDevice(t.device, n);
			if (!i) throw new e("Device not found or unsupported by requested programmer.", "DeviceNotFound");
			if (!i.supportsPinCheck) throw new e("Pin-contact checking is unavailable for this device and programmer.", "PinCheckUnavailable");
			await P(r);
			let a = this.wasm.startPinCheck({
				programmer: n,
				device: t.device
			});
			return et(await this.wasm.runOperation(a, (e) => N(r, e), {
				signal: t.signal,
				onCleanupFailure: () => K(r)
			}));
		});
	}
	async writeROM(t) {
		q(t.programmer), it(t), X(t.signal);
		let n = {
			programmer: t.programmer,
			programmerKind: t.programmerKind ?? "auto",
			device: t.device,
			data: t.data.slice(),
			memory: t.memory ?? "code",
			erase: t.erase ?? !0,
			eraseNumFuses: t.eraseNumFuses ?? 0,
			erasePld: t.erasePld ?? 0,
			verify: t.verify ?? !0,
			skipIdCheck: t.skipIdCheck ?? !1,
			continueOnIdMismatch: t.continueOnIdMismatch ?? !1,
			unprotectBefore: t.unprotectBefore ?? !1,
			protectAfter: t.protectAfter ?? !1,
			signal: t.signal,
			onProgress: t.onProgress
		};
		if (n.data.byteLength === 0) throw new e("writeROM data must not be empty.", "InputTooLarge");
		let r = n.programmer.device;
		return G(r, async () => {
			let t = this.wasm.resolveDevice(n.device, n.programmerKind);
			if (!t) throw new e("Device not found or unsupported by requested programmer.", "DeviceNotFound");
			let i = H(t, n.memory);
			if (i === 0) throw new e("Selected memory region is empty.", "EmptyMemoryRegion");
			if (n.data.byteLength > i) throw new e("writeROM data is larger than the selected memory region.", "InputTooLarge");
			if (n.erase && n.memory !== "code") throw new e("Erase writes are restricted to full code-memory images because erase scope is device-specific.", "InvalidInput");
			if (n.erase && n.data.byteLength !== i) throw new e("writeROM data must match the selected memory region when erase is enabled.", "InputTooLarge");
			if (n.erase && !t.canErase) throw new e("The selected device cannot be electrically erased. Externally erase and blank-check it, then write with erase: false.", "InvalidInput");
			if (n.unprotectBefore && !t.supportsUnprotect) throw new e("The selected device does not support disabling protection before programming.", "ProtectionUnsupported");
			if (n.protectAfter && !t.supportsProtect) throw new e("The selected device does not support enabling protection after programming.", "ProtectionUnsupported");
			await P(r);
			let a = await W(this.wasm, r, n.programmerKind, this.algorithmProvider), o = await U(this.algorithmProvider, t, a), s = this.wasm.startWriteROM({
				programmer: n.programmerKind,
				device: n.device,
				memory: n.memory,
				data: n.data,
				erase: n.erase,
				eraseNumFuses: n.eraseNumFuses,
				erasePld: n.erasePld,
				verify: n.verify,
				skipIdCheck: n.skipIdCheck,
				continueOnIdMismatch: n.continueOnIdMismatch,
				unprotectBefore: n.unprotectBefore,
				protectAfter: n.protectAfter,
				...o
			});
			await this.wasm.runOperation(s, (e) => N(r, e), {
				signal: n.signal,
				onProgress: n.onProgress,
				onCleanupFailure: () => K(r)
			});
		});
	}
};
async function Je(e = {}) {
	return Q(await Z(async () => new qe(await de.load(e.wasmUrl), e.usb ?? R(), e.algorithmProvider)));
}
async function N(e, t) {
	if (t.direction === "out") {
		let r;
		try {
			r = await e.transferOut(t.endpoint, Ye(t.data));
		} catch (e) {
			throw new n(`USB transferOut(${t.endpoint}) failed.`, e);
		}
		if (r.status !== "ok") throw new n(`USB transferOut(${t.endpoint}) failed with ${r.status}.`);
		if (r.bytesWritten !== t.data.byteLength) throw new n(`USB transferOut(${t.endpoint}) wrote ${r.bytesWritten} of ${t.data.byteLength} bytes.`);
		return;
	}
	let r;
	try {
		r = await e.transferIn(t.endpoint, t.length);
	} catch (e) {
		throw new n(`USB transferIn(${t.endpoint}) failed.`, e);
	}
	if (r.status !== "ok") throw new n(`USB transferIn(${t.endpoint}) failed with ${r.status}.`);
	if (!r.data) throw new n(`USB transferIn(${t.endpoint}) returned no data.`);
	return new Uint8Array(r.data.buffer, r.data.byteOffset, r.data.byteLength).slice();
}
function Ye(e) {
	let t = new Uint8Array(e.byteLength);
	return t.set(e), t.buffer;
}
async function P(e) {
	await F(e, !0);
}
async function F(t, n = !1) {
	let r = L(t);
	if (r.lifecycleActive || !n && r.operations !== 0) throw new e("A USB lifecycle operation is already in progress for this programmer.", "OperationInProgress");
	if (n && !t.opened && r.sessionEstablished) throw new e("The programmer connection was lost. Reconnect before starting another operation.", "WebUSBLifecycleFailed");
	if (n && r.poisoned) throw new e("The programmer is in an unknown hardware state. Reconnect before starting another operation.", "WebUSBLifecycleFailed");
	r.lifecycleActive = !0;
	let i = !1;
	try {
		if (!n && r.poisoned) {
			if (t.opened && r.claimed && await t.releaseInterface?.(k).catch(() => void 0), r.claimed = !1, t.opened && await $("reset the programmer after transaction cleanup failed", () => t.close()), t.opened) throw new e("The programmer remained open after reset. Disconnect and reconnect it before continuing.", "WebUSBLifecycleFailed");
			r.openedByLibrary = !1, r.sessionEstablished = !1, r.detectedProgrammer = void 0;
		}
		t.opened || (r.claimed = !1, r.detectedProgrammer = void 0, await $("open USB device", () => t.open()), r.openedByLibrary = !0, i = !0), t.configuration?.configurationValue !== A && (await $("select USB configuration 1", () => t.selectConfiguration(A)), r.claimed = !1), r.claimed ||= (await $("claim USB interface 0", () => t.claimInterface(k)), !0), await Xe(t), r.poisoned = !1, r.sessionEstablished = !0;
	} catch (e) {
		throw r.claimed && await t.releaseInterface?.(k).catch(() => void 0), r.claimed = !1, i && t.opened && await t.close().catch(() => void 0), i && (r.openedByLibrary = !1, r.sessionEstablished = !1), e;
	} finally {
		r.lifecycleActive = !1;
	}
}
async function Xe(t) {
	let n = t.configuration?.interfaces;
	if (!n) return;
	let r = n.find((e) => e.interfaceNumber === k);
	if (!r) throw new e("USB configuration 1 does not expose interface 0.", "WebUSBLifecycleFailed");
	let i = (e) => Qe(e, t.productId);
	if (i(r.alternate)) return;
	let a = r.alternates.find(i) ?? (t.productId === D ? r.alternates.find(Ze) : void 0);
	if (!a) throw new e("USB interface 0 does not expose the required bulk endpoints for this programmer.", "WebUSBLifecycleFailed");
	if (a !== r.alternate) {
		if (!t.selectAlternateInterface) throw new e("USB interface 0 requires an unsupported alternate setting.", "WebUSBLifecycleFailed");
		await $("select USB interface 0 alternate", () => t.selectAlternateInterface(k, a.alternateSetting));
	}
}
function Ze(e) {
	return ["in", "out"].every((t) => e.endpoints.some((e) => e.endpointNumber === 1 && e.direction === t && e.type === "bulk"));
}
function Qe(e, t) {
	return (t === O ? [
		[1, "in"],
		[1, "out"],
		[2, "in"],
		[5, "out"]
	] : [
		[1, "in"],
		[1, "out"],
		[2, "in"],
		[2, "out"]
	]).every(([t, n]) => e.endpoints.some((e) => e.endpointNumber === t && e.direction === n && e.type === "bulk"));
}
function I(e) {
	return new M(e);
}
function L(e) {
	let t = j.get(e);
	return t || (t = {
		claimed: !1,
		lifecycleActive: !1,
		openedByLibrary: !1,
		operations: 0,
		poisoned: !1,
		references: 0,
		sessionEstablished: !1
	}, j.set(e, t)), t;
}
function R() {
	if (typeof navigator > "u" || !navigator.usb) throw new t();
	return navigator.usb;
}
function z(e) {
	return e.vendorId === E && (e.productId === D || e.productId === O);
}
function $e(e) {
	return {
		productName: B(e.productName),
		manufacturerName: B(e.manufacturerName),
		serialNumber: B(e.serialNumber),
		vendorId: e.vendorId,
		productId: e.productId,
		opened: e.opened
	};
}
function B(e) {
	if (e != null) return e.split("\0", 1)[0].trim() || void 0;
}
function et(t) {
	let n;
	try {
		n = JSON.parse(new TextDecoder().decode(t));
	} catch (t) {
		throw new e("The pin-contact check returned an invalid result.", "Unknown", t);
	}
	if (typeof n != "object" || !n) throw new e("The pin-contact check returned an invalid result.");
	let r = n;
	if (typeof r.passed != "boolean" || !V(r.checkedPins) || !V(r.badPins)) throw new e("The pin-contact check returned an invalid result.");
	return {
		passed: r.passed,
		checkedPins: r.checkedPins,
		badPins: r.badPins
	};
}
function V(e) {
	return Array.isArray(e) && e.every((e) => Number.isInteger(e) && e >= 1 && e <= 40);
}
function H(e, t) {
	switch (t) {
		case "code": return e.codeMemorySize;
		case "data": return e.dataMemorySize;
		case "user": return e.userMemorySize;
	}
}
async function U(t, n, r) {
	if (!r) return {};
	if (!t) throw new e(`A local algorithm provider is required for ${r.toUpperCase()} operations.`, "AlgorithmUnavailable");
	let i = {}, a = n.algorithms.find((e) => e.programmer === r);
	if (!a) throw new e(`The catalog does not define a ${r.toUpperCase()} algorithm for this device.`, "AlgorithmUnavailable");
	let o = await t(a);
	if (!(o instanceof Uint8Array)) throw new e("The algorithm provider must return a Uint8Array.", "InvalidAlgorithm");
	return r === "t56" ? i.t56Algorithm = o.slice() : i.t76Algorithm = o.slice(), i;
}
async function W(t, n, r, i) {
	if (r === "t56" || r === "t76") return r;
	if (r === "t48") return;
	if (n.productId === O) return "t76";
	if (!i) return;
	let a = L(n), o = a.detectedProgrammer ?? await t.identifyProgrammer((e) => N(n, e));
	if (o !== "t48" && o !== "t56") throw new e("The shared T48/T56 USB identity returned an unexpected programmer model.", "ProgrammerMismatch");
	return a.detectedProgrammer = o, o === "t56" ? "t56" : void 0;
}
async function G(t, n) {
	let i = L(t);
	if (i.operations !== 0) throw new e("A programmer operation is already in progress for this programmer.", "OperationInProgress");
	i.operations += 1;
	try {
		return Q(T.ok(await n()));
	} catch (e) {
		throw i.poisoned && await tt(t, i), Q(T.err(r(e)));
	} finally {
		--i.operations;
	}
}
function K(e) {
	let t = L(e);
	t.poisoned = !0, t.detectedProgrammer = void 0;
}
async function tt(e, t) {
	e.opened && t.claimed && await e.releaseInterface?.(k).catch(() => void 0), e.opened && await e.close().catch(() => void 0), t.claimed = !1, e.opened || (t.openedByLibrary = !1), t.sessionEstablished = !1, t.detectedProgrammer = void 0;
}
function q(t) {
	if (!(t instanceof M)) throw new e("Use WebUSBProgrammerConnection or a connection returned by the programmer API.", "WebUSBLifecycleFailed");
	if (!z(t.device)) throw new e("USB device is not a supported T48/T56/T76 programmer.", "UnsupportedProgrammer");
	if (t.isClosed) throw new e("The programmer connection is closed.", "WebUSBLifecycleFailed");
}
function nt(e) {
	(typeof e != "string" || e.trim() === "") && Y("device must be a non-empty string");
}
function rt(e) {
	J(e.programmerKind, [
		"auto",
		"t48",
		"t56",
		"t76"
	], "programmerKind"), J(e.memory, [
		"code",
		"data",
		"user"
	], "memory"), at(e, ["skipIdCheck", "continueOnIdMismatch"]);
}
function it(e) {
	e.data instanceof Uint8Array || Y("data must be a Uint8Array"), J(e.programmerKind, [
		"auto",
		"t48",
		"t56",
		"t76"
	], "programmerKind"), J(e.memory, [
		"code",
		"data",
		"user"
	], "memory"), at(e, [
		"erase",
		"verify",
		"skipIdCheck",
		"continueOnIdMismatch",
		"unprotectBefore",
		"protectAfter"
	]), ot(e.eraseNumFuses, "eraseNumFuses"), ot(e.erasePld, "erasePld");
}
function J(e, t, n) {
	e !== void 0 && (typeof e != "string" || !t.includes(e)) && Y(`${n} is invalid`);
}
function at(e, t) {
	let n = e;
	for (let e of t) n[e] !== void 0 && typeof n[e] != "boolean" && Y(`${e} must be a boolean`);
}
function ot(e, t) {
	e !== void 0 && (typeof e != "number" || !Number.isInteger(e) || e < 0 || e > 255) && Y(`${t} must be an integer from 0 to 255`);
}
function Y(t) {
	throw new e(t, "InvalidInput");
}
function X(t) {
	if (t?.aborted) throw new e("Operation aborted.", "OperationAborted");
}
async function Z(e) {
	try {
		return T.ok(await e());
	} catch (e) {
		return T.err(r(e));
	}
}
function st(e) {
	try {
		return T.ok(e());
	} catch (e) {
		return T.err(r(e));
	}
}
function Q(e) {
	if (e.status === "error") throw e.error;
	return e.value;
}
async function $(t, n) {
	try {
		await n();
	} catch (n) {
		throw new e(`Failed to ${t}.`, "WebUSBLifecycleFailed", n);
	}
}
//#endregion
export { qe as BrowserXgecuWebUSB, de as WasmBridge, M as WebUSBProgrammerConnection, n as WebUSBTransferError, t as WebUSBUnavailableError, e as XgecuWebUSBError, s as createAlgorithmXmlProvider, Je as createProgrammer, N as performWebUSBTransfer };

//# sourceMappingURL=index.js.map