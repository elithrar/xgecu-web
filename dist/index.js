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
	let n = d(t, 4), r = 4294967295;
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
	let n = new Uint8Array(d(t, 0));
	if (n.byteLength === 0) throw new e("The T76 algorithm payload declares an empty bitstream.", "InvalidAlgorithm");
	let r = a, i = 0;
	for (; r < t.byteLength;) {
		r + 2 > t.byteLength && u();
		let e = se(t, r);
		if (r += 2, e !== 0) {
			i + 2 > n.byteLength && u(), n[i] = e & 255, n[i + 1] = e >>> 8, i += 2;
			continue;
		}
		r + 2 > t.byteLength && u();
		let a = se(t, r) * 2;
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
function se(e, t) {
	return e[t] | e[t + 1] << 8;
}
function d(e, t) {
	return (e[t] | e[t + 1] << 8 | e[t + 2] << 16 | e[t + 3] << 24) >>> 0;
}
function ce(e) {
	let t = new Uint8Array(e.byteLength);
	return t.set(e), t.buffer;
}
//#endregion
//#region js/src/wasm.ts
var f = new TextEncoder(), p = new TextDecoder(), le = class t {
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
			let r = this.exports.mp_device_list(n, t.byteLength, h(e.programmer ?? "auto"), e.limit ?? 100);
			return this.throwIfError(r), JSON.parse(p.decode(this.resultBytes()));
		});
	}
	resolveDevice(e, t = "auto") {
		let n = f.encode(e);
		return this.withBytes(n, (e) => {
			let r = this.exports.mp_device_detail(e, n.byteLength, h(t));
			return this.throwIfError(r), JSON.parse(p.decode(this.resultBytes()));
		});
	}
	startReadROM(t) {
		let n = h(t.programmer), r = g(t.memory);
		m(t.skipIdCheck, "skipIdCheck"), m(t.continueOnIdMismatch, "continueOnIdMismatch");
		let i = f.encode(t.device);
		return this.withBytes(i, (a) => this.withBytes(t.t56Algorithm ?? /* @__PURE__ */ new Uint8Array(), (o) => this.withBytes(t.t76Algorithm ?? /* @__PURE__ */ new Uint8Array(), (s) => {
			let c = this.exports.mp_start_read_rom(n, a, i.byteLength, r, +!!t.skipIdCheck, +!!t.continueOnIdMismatch, o, t.t56Algorithm?.byteLength ?? 0, s, t.t76Algorithm?.byteLength ?? 0);
			if (c === 0) throw new e(this.lastError() || "Failed to start readROM operation.");
			return this.registerOperation(c);
		})));
	}
	startPinCheck(t) {
		let n = h(t.programmer), r = f.encode(t.device);
		return this.withBytes(r, (t) => {
			let i = this.exports.mp_start_pin_check(n, t, r.byteLength);
			if (i === 0) throw new e(this.lastError() || "Failed to start pin-contact check.", "PinCheckUnavailable");
			return this.registerOperation(i);
		});
	}
	startWriteROM(t) {
		let n = h(t.programmer), r = g(t.memory);
		if (!(t.data instanceof Uint8Array)) throw new e("data must be a Uint8Array.", "InvalidInput");
		for (let [e, n] of [
			["erase", t.erase],
			["verify", t.verify],
			["skipIdCheck", t.skipIdCheck],
			["continueOnIdMismatch", t.continueOnIdMismatch],
			["unprotectBefore", t.unprotectBefore],
			["protectAfter", t.protectAfter]
		]) m(n, e);
		ue(t.eraseNumFuses, "eraseNumFuses"), ue(t.erasePld, "erasePld");
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
			phase: de(this.exports.mp_operation_phase(e)),
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
function m(t, n) {
	if (typeof t != "boolean") throw new e(`${n} must be a boolean.`, "InvalidInput");
}
function ue(t, n) {
	if (typeof t != "number" || !Number.isInteger(t) || t < 0 || t > 255) throw new e(`${n} must be an integer from 0 to 255.`, "InvalidInput");
}
function h(t) {
	switch (t) {
		case "auto": return 0;
		case "t48": return 1;
		case "t56": return 2;
		case "t76": return 3;
		default: throw new e("Invalid programmer kind.", "InvalidInput");
	}
}
function g(t) {
	switch (t) {
		case "code": return 0;
		case "data": return 1;
		case "user": return 2;
		default: throw new e("Invalid memory kind.", "InvalidInput");
	}
}
function de(e) {
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
function _(e, t) {
	return e === 2 ? ((...e) => e.length >= 2 ? t(e[0], e[1]) : (n) => t(n, e[0])) : e === 3 ? ((...e) => e.length >= 3 ? t(e[0], e[1], e[2]) : (n) => t(n, e[0], e[1])) : e === 4 ? ((...e) => e.length >= 4 ? t(e[0], e[1], e[2], e[3]) : (n) => t(n, e[0], e[1], e[2])) : ((...n) => n.length >= e ? t(...n) : (e) => t(e, ...n));
}
var fe = (e) => e instanceof Error ? {
	name: e.name,
	message: e.message,
	stack: e.stack
} : e, pe = class e extends Error {
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
			cause: fe(this.cause),
			stack: this.stack
		};
	}
	*[Symbol.iterator]() {
		return yield* C(this), v("Unreachable: Err yielded in Panic but generator continued", this);
	}
}, v = (e, t) => {
	throw new pe({
		message: e,
		cause: t
	});
}, y = (e, t) => {
	try {
		return e();
	} catch (e) {
		throw v(t, e);
	}
}, b = async (e, t) => {
	try {
		return await e();
	} catch (e) {
		throw v(t, e);
	}
}, x = class e {
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
		return y(() => new e(t(this.value)), "map callback threw");
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
		return y(() => e(this.value), "andThen callback threw");
	}
	andThenAsync(e) {
		return b(() => e(this.value), "andThenAsync callback threw");
	}
	match(e) {
		return y(() => e.ok(this.value), "match ok handler threw");
	}
	unwrap(e) {
		return this.value;
	}
	unwrapOr(e) {
		return this.value;
	}
	tap(e) {
		return y(() => (e(this.value), this), "tap callback threw");
	}
	tapAsync(e) {
		return b(async () => (await e(this.value), this), "tapAsync callback threw");
	}
	tapError(e) {
		return this;
	}
	tapErrorAsync(e) {
		return Promise.resolve(this);
	}
	tapBoth(e) {
		return y(() => (e.ok(this.value), this), "tapBoth ok callback threw");
	}
	tapBothAsync(e) {
		return b(async () => (await e.ok(this.value), this), "tapBothAsync ok callback threw");
	}
	*[Symbol.iterator]() {
		return this.value;
	}
}, me = class e {
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
		return y(() => new e(t(this.error)), "mapError callback threw");
	}
	tryRecover(e) {
		return y(() => e(this.error), "tryRecover callback threw");
	}
	tryRecoverAsync(e) {
		return b(() => e(this.error), "tryRecoverAsync callback threw");
	}
	andThen(e) {
		return this;
	}
	andThenAsync(e) {
		return Promise.resolve(this);
	}
	match(e) {
		return y(() => e.err(this.error), "match err handler threw");
	}
	unwrap(e) {
		return v(e ?? `Unwrap called on Err: ${String(this.error)}`, this.error);
	}
	unwrapOr(e) {
		return e;
	}
	tap(e) {
		return this;
	}
	tapError(e) {
		return y(() => (e(this.error), this), "tapError callback threw");
	}
	tapAsync(e) {
		return Promise.resolve(this);
	}
	tapErrorAsync(e) {
		return b(async () => (await e(this.error), this), "tapErrorAsync callback threw");
	}
	tapBoth(e) {
		return y(() => (e.err(this.error), this), "tapBoth err callback threw");
	}
	tapBothAsync(e) {
		return b(async () => (await e.err(this.error), this), "tapBothAsync err callback threw");
	}
	*[Symbol.iterator]() {
		return yield this, v("Unreachable: Err yielded in Result.gen but generator continued", this.error);
	}
};
function S(e) {
	return new x(e);
}
var he = (e) => e.status === "ok", C = (e) => new me(e), ge = (e) => e.status === "error", _e = (e) => e instanceof Error ? {
	name: e.name,
	message: e.message,
	stack: e.stack
} : e, ve = Object.assign((e) => () => {
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
				cause: _e(this.cause),
				stack: this.stack
			};
		}
		*[Symbol.iterator]() {
			return yield* C(this), v("Unreachable: Err yielded in TaggedError but generator continued", this);
		}
	}
	return t;
}, { is: (e) => e instanceof Error && "_tag" in e && typeof e._tag == "string" }), w = class extends ve("UnhandledException")() {
	constructor(e) {
		let t = e.cause instanceof Error ? `Unhandled exception: ${e.cause.message}` : `Unhandled exception: ${String(e.cause)}`;
		super({
			message: t,
			cause: e.cause
		});
	}
}, ye = class extends ve("ResultDeserializationError")() {
	constructor(e) {
		super({
			message: "Failed to deserialize value as Result: expected { status: \"ok\", value } or { status: \"error\", error }",
			value: e.value
		});
	}
}, be = (e, t) => {
	try {
		return e();
	} catch (e) {
		throw v(t, e);
	}
}, xe = (e, t) => {
	let n = () => {
		if (typeof e == "function") try {
			return S(e());
		} catch (e) {
			return C(new w({ cause: e }));
		}
		try {
			return S(e.try());
		} catch (t) {
			try {
				return C(e.catch(t));
			} catch (e) {
				throw v("Result.try catch handler threw", e);
			}
		}
	}, r = t?.retry?.times ?? 0, i = n();
	for (let e = 0; e < r && i.status === "error"; e++) i = n();
	return i;
}, Se = async (e, t) => {
	let n = async () => {
		if (typeof e == "function") try {
			return S(await e());
		} catch (e) {
			return C(new w({ cause: e }));
		}
		try {
			return S(await e.try());
		} catch (t) {
			try {
				return C(await e.catch(t));
			} catch (e) {
				throw v("Result.tryPromise catch handler threw", e);
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
		if (!be(() => s(t), "shouldRetry predicate threw")) break;
		await a(i(e)), o = await n();
	}
	return o;
}, Ce = _(2, (e, t) => e.map(t)), we = _(2, (e, t) => e.mapError(t)), Te = _(2, (e, t) => e.tryRecover(t)), Ee = _(2, (e, t) => e.andThen(t)), De = _(2, (e, t) => e.tryRecoverAsync(t)), Oe = _(2, (e, t) => e.andThenAsync(t)), ke = _(2, (e, t) => e.match(t)), Ae = _(2, (e, t) => e.tap(t)), je = _(2, (e, t) => e.tapAsync(t)), Me = _(2, (e, t) => e.tapError(t)), Ne = _(2, (e, t) => e.tapErrorAsync(t)), Pe = _(2, (e, t) => e.tapBoth(t)), Fe = _(2, (e, t) => e.tapBothAsync(t)), Ie = (e, t) => e.unwrap(t);
function T(e) {
	if (!(typeof e == "object" && e && "status" in e && (e.status === "ok" || e.status === "error"))) return v("Result.gen body must return Result.ok() or Result.err(), got: " + (e === null ? "null" : typeof e == "object" ? JSON.stringify(e) : String(e)));
}
var Le = _(2, (e, t) => e.unwrapOr(t)), Re = ((e, t) => {
	let n = e.call(t);
	if (Symbol.asyncIterator in n) return (async () => {
		let e = n, t;
		try {
			t = await e.next();
		} catch (e) {
			throw v("generator body threw", e);
		}
		if (T(t.value), !t.done) try {
			await e.return?.(void 0);
		} catch (e) {
			throw v("generator cleanup threw", e);
		}
		return t.value;
	})();
	let r = n, i;
	try {
		i = r.next();
	} catch (e) {
		throw v("generator body threw", e);
	}
	if (T(i.value), !i.done) try {
		r.return?.(void 0);
	} catch (e) {
		throw v("generator cleanup threw", e);
	}
	return i.value;
});
async function* ze(e) {
	return yield* await e;
}
function Be(e) {
	return typeof e == "object" && !!e && "status" in e && (e.status === "ok" && "value" in e || e.status === "error" && "error" in e);
}
var Ve = (e) => e.status === "ok" ? {
	status: "ok",
	value: e.value
} : {
	status: "error",
	error: e.error
}, E = (e) => Be(e) ? e.status === "ok" ? new x(e.value) : new me(e.error) : C(new ye({ value: e })), D = {
	ok: S,
	isOk: he,
	err: C,
	isError: ge,
	try: xe,
	tryPromise: Se,
	map: Ce,
	mapError: we,
	tryRecover: Te,
	andThen: Ee,
	tryRecoverAsync: De,
	andThenAsync: Oe,
	match: ke,
	tap: Ae,
	tapAsync: je,
	tapError: Me,
	tapErrorAsync: Ne,
	tapBoth: Pe,
	tapBothAsync: Fe,
	unwrap: Ie,
	unwrapOr: Le,
	gen: Re,
	await: ze,
	serialize: Ve,
	deserialize: E,
	hydrate: (e) => E(e),
	partition: (e) => {
		let t = [], n = [];
		for (let r of e) r.status === "ok" ? t.push(r.value) : n.push(r.error);
		return [t, n];
	},
	flatten: (e) => e.status === "ok" ? e.value : e
}, O = 42086, k = 2643, A = 6790, j = 0, He = 1, Ue = /* @__PURE__ */ new WeakMap(), M = class {
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
					this.device.opened && this.state.claimed && await this.device.releaseInterface?.(j);
				} catch {}
				if (this.state.claimed = !1, this.device.opened && (this.state.openedByLibrary || this.state.poisoned) && await this.device.close(), this.state.poisoned && this.device.opened) throw new e("Failed to reset the programmer after transaction cleanup failed.", "WebUSBLifecycleFailed");
				this.state.openedByLibrary = !1, this.state.references = 0, this.state.poisoned = !1, this.state.sessionEstablished = !1, this.closed = !0;
			} finally {
				this.state.lifecycleActive = !1;
			}
		}
	}
}, We = class {
	wasm;
	usb;
	algorithmProvider;
	constructor(e, t = R(), n) {
		this.wasm = e, this.usb = t, this.algorithmProvider = n;
	}
	deviceList(e = {}) {
		return Q(rt(() => this.wasm.deviceList(e)));
	}
	resolveDevice(e, t = "auto") {
		return Q(rt(() => this.wasm.resolveDevice(e, t)));
	}
	async getProgrammers() {
		return Q(await Z(async () => (await this.usb.getDevices()).filter(z).map(Xe)));
	}
	async requestProgrammer() {
		return Q(await Z(async () => {
			let t = await this.usb.requestDevice({ filters: [{
				vendorId: O,
				productId: k
			}, {
				vendorId: O,
				productId: A
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
		K(t.programmer), et(t), X(t.signal);
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
		return W(r, async () => {
			let t = this.wasm.resolveDevice(n.device, n.programmerKind);
			if (!t) throw new e("Device not found or unsupported by requested programmer.", "DeviceNotFound");
			let i = H(t, n.memory);
			if (i === 0) throw new e("Selected memory region is empty.", "EmptyMemoryRegion");
			let a = await U(this.algorithmProvider, t, n.programmerKind, r.productId);
			await P(r);
			let o = this.wasm.startReadROM({
				programmer: n.programmerKind,
				device: n.device,
				memory: n.memory,
				skipIdCheck: n.skipIdCheck,
				continueOnIdMismatch: n.continueOnIdMismatch,
				...a
			}), s = await this.wasm.runOperation(o, (e) => N(r, e), {
				signal: n.signal,
				onProgress: n.onProgress,
				onCleanupFailure: () => G(r)
			});
			if (s.byteLength !== i) {
				let t = s.byteLength < i ? "ShortRead" : "InvalidInput";
				throw new e(`readROM returned ${s.byteLength} of ${i} expected bytes for the selected memory region.`, t);
			}
			return s;
		});
	}
	async checkPinContacts(t) {
		K(t.programmer), $e(t.device), q(t.programmerKind, ["auto", "t48"], "programmerKind"), X(t.signal);
		let n = t.programmerKind ?? "auto", r = t.programmer.device;
		return W(r, async () => {
			let i = this.wasm.resolveDevice(t.device, n);
			if (!i) throw new e("Device not found or unsupported by requested programmer.", "DeviceNotFound");
			if (!i.supportsPinCheck) throw new e("Pin-contact checking is unavailable for this device and programmer.", "PinCheckUnavailable");
			await P(r);
			let a = this.wasm.startPinCheck({
				programmer: n,
				device: t.device
			});
			return Ze(await this.wasm.runOperation(a, (e) => N(r, e), {
				signal: t.signal,
				onCleanupFailure: () => G(r)
			}));
		});
	}
	async writeROM(t) {
		K(t.programmer), tt(t), X(t.signal);
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
		return W(r, async () => {
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
			let a = await U(this.algorithmProvider, t, n.programmerKind, r.productId);
			await P(r);
			let o = this.wasm.startWriteROM({
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
				...a
			});
			await this.wasm.runOperation(o, (e) => N(r, e), {
				signal: n.signal,
				onProgress: n.onProgress,
				onCleanupFailure: () => G(r)
			});
		});
	}
};
async function Ge(e = {}) {
	return Q(await Z(async () => new We(await le.load(e.wasmUrl), e.usb ?? R(), e.algorithmProvider)));
}
async function N(e, t) {
	if (t.direction === "out") {
		let r;
		try {
			r = await e.transferOut(t.endpoint, Ke(t.data));
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
function Ke(e) {
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
			if (t.opened && r.claimed && await t.releaseInterface?.(j).catch(() => void 0), r.claimed = !1, t.opened && await $("reset the programmer after transaction cleanup failed", () => t.close()), t.opened) throw new e("The programmer remained open after reset. Disconnect and reconnect it before continuing.", "WebUSBLifecycleFailed");
			r.openedByLibrary = !1, r.sessionEstablished = !1;
		}
		t.opened || (r.claimed = !1, await $("open USB device", () => t.open()), r.openedByLibrary = !0, i = !0), t.configuration?.configurationValue !== He && (await $("select USB configuration 1", () => t.selectConfiguration(He)), r.claimed = !1), r.claimed ||= (await $("claim USB interface 0", () => t.claimInterface(j)), !0), await qe(t), r.poisoned = !1, r.sessionEstablished = !0;
	} catch (e) {
		throw r.claimed && await t.releaseInterface?.(j).catch(() => void 0), r.claimed = !1, i && t.opened && await t.close().catch(() => void 0), i && (r.openedByLibrary = !1, r.sessionEstablished = !1), e;
	} finally {
		r.lifecycleActive = !1;
	}
}
async function qe(t) {
	let n = t.configuration?.interfaces;
	if (!n) return;
	let r = n.find((e) => e.interfaceNumber === j);
	if (!r) throw new e("USB configuration 1 does not expose interface 0.", "WebUSBLifecycleFailed");
	let i = (e) => Ye(e, t.productId);
	if (i(r.alternate)) return;
	let a = r.alternates.find(i) ?? (t.productId === k ? r.alternates.find(Je) : void 0);
	if (!a) throw new e("USB interface 0 does not expose the required bulk endpoints for this programmer.", "WebUSBLifecycleFailed");
	if (a !== r.alternate) {
		if (!t.selectAlternateInterface) throw new e("USB interface 0 requires an unsupported alternate setting.", "WebUSBLifecycleFailed");
		await $("select USB interface 0 alternate", () => t.selectAlternateInterface(j, a.alternateSetting));
	}
}
function Je(e) {
	return ["in", "out"].every((t) => e.endpoints.some((e) => e.endpointNumber === 1 && e.direction === t && e.type === "bulk"));
}
function Ye(e, t) {
	return (t === A ? [
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
	let t = Ue.get(e);
	return t || (t = {
		claimed: !1,
		lifecycleActive: !1,
		openedByLibrary: !1,
		operations: 0,
		poisoned: !1,
		references: 0,
		sessionEstablished: !1
	}, Ue.set(e, t)), t;
}
function R() {
	if (typeof navigator > "u" || !navigator.usb) throw new t();
	return navigator.usb;
}
function z(e) {
	return e.vendorId === O && (e.productId === k || e.productId === A);
}
function Xe(e) {
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
function Ze(t) {
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
async function U(t, n, r, i) {
	let a = r === "t56" || r === "t76" ? [r] : r === "auto" && i === A ? ["t76"] : r === "auto" && t ? ["t56"] : [];
	if (a.length === 0) return {};
	if (!t) throw new e(`A local algorithm provider is required for ${a[0].toUpperCase()} operations.`, "AlgorithmUnavailable");
	let o = {};
	for (let r of a) {
		let i = n.algorithms.find((e) => e.programmer === r);
		if (!i) throw new e(`The catalog does not define a ${r.toUpperCase()} algorithm for this device.`, "AlgorithmUnavailable");
		let a = await t(i);
		if (!(a instanceof Uint8Array)) throw new e("The algorithm provider must return a Uint8Array.", "InvalidAlgorithm");
		r === "t56" ? o.t56Algorithm = a.slice() : o.t76Algorithm = a.slice();
	}
	return o;
}
async function W(t, n) {
	let i = L(t);
	if (i.operations !== 0) throw new e("A programmer operation is already in progress for this programmer.", "OperationInProgress");
	i.operations += 1;
	try {
		return Q(D.ok(await n()));
	} catch (e) {
		throw i.poisoned && await Qe(t, i), Q(D.err(r(e)));
	} finally {
		--i.operations;
	}
}
function G(e) {
	L(e).poisoned = !0;
}
async function Qe(e, t) {
	e.opened && t.claimed && await e.releaseInterface?.(j).catch(() => void 0), e.opened && await e.close().catch(() => void 0), t.claimed = !1, e.opened || (t.openedByLibrary = !1), t.sessionEstablished = !1;
}
function K(t) {
	if (!(t instanceof M)) throw new e("Use WebUSBProgrammerConnection or a connection returned by the programmer API.", "WebUSBLifecycleFailed");
	if (!z(t.device)) throw new e("USB device is not a supported T48/T56/T76 programmer.", "UnsupportedProgrammer");
	if (t.isClosed) throw new e("The programmer connection is closed.", "WebUSBLifecycleFailed");
}
function $e(e) {
	(typeof e != "string" || e.trim() === "") && Y("device must be a non-empty string");
}
function et(e) {
	q(e.programmerKind, [
		"auto",
		"t48",
		"t56",
		"t76"
	], "programmerKind"), q(e.memory, [
		"code",
		"data",
		"user"
	], "memory"), J(e, ["skipIdCheck", "continueOnIdMismatch"]);
}
function tt(e) {
	e.data instanceof Uint8Array || Y("data must be a Uint8Array"), q(e.programmerKind, [
		"auto",
		"t48",
		"t56",
		"t76"
	], "programmerKind"), q(e.memory, [
		"code",
		"data",
		"user"
	], "memory"), J(e, [
		"erase",
		"verify",
		"skipIdCheck",
		"continueOnIdMismatch",
		"unprotectBefore",
		"protectAfter"
	]), nt(e.eraseNumFuses, "eraseNumFuses"), nt(e.erasePld, "erasePld");
}
function q(e, t, n) {
	e !== void 0 && (typeof e != "string" || !t.includes(e)) && Y(`${n} is invalid`);
}
function J(e, t) {
	let n = e;
	for (let e of t) n[e] !== void 0 && typeof n[e] != "boolean" && Y(`${e} must be a boolean`);
}
function nt(e, t) {
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
		return D.ok(await e());
	} catch (e) {
		return D.err(r(e));
	}
}
function rt(e) {
	try {
		return D.ok(e());
	} catch (e) {
		return D.err(r(e));
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
export { We as BrowserXgecuWebUSB, le as WasmBridge, M as WebUSBProgrammerConnection, n as WebUSBTransferError, t as WebUSBUnavailableError, e as XgecuWebUSBError, s as createAlgorithmXmlProvider, Ge as createProgrammer, N as performWebUSBTransfer };

//# sourceMappingURL=index.js.map