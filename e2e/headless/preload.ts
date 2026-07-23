// e2e/headless/preload.ts
//
// `bun --preload` for the headless protocol tier. Runs BEFORE run.ts so that,
// by the time any plugin module evaluates:
//   1. `import ... from "obsidian"` resolves to the sim tier's obsidian shim
//      (the SAME real TFile/TFolder identities the engine's `instanceof` checks
//      use, plus an injectable requestUrl that run.ts points at real `fetch`);
//   2. `window` exists (plugin code uses window.setTimeout per the
//      obsidianmd/prefer-window-timers lint) — aliased to globalThis so REAL
//      timers back it (this tier is real time, not the sim's virtual clock);
//   3. a fake indexedDB global exists for the CRDT manager's y-indexeddb
//      persistence.
//
// Everything is sourced from the plugin worktree at ENGRAM_PLUGIN_SRC, exactly
// as the existing e2e jobs consume plugin source.

import { plugin } from "bun";
import * as path from "node:path";

const PLUGIN_SRC = process.env.ENGRAM_PLUGIN_SRC;
if (!PLUGIN_SRC) {
	throw new Error("ENGRAM_PLUGIN_SRC is required (absolute path to the plugin worktree)");
}

// (2) window -> globalThis, so window.setTimeout/clearTimeout are real timers.
const g = globalThis as unknown as { window?: typeof globalThis };
if (!g.window) g.window = globalThis;

// (3) A fake indexedDB. The CRDT doc still persists locally through
// IndexeddbPersistence; back it with an in-memory fake. One factory shared by
// both replicas is fine — the wiring namespaces its store by dbPrefix=replicaId,
// so the two "devices" never converge through shared IDB (the seam the sim
// tier documents in replica.ts). Resolved from the plugin's node_modules.
await import(path.join(PLUGIN_SRC, "node_modules/fake-indexeddb/auto"));

// (1) Route every bare `import ... from "obsidian"` to the sim's shim.
const shimPath = path.join(PLUGIN_SRC, "tests/sim/obsidian-shim.ts");
plugin({
	name: "obsidian-alias",
	setup(build) {
		build.module("obsidian", () => ({ exports: require(shimPath), loader: "object" }));
	},
});
