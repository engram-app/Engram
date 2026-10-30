// e2e/load/first_sync.ts
//
// Load half of the staging first-sync proof (first_sync_proof.py). ONE real
// plugin engine (e2e/headless Replica: SyncEngine + CrdtManager + NoteChannel,
// index room wired as main.ts does) boots over a vault directory that already
// holds the generated corpus, then runs the plugin's own fullSync until every
// file is on the server. A server restart mid-sync kills the socket and fails
// in-flight pushes; the engine reconnects on its own and the next pass pushes
// what is left, which is what a real Obsidian does after an outage.
//
// Run (first_sync_proof.py spawns this):
//   ENGRAM_PLUGIN_SRC=<plugin> ENGRAM_API_URL=<api> \
//     bun --preload ./e2e/headless/preload.ts ./e2e/load/first_sync.ts - < config.json
// config: { token, userId, vaultId, root, id, out, deadline, passGapMs }
// Emits one JSON line per pass to `out`: {t, op, ms, ok, pulled?, pushed?, err?}.

import * as fs from "node:fs";
import { barrier } from "../headless/barriers";
import { Replica, realRequestUrl, type Session } from "../headless/run";

type Cfg = Session & { root: string; id: string; out: string; deadline: number; passGapMs: number; apiUrl: string };

// Same reason as crdt_load.ts: Cloudflare's Browser Integrity Check refuses an
// empty User-Agent on the upgrade, and Bun's WebSocket sends none.
const NativeWebSocket = globalThis.WebSocket;
class UAWebSocket extends NativeWebSocket {
	constructor(url: string | URL, protocols?: string | string[]) {
		// biome-ignore lint/suspicious/noExplicitAny: Bun's options-object constructor overload.
		super(url, { protocols, headers: { "User-Agent": "engram-first-sync-proof (bun)" } } as any);
	}
}
globalThis.WebSocket = UAWebSocket as typeof WebSocket;

// Config arrives on stdin ("-"): it carries a live API key, so no file holds it.
const cfg: Cfg = JSON.parse(fs.readFileSync(process.argv[2] === "-" ? 0 : process.argv[2], "utf8"));
const out = fs.openSync(cfg.out, "a");
// An error string can echo the socket URL (?token=) or an auth header: the
// key itself never reaches this file.
const record = (op: string, ms: number, ok: boolean, extra: Record<string, unknown> = {}) =>
	fs.writeSync(
		out,
		`${JSON.stringify({ t: Date.now() / 1000, op, ms: Math.round(ms), ok, ...extra }).replaceAll(cfg.token, "engram_REDACTED")}\n`,
	);

// A push racing the restart rejects somewhere the engine does not await; the
// next pass retries it, so record and carry on rather than die mid-proof.
process.on("unhandledRejection", (e) => {
	record("unhandled_rejection", 0, false, { err: String((e as Error)?.message ?? e).slice(0, 200) });
});

// The server's live counts for this vault (the same numbers the web app shows).
async function serverCounts(): Promise<{ notes: number; attachments: number } | null> {
	try {
		const r = await fetch(`${cfg.apiUrl}/vaults/${cfg.vaultId}`, {
			headers: { Authorization: `Bearer ${cfg.token}` },
		});
		if (!r.ok) return null;
		const v = ((await r.json()) as { vault: { note_count: number; attachment_count: number } }).vault;
		return { notes: v.note_count, attachments: v.attachment_count };
	} catch {
		return null;
	}
}

async function main(): Promise<void> {
	const obs = await import("obsidian");
	(obs as unknown as { setRequestUrlHandler: (fn: typeof realRequestUrl) => void }).setRequestUrlHandler(realRequestUrl);

	// The Python side tells us what "done" means: the generated corpus size.
	const manifest = JSON.parse(fs.readFileSync(`${cfg.root}/${cfg.id}.manifest.json`, "utf8")) as {
		notes: number;
		attachments: number;
		baseline_notes: number;
	};
	const want = { notes: manifest.notes + manifest.baseline_notes, attachments: manifest.attachments };

	const t0 = performance.now();
	const r = await Replica.boot(cfg, cfg.id, cfg.root, { indexRoom: true });
	await barrier.synced(r);
	record("handshake", performance.now() - t0, true);

	for (let pass = 1; Date.now() / 1000 < cfg.deadline; pass++) {
		const p0 = performance.now();
		try {
			const { pulled, pushed } = await r.fullSync();
			record("full_sync", performance.now() - p0, true, { pass, pulled, pushed });
		} catch (e) {
			record("full_sync", performance.now() - p0, false, { pass, err: String((e as Error).message).slice(0, 200) });
		}
		const have = await serverCounts();
		record("server_counts", 0, have !== null, { pass, ...have, want });
		if (have && have.notes >= want.notes && have.attachments >= want.attachments) {
			r.disconnect();
			process.exit(0);
		}
		await new Promise((res) => setTimeout(res, cfg.passGapMs));
	}
	record("deadline", 0, false);
	r.disconnect();
	process.exit(2);
}

main().catch((e) => {
	record("fatal", 0, false, { err: String((e as Error).stack ?? e).slice(0, 500) });
	console.error("[first_sync] fatal:", e);
	process.exit(1);
});
