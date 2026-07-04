# Agent guide for @xgecu/webusb

This repository builds a browser WebUSB package for XGecu T48/T56 programmers. The core protocol logic is Zig, the browser ABI is Wasm, and the public browser API is TypeScript.

## Working principles

- Treat ROM programming as hardware-affecting work. Prefer safe defaults, explicit checks, and examples that read/backup before write.
- Keep the package centered on T48/T56, WebUSB, Wasm, TypeScript, and the generated catalog.
- Make API, docs, tests, and examples move together. If a public TypeScript type or Zig API changes, update `docs/`, `README.md`, and relevant tests in the same change.
- Prefer small, reviewable changes over broad rewrites. Keep protocol byte changes especially focused and well tested.
- Do not add dependencies unless the existing toolchain cannot reasonably solve the problem.

## Prompt engineering for agents

When giving or refining tasks for OpenAI models and coding agents, include:

1. **Goal**: the user-visible behavior or package surface to change.
2. **Scope**: files, APIs, or subsystems expected to change.
3. **Safety constraints**: hardware safety rules, browser compatibility requirements, and any examples that must avoid destructive defaults.
4. **Verification**: exact scripts or tests expected to pass.
5. **Non-goals**: features or subsystems that should remain untouched.

Good task shape:

```text
Update the WebUSB read path so T56 reads stay within the protocol payload window.
Touch Zig protocol/Wasm code only if needed. Preserve public TypeScript API names.
Add tests for the chunk boundary and run pnpm run ci.
```

Avoid vague prompts such as "clean this up" unless paired with concrete review criteria.

## OpenAI model guidance

- Use a strong reasoning model for protocol, Wasm ABI, catalog generation, or safety-sensitive review work.
- Ask the model to list assumptions before editing when hardware behavior, byte layouts, or browser lifecycle rules are involved.
- Ask for findings first during reviews: severity, file/line, impact, and a minimal fix direction.
- For implementation prompts, require the model to verify against source code rather than relying on memory of WebUSB or Zig APIs.
- For docs prompts, require examples to compile conceptually against exported TypeScript types from `js/src/types.ts`.

## Repository map

- `src/programmer/protocol_bytes.zig`: shared command bytes, endpoints, and packet sizes for T48/T56 paths.
- `src/programmer/t48.zig`, `src/programmer/t56.zig`: packet-level programmer protocols.
- `src/programmer/transport.zig`: host-neutral transport interface and test fake.
- `src/ops/rom.zig`: public Zig ROM read/write operations.
- `src/wasm/abi.zig`: Wasm operation state machine driven by JavaScript transfers.
- `js/src/webusb.ts`: high-level browser API and WebUSB transfer mapping.
- `js/src/wasm.ts`: TypeScript wrapper for the Wasm ABI.
- `data/catalog.json`: source catalog metadata.
- `tools/generate-catalog.mjs`: catalog generator for `src/catalog/generated.zig`.
- `examples/react-rom-demo`: React/Vite browser demo.
- `docs/`: API, WebUSB behavior, examples, and safety guidance.

## Build and verification

Use pnpm scripts as the canonical workflow:

```sh
pnpm install
pnpm run generate:catalog
pnpm run check:catalog
pnpm run test:zig
pnpm run test:js
pnpm run typecheck
pnpm run build
pnpm run demo:typecheck
pnpm run demo:build
pnpm run ci
```

`pnpm run ci` is the local equivalent of the GitHub workflow. It runs catalog drift checks, Zig checks/tests, Vitest, TypeScript typecheck, package build, and demo checks.

The workflow uses Zig 0.16.0. If Zig is not on `PATH` in an agent environment, install or select Zig 0.16.0 for local verification rather than changing project scripts.

## Catalog rules

- Edit `data/catalog.json` for catalog source changes.
- Run `pnpm run generate:catalog` after catalog edits.
- Run `pnpm run check:catalog` before committing.
- T56 support requires a non-empty algorithm payload in the catalog source.
- Keep generated Zig output deterministic.

## API and docs guardrails

- Public browser API lives in `js/src/types.ts` and `js/src/index.ts`.
- High-level apps should use `createProgrammer()`, `deviceList()`, `requestProgrammer()`, `readROM()`, and `writeROM()`.
- Document defaults:
  - `programmerKind`: `"auto"`
  - `memory`: `"code"`
  - `erase`: `true`
  - `verify`: `true`
  - `skipIdCheck`: `false`
- Do not show write examples without a prior read/backup, image length check, explicit `erase: true`, and `verify: true`.
- Always close `ProgrammerConnection` in examples with `try`/`finally`.
- Keep examples browser-compatible and TypeScript-first.

## Protocol and Wasm guardrails

- Keep packet constants centralized in `src/programmer/protocol_bytes.zig`.
- Reuse shared packet encoders where practical; avoid duplicating byte layouts in Wasm and native Zig paths.
- Validate buffer sizes before sending USB command bytes.
- Keep T56 read sizes capped to the protocol payload window.
- Preserve operation cleanup: Wasm operation handles must be destroyed on success and failure.
- Prefer explicit error propagation and targeted error sets over broad catch-all behavior.
- Use `defer`/`errdefer` immediately after allocations or partial initialization.

## Hardware safety guardrails

- Never weaken ID checks, erase/verify defaults, or size validation without explicit tests and docs.
- Treat overcurrent and programmer status errors as hard failures.
- Do not make examples encourage repeated writes or unattended write loops.
- Browser permission means access to the programmer only; examples must still tell users to confirm chip marking, orientation, package, and adapter.

## Review checklist

Before finalizing agent changes:

- `pnpm run ci` passes.
- Generated catalog files are up to date.
- Public API changes are reflected in docs and examples.
- New protocol behavior has Zig tests.
- New WebUSB behavior has Vitest coverage where practical.
- Docs avoid unsafe write shortcuts.
- The final diff does not include build artifacts from `dist`, `zig-out`, or demo build output.
