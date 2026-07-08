# Strict TSC and Test Type-Checking Gotchas

_Last verified: 2026-06-30_

## 1. Tests ARE Type-Checked by the Build

`frontend/tsconfig.json` has `include: ["src"]`, which means test files living in `src/**/*.test.ts(x)` ARE subject to type-checking. The build runs `tsc --noEmit` (via `build:selfhost` and `bun run build`) with strict settings that affect test code:

- **`target/lib: ES2020`** — No `Array.prototype.at`. Use `arr[arr.length - 1]!` instead.
- **`noUncheckedIndexedAccess`** — Indexed access like `arr[0]` or `mock.calls[0][0]` types as `T | undefined`. Must add `!` to assert or guard before use.
- **`noUnusedLocals`/`noUnusedParameters`** — Remove every unused import and parameter; the build will fail otherwise.

**KEY TRAP:** `bunx vitest run` PASSES even with these type errors because esbuild never type-checks—it just strips types. A green test run does NOT mean the build is green. Always run `bunx tsc --noEmit` (or `bun run build`) before declaring done. The IDE/LSP sometimes shows stale "Cannot find module" diagnostics immediately after creating a file → cascading false "implicit any" errors; `tsc --noEmit` from the shell is the authoritative check.

## 2. Vitest Mock Hoisting

A `vi.mock('mod', () => mockObj)` factory that references a `const mockObj` declared above it throws:

```
ReferenceError: Cannot access 'mockObj' before initialization
```

This happens because vitest hoists `vi.mock()` above imports and other code. **Fix:** Wrap the factory with `vi.hoisted()`:

```typescript
const { mockObj } = vi.hoisted(() => ({
  mockObj: { /* ... */ }
}));

vi.mock('mod', () => mockObj);
```

The hoisted result is now available to the `vi.mock()` call.

## 3. happy-dom Cannot Render Real CodeMirror

happy-dom (vitest's default DOM environment) lacks layout APIs. Component tests for CodeMirror or yCollab-bound editors **must mock** `@uiw/react-codemirror` and `y-codemirror.next` entirely. Assert only the binding contract:

- Correct `ytext` and `awareness` props passed into yCollab
- yCollab result appears in the extensions array
- Callbacks (onChange, etc.) are wired correctly

Real Y.Text↔editor propagation is **only verifiable in E2E** (Playwright with a real browser). Do not try to test editor mutations in vitest.

## Build & Test CLI

The frontend has no separate `lint` script. Type-checking happens via:

- `tsc --noEmit` (inside `bun run build`)
- `bun run build` — full build with type-check
- `test:e2e` — Playwright end-to-end tests (browser-based editor tests)

Always run `tsc --noEmit` before committing.
