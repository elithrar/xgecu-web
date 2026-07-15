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
		default: return "Unknown";
	}
}
//#endregion
//#region js/src/wasm.ts
var a = new TextEncoder(), o = new TextDecoder(), s = class t {
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
		let t = a.encode(e.search ?? "");
		return this.withBytes(t, (n) => {
			let r = this.exports.mp_device_list(n, t.byteLength, u(e.programmer ?? "auto"), e.limit ?? 100);
			return this.throwIfError(r), JSON.parse(o.decode(this.resultBytes()));
		});
	}
	resolveDevice(e, t = "auto") {
		let n = a.encode(e);
		return this.withBytes(n, (e) => {
			let r = this.exports.mp_device_detail(e, n.byteLength, u(t));
			return this.throwIfError(r), JSON.parse(o.decode(this.resultBytes()));
		});
	}
	startReadROM(t) {
		let n = u(t.programmer), r = d(t.memory);
		c(t.skipIdCheck, "skipIdCheck"), c(t.continueOnIdMismatch, "continueOnIdMismatch");
		let i = a.encode(t.device);
		return this.withBytes(i, (a) => {
			let o = this.exports.mp_start_read_rom(n, a, i.byteLength, r, +!!t.skipIdCheck, +!!t.continueOnIdMismatch);
			if (o === 0) throw new e(this.lastError() || "Failed to start readROM operation.");
			return this.registerOperation(o);
		});
	}
	startWriteROM(t) {
		let n = u(t.programmer), r = d(t.memory);
		if (!(t.data instanceof Uint8Array)) throw new e("data must be a Uint8Array.", "InvalidInput");
		for (let [e, n] of [
			["erase", t.erase],
			["verify", t.verify],
			["skipIdCheck", t.skipIdCheck],
			["continueOnIdMismatch", t.continueOnIdMismatch],
			["unprotectBefore", t.unprotectBefore],
			["protectAfter", t.protectAfter]
		]) c(n, e);
		l(t.eraseNumFuses, "eraseNumFuses"), l(t.erasePld, "erasePld");
		let i = a.encode(t.device);
		return this.withBytes(i, (a) => this.withBytes(t.data, (o) => {
			let s = this.exports.mp_start_write_rom(n, a, i.byteLength, r, o, t.data.byteLength, +!!t.erase, t.eraseNumFuses, t.erasePld, +!!t.verify, +!!t.skipIdCheck, +!!t.continueOnIdMismatch, +!!t.unprotectBefore, +!!t.protectAfter);
			if (s === 0) throw new e(this.lastError() || "Failed to start writeROM operation.");
			return this.registerOperation(s);
		}));
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
				if (r.signal?.aborted) throw this.exports.mp_operation_abort(t), await this.drainCleanupBestEffort(t, n), new e("Operation aborted.", "OperationAborted");
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
					if (this.exports.mp_operation_complete(t, 0, 0, 0) !== 0) throw await this.drainCleanupBestEffort(t, n), this.operationError(t);
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
					}), s !== 0) throw await this.drainCleanupBestEffort(t, n), this.operationError(t);
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
				throw new e("The ROM operation failed and the programmer transaction could not be closed. Reconnect the programmer before continuing.", "WebUSBLifecycleFailed", i);
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
		return e === 0 || t === 0 ? "" : o.decode(this.memoryBytes(e, t));
	}
	throwIfError(t) {
		if (t !== 0) throw new e(this.lastError() || "Wasm call failed.");
	}
	operationError(t) {
		let n = this.exports.mp_operation_error_code(t), r = this.exports.mp_operation_error_ptr(t), a = this.exports.mp_operation_error_len(t);
		return new e(r === 0 || a === 0 ? this.lastError() || "Wasm operation failed." : o.decode(this.memoryBytes(r, a)), i(n));
	}
	operationProgress(e) {
		return {
			phase: ee(this.exports.mp_operation_phase(e)),
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
function c(t, n) {
	if (typeof t != "boolean") throw new e(`${n} must be a boolean.`, "InvalidInput");
}
function l(t, n) {
	if (typeof t != "number" || !Number.isInteger(t) || t < 0 || t > 255) throw new e(`${n} must be an integer from 0 to 255.`, "InvalidInput");
}
function u(t) {
	switch (t) {
		case "auto": return 0;
		case "t48": return 1;
		case "t56": return 2;
		default: throw new e("Invalid programmer kind.", "InvalidInput");
	}
}
function d(t) {
	switch (t) {
		case "code": return 0;
		case "data": return 1;
		case "user": return 2;
		default: throw new e("Invalid memory kind.", "InvalidInput");
	}
}
function ee(e) {
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
function f(e, t) {
	return e === 2 ? ((...e) => e.length >= 2 ? t(e[0], e[1]) : (n) => t(n, e[0])) : e === 3 ? ((...e) => e.length >= 3 ? t(e[0], e[1], e[2]) : (n) => t(n, e[0], e[1])) : e === 4 ? ((...e) => e.length >= 4 ? t(e[0], e[1], e[2], e[3]) : (n) => t(n, e[0], e[1], e[2])) : ((...n) => n.length >= e ? t(...n) : (e) => t(e, ...n));
}
var te = (e) => e instanceof Error ? {
	name: e.name,
	message: e.message,
	stack: e.stack
} : e, ne = class e extends Error {
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
			cause: te(this.cause),
			stack: this.stack
		};
	}
	*[Symbol.iterator]() {
		return yield* y(this), p("Unreachable: Err yielded in Panic but generator continued", this);
	}
}, p = (e, t) => {
	throw new ne({
		message: e,
		cause: t
	});
}, m = (e, t) => {
	try {
		return e();
	} catch (e) {
		throw p(t, e);
	}
}, h = async (e, t) => {
	try {
		return await e();
	} catch (e) {
		throw p(t, e);
	}
}, g = class e {
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
		return m(() => new e(t(this.value)), "map callback threw");
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
		return m(() => e(this.value), "andThen callback threw");
	}
	andThenAsync(e) {
		return h(() => e(this.value), "andThenAsync callback threw");
	}
	match(e) {
		return m(() => e.ok(this.value), "match ok handler threw");
	}
	unwrap(e) {
		return this.value;
	}
	unwrapOr(e) {
		return this.value;
	}
	tap(e) {
		return m(() => (e(this.value), this), "tap callback threw");
	}
	tapAsync(e) {
		return h(async () => (await e(this.value), this), "tapAsync callback threw");
	}
	tapError(e) {
		return this;
	}
	tapErrorAsync(e) {
		return Promise.resolve(this);
	}
	tapBoth(e) {
		return m(() => (e.ok(this.value), this), "tapBoth ok callback threw");
	}
	tapBothAsync(e) {
		return h(async () => (await e.ok(this.value), this), "tapBothAsync ok callback threw");
	}
	*[Symbol.iterator]() {
		return this.value;
	}
}, _ = class e {
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
		return m(() => new e(t(this.error)), "mapError callback threw");
	}
	tryRecover(e) {
		return m(() => e(this.error), "tryRecover callback threw");
	}
	tryRecoverAsync(e) {
		return h(() => e(this.error), "tryRecoverAsync callback threw");
	}
	andThen(e) {
		return this;
	}
	andThenAsync(e) {
		return Promise.resolve(this);
	}
	match(e) {
		return m(() => e.err(this.error), "match err handler threw");
	}
	unwrap(e) {
		return p(e ?? `Unwrap called on Err: ${String(this.error)}`, this.error);
	}
	unwrapOr(e) {
		return e;
	}
	tap(e) {
		return this;
	}
	tapError(e) {
		return m(() => (e(this.error), this), "tapError callback threw");
	}
	tapAsync(e) {
		return Promise.resolve(this);
	}
	tapErrorAsync(e) {
		return h(async () => (await e(this.error), this), "tapErrorAsync callback threw");
	}
	tapBoth(e) {
		return m(() => (e.err(this.error), this), "tapBoth err callback threw");
	}
	tapBothAsync(e) {
		return h(async () => (await e.err(this.error), this), "tapBothAsync err callback threw");
	}
	*[Symbol.iterator]() {
		return yield this, p("Unreachable: Err yielded in Result.gen but generator continued", this.error);
	}
};
function v(e) {
	return new g(e);
}
var re = (e) => e.status === "ok", y = (e) => new _(e), ie = (e) => e.status === "error", ae = (e) => e instanceof Error ? {
	name: e.name,
	message: e.message,
	stack: e.stack
} : e, b = Object.assign((e) => () => {
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
				cause: ae(this.cause),
				stack: this.stack
			};
		}
		*[Symbol.iterator]() {
			return yield* y(this), p("Unreachable: Err yielded in TaggedError but generator continued", this);
		}
	}
	return t;
}, { is: (e) => e instanceof Error && "_tag" in e && typeof e._tag == "string" }), x = class extends b("UnhandledException")() {
	constructor(e) {
		let t = e.cause instanceof Error ? `Unhandled exception: ${e.cause.message}` : `Unhandled exception: ${String(e.cause)}`;
		super({
			message: t,
			cause: e.cause
		});
	}
}, oe = class extends b("ResultDeserializationError")() {
	constructor(e) {
		super({
			message: "Failed to deserialize value as Result: expected { status: \"ok\", value } or { status: \"error\", error }",
			value: e.value
		});
	}
}, se = (e, t) => {
	try {
		return e();
	} catch (e) {
		throw p(t, e);
	}
}, ce = (e, t) => {
	let n = () => {
		if (typeof e == "function") try {
			return v(e());
		} catch (e) {
			return y(new x({ cause: e }));
		}
		try {
			return v(e.try());
		} catch (t) {
			try {
				return y(e.catch(t));
			} catch (e) {
				throw p("Result.try catch handler threw", e);
			}
		}
	}, r = t?.retry?.times ?? 0, i = n();
	for (let e = 0; e < r && i.status === "error"; e++) i = n();
	return i;
}, le = async (e, t) => {
	let n = async () => {
		if (typeof e == "function") try {
			return v(await e());
		} catch (e) {
			return y(new x({ cause: e }));
		}
		try {
			return v(await e.try());
		} catch (t) {
			try {
				return y(await e.catch(t));
			} catch (e) {
				throw p("Result.tryPromise catch handler threw", e);
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
		if (!se(() => s(t), "shouldRetry predicate threw")) break;
		await a(i(e)), o = await n();
	}
	return o;
}, ue = f(2, (e, t) => e.map(t)), de = f(2, (e, t) => e.mapError(t)), fe = f(2, (e, t) => e.tryRecover(t)), pe = f(2, (e, t) => e.andThen(t)), me = f(2, (e, t) => e.tryRecoverAsync(t)), he = f(2, (e, t) => e.andThenAsync(t)), ge = f(2, (e, t) => e.match(t)), _e = f(2, (e, t) => e.tap(t)), ve = f(2, (e, t) => e.tapAsync(t)), ye = f(2, (e, t) => e.tapError(t)), be = f(2, (e, t) => e.tapErrorAsync(t)), xe = f(2, (e, t) => e.tapBoth(t)), Se = f(2, (e, t) => e.tapBothAsync(t)), Ce = (e, t) => e.unwrap(t);
function S(e) {
	if (!(typeof e == "object" && e && "status" in e && (e.status === "ok" || e.status === "error"))) return p("Result.gen body must return Result.ok() or Result.err(), got: " + (e === null ? "null" : typeof e == "object" ? JSON.stringify(e) : String(e)));
}
var we = f(2, (e, t) => e.unwrapOr(t)), Te = ((e, t) => {
	let n = e.call(t);
	if (Symbol.asyncIterator in n) return (async () => {
		let e = n, t;
		try {
			t = await e.next();
		} catch (e) {
			throw p("generator body threw", e);
		}
		if (S(t.value), !t.done) try {
			await e.return?.(void 0);
		} catch (e) {
			throw p("generator cleanup threw", e);
		}
		return t.value;
	})();
	let r = n, i;
	try {
		i = r.next();
	} catch (e) {
		throw p("generator body threw", e);
	}
	if (S(i.value), !i.done) try {
		r.return?.(void 0);
	} catch (e) {
		throw p("generator cleanup threw", e);
	}
	return i.value;
});
async function* Ee(e) {
	return yield* await e;
}
function De(e) {
	return typeof e == "object" && !!e && "status" in e && (e.status === "ok" && "value" in e || e.status === "error" && "error" in e);
}
var Oe = (e) => e.status === "ok" ? {
	status: "ok",
	value: e.value
} : {
	status: "error",
	error: e.error
}, C = (e) => De(e) ? e.status === "ok" ? new g(e.value) : new _(e.error) : y(new oe({ value: e })), w = {
	ok: v,
	isOk: re,
	err: y,
	isError: ie,
	try: ce,
	tryPromise: le,
	map: ue,
	mapError: de,
	tryRecover: fe,
	andThen: pe,
	tryRecoverAsync: me,
	andThenAsync: he,
	match: ge,
	tap: _e,
	tapAsync: ve,
	tapError: ye,
	tapErrorAsync: be,
	tapBoth: xe,
	tapBothAsync: Se,
	unwrap: Ce,
	unwrapOr: we,
	gen: Te,
	await: Ee,
	serialize: Oe,
	deserialize: C,
	hydrate: (e) => C(e),
	partition: (e) => {
		let t = [], n = [];
		for (let r of e) r.status === "ok" ? t.push(r.value) : n.push(r.error);
		return [t, n];
	},
	flatten: (e) => e.status === "ok" ? e.value : e
}, T = 42086, E = 2643, D = 0, O = 1, k = /* @__PURE__ */ new WeakMap(), A = class {
	device;
	closed = !1;
	state;
	constructor(e) {
		this.device = e, this.state = R(e), this.state.references += 1;
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
		return V(this.device.productName);
	}
	get manufacturerName() {
		return V(this.device.manufacturerName);
	}
	get serialNumber() {
		return V(this.device.serialNumber);
	}
	get isClosed() {
		return this.closed;
	}
	async close() {
		if (!this.closed) {
			if (this.state.operations !== 0) throw new e("A ROM operation is still in progress for this programmer.", "OperationInProgress");
			if (this.state.lifecycleActive) throw new e("A USB lifecycle operation is already in progress for this programmer.", "OperationInProgress");
			if (this.state.references > 1) {
				--this.state.references, this.closed = !0;
				return;
			}
			this.state.lifecycleActive = !0;
			try {
				try {
					this.device.opened && this.state.claimed && await this.device.releaseInterface?.(D);
				} catch {}
				if (this.state.claimed = !1, this.device.opened && (this.state.openedByLibrary || this.state.poisoned) && await this.device.close(), this.state.poisoned && this.device.opened) throw new e("Failed to reset the programmer after transaction cleanup failed.", "WebUSBLifecycleFailed");
				this.state.openedByLibrary = !1, this.state.references = 0, this.state.poisoned = !1, this.state.sessionEstablished = !1, this.closed = !0;
			} finally {
				this.state.lifecycleActive = !1;
			}
		}
	}
}, j = class {
	wasm;
	usb;
	constructor(e, t = z()) {
		this.wasm = e, this.usb = t;
	}
	deviceList(e = {}) {
		return Q(Z(() => this.wasm.deviceList(e)));
	}
	resolveDevice(e, t = "auto") {
		return Q(Z(() => this.wasm.resolveDevice(e, t)));
	}
	async getProgrammers() {
		return Q(await X(async () => (await this.usb.getDevices()).filter(B).map(Me)));
	}
	async requestProgrammer() {
		return Q(await X(async () => {
			let t = await this.usb.requestDevice({ filters: [{
				vendorId: T,
				productId: E
			}] });
			if (!B(t)) throw new e("Selected USB device is not a supported T48/T56 programmer.", "UnsupportedProgrammer");
			return await P(t), L(t);
		}));
	}
	async connectProgrammer(t) {
		return Q(await X(async () => {
			if (!B(t)) throw new e("USB device is not a supported T48/T56 programmer.", "UnsupportedProgrammer");
			return await P(t), L(t);
		}));
	}
	async readROM(e) {
		W(e.programmer), Fe(e), Y(e.signal);
		let t = {
			programmer: e.programmer,
			programmerKind: e.programmerKind ?? "auto",
			device: e.device,
			memory: e.memory ?? "code",
			skipIdCheck: e.skipIdCheck ?? !1,
			continueOnIdMismatch: e.continueOnIdMismatch ?? !1,
			signal: e.signal,
			onProgress: e.onProgress
		}, n = t.programmer.device;
		return H(n, async () => {
			await N(n);
			let e = this.wasm.startReadROM({
				programmer: t.programmerKind,
				device: t.device,
				memory: t.memory,
				skipIdCheck: t.skipIdCheck,
				continueOnIdMismatch: t.continueOnIdMismatch
			});
			return this.wasm.runOperation(e, (e) => M(n, e), {
				signal: t.signal,
				onProgress: t.onProgress,
				onCleanupFailure: () => U(n)
			});
		});
	}
	async writeROM(t) {
		W(t.programmer), Ie(t), Y(t.signal);
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
		return H(r, async () => {
			let t = this.wasm.resolveDevice(n.device, n.programmerKind);
			if (!t) throw new e("Device not found or unsupported by requested programmer.", "DeviceNotFound");
			let i = Ne(t, n.memory);
			if (i === 0) throw new e("Selected memory region is empty.", "EmptyMemoryRegion");
			if (n.data.byteLength > i) throw new e("writeROM data is larger than the selected memory region.", "InputTooLarge");
			if (n.erase && n.memory !== "code") throw new e("Erase writes are restricted to full code-memory images because erase scope is device-specific.", "InvalidInput");
			if (n.erase && n.data.byteLength !== i) throw new e("writeROM data must match the selected memory region when erase is enabled.", "InputTooLarge");
			if (n.erase && !t.canErase) throw new e("The selected device cannot be electrically erased. Externally erase and blank-check it, then write with erase: false.", "InvalidInput");
			await N(r);
			let a = this.wasm.startWriteROM({
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
				protectAfter: n.protectAfter
			});
			await this.wasm.runOperation(a, (e) => M(r, e), {
				signal: n.signal,
				onProgress: n.onProgress,
				onCleanupFailure: () => U(r)
			});
		});
	}
};
async function ke(e = {}) {
	return Q(await X(async () => new j(await s.load(e.wasmUrl), e.usb ?? z())));
}
async function M(e, t) {
	if (t.direction === "out") {
		let r;
		try {
			r = await e.transferOut(t.endpoint, Ae(t.data));
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
function Ae(e) {
	let t = new Uint8Array(e.byteLength);
	return t.set(e), t.buffer;
}
async function N(e) {
	await P(e, !0);
}
async function P(t, n = !1) {
	let r = R(t);
	if (r.lifecycleActive || !n && r.operations !== 0) throw new e("A USB lifecycle operation is already in progress for this programmer.", "OperationInProgress");
	if (n && !t.opened && r.sessionEstablished) throw new e("The programmer connection was lost. Reconnect before starting another ROM operation.", "WebUSBLifecycleFailed");
	if (n && r.poisoned) throw new e("The programmer is in an unknown transaction state. Reconnect before starting another ROM operation.", "WebUSBLifecycleFailed");
	r.lifecycleActive = !0;
	let i = !1;
	try {
		if (!n && r.poisoned) {
			if (t.opened && r.claimed && await t.releaseInterface?.(D).catch(() => void 0), r.claimed = !1, t.opened && await $("reset the programmer after transaction cleanup failed", () => t.close()), t.opened) throw new e("The programmer remained open after reset. Disconnect and reconnect it before continuing.", "WebUSBLifecycleFailed");
			r.openedByLibrary = !1, r.sessionEstablished = !1;
		}
		t.opened || (r.claimed = !1, await $("open USB device", () => t.open()), r.openedByLibrary = !0, i = !0), t.configuration?.configurationValue !== O && (await $("select USB configuration 1", () => t.selectConfiguration(O)), r.claimed = !1), r.claimed ||= (await $("claim USB interface 0", () => t.claimInterface(D)), !0), await je(t), r.poisoned = !1, r.sessionEstablished = !0;
	} catch (e) {
		throw r.claimed && await t.releaseInterface?.(D).catch(() => void 0), r.claimed = !1, i && t.opened && await t.close().catch(() => void 0), i && (r.openedByLibrary = !1, r.sessionEstablished = !1), e;
	} finally {
		r.lifecycleActive = !1;
	}
}
async function je(t) {
	let n = t.configuration?.interfaces;
	if (!n) return;
	let r = n.find((e) => e.interfaceNumber === D);
	if (!r) throw new e("USB configuration 1 does not expose interface 0.", "WebUSBLifecycleFailed");
	if (F(r.alternate)) return;
	let i = r.alternates.find(F) ?? (I(r.alternate) ? r.alternate : r.alternates.find(I));
	if (!i) throw new e("USB interface 0 does not expose command endpoint 1 in both directions.", "WebUSBLifecycleFailed");
	if (i !== r.alternate) {
		if (!t.selectAlternateInterface) throw new e("USB interface 0 requires an unsupported alternate setting.", "WebUSBLifecycleFailed");
		await $("select USB interface 0 alternate", () => t.selectAlternateInterface(D, i.alternateSetting));
	}
}
function F(e) {
	return [1, 2].every((t) => ["in", "out"].every((n) => e.endpoints.some((e) => e.endpointNumber === t && e.direction === n && e.type === "bulk")));
}
function I(e) {
	return ["in", "out"].every((t) => e.endpoints.some((e) => e.endpointNumber === 1 && e.direction === t && e.type === "bulk"));
}
function L(e) {
	return new A(e);
}
function R(e) {
	let t = k.get(e);
	return t || (t = {
		claimed: !1,
		lifecycleActive: !1,
		openedByLibrary: !1,
		operations: 0,
		poisoned: !1,
		references: 0,
		sessionEstablished: !1
	}, k.set(e, t)), t;
}
function z() {
	if (typeof navigator > "u" || !navigator.usb) throw new t();
	return navigator.usb;
}
function B(e) {
	return e.vendorId === T && e.productId === E;
}
function Me(e) {
	return {
		productName: V(e.productName),
		manufacturerName: V(e.manufacturerName),
		serialNumber: V(e.serialNumber),
		vendorId: e.vendorId,
		productId: e.productId,
		opened: e.opened
	};
}
function V(e) {
	if (e != null) return e.split("\0", 1)[0].trim() || void 0;
}
function Ne(e, t) {
	switch (t) {
		case "code": return e.codeMemorySize;
		case "data": return e.dataMemorySize;
		case "user": return e.userMemorySize;
	}
}
async function H(t, n) {
	let i = R(t);
	if (i.operations !== 0) throw new e("A ROM operation is already in progress for this programmer.", "OperationInProgress");
	i.operations += 1;
	try {
		return Q(w.ok(await n()));
	} catch (e) {
		throw i.poisoned && await Pe(t, i), Q(w.err(r(e)));
	} finally {
		--i.operations;
	}
}
function U(e) {
	R(e).poisoned = !0;
}
async function Pe(e, t) {
	e.opened && t.claimed && await e.releaseInterface?.(D).catch(() => void 0), e.opened && await e.close().catch(() => void 0), t.claimed = !1, e.opened || (t.openedByLibrary = !1), t.sessionEstablished = !1;
}
function W(t) {
	if (!(t instanceof A)) throw new e("Use WebUSBProgrammerConnection or a connection returned by the programmer API.", "WebUSBLifecycleFailed");
	if (!B(t.device)) throw new e("USB device is not a supported T48/T56 programmer.", "UnsupportedProgrammer");
	if (t.isClosed) throw new e("The programmer connection is closed.", "WebUSBLifecycleFailed");
}
function Fe(e) {
	G(e.programmerKind, [
		"auto",
		"t48",
		"t56"
	], "programmerKind"), G(e.memory, [
		"code",
		"data",
		"user"
	], "memory"), K(e, ["skipIdCheck", "continueOnIdMismatch"]);
}
function Ie(e) {
	e.data instanceof Uint8Array || J("data must be a Uint8Array"), G(e.programmerKind, [
		"auto",
		"t48",
		"t56"
	], "programmerKind"), G(e.memory, [
		"code",
		"data",
		"user"
	], "memory"), K(e, [
		"erase",
		"verify",
		"skipIdCheck",
		"continueOnIdMismatch",
		"unprotectBefore",
		"protectAfter"
	]), q(e.eraseNumFuses, "eraseNumFuses"), q(e.erasePld, "erasePld");
}
function G(e, t, n) {
	e !== void 0 && (typeof e != "string" || !t.includes(e)) && J(`${n} is invalid`);
}
function K(e, t) {
	let n = e;
	for (let e of t) n[e] !== void 0 && typeof n[e] != "boolean" && J(`${e} must be a boolean`);
}
function q(e, t) {
	e !== void 0 && (typeof e != "number" || !Number.isInteger(e) || e < 0 || e > 255) && J(`${t} must be an integer from 0 to 255`);
}
function J(t) {
	throw new e(t, "InvalidInput");
}
function Y(t) {
	if (t?.aborted) throw new e("Operation aborted.", "OperationAborted");
}
async function X(e) {
	try {
		return w.ok(await e());
	} catch (e) {
		return w.err(r(e));
	}
}
function Z(e) {
	try {
		return w.ok(e());
	} catch (e) {
		return w.err(r(e));
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
export { j as BrowserXgecuWebUSB, s as WasmBridge, A as WebUSBProgrammerConnection, n as WebUSBTransferError, t as WebUSBUnavailableError, e as XgecuWebUSBError, ke as createProgrammer, M as performWebUSBTransfer };

//# sourceMappingURL=index.js.map