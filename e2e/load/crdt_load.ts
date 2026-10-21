// e2e/load/crdt_load.ts
//
// CRDT half of the staging traffic simulator. Reuses the headless tier's real
// plugin engine (e2e/headless/run.ts Replica: SyncEngine + CrdtManager +
// NoteChannel over a real WebSocket) — no new protocol client.
//
// Per session: two replicas (A, B = two devices on one account). Ops:
//   burst      keystroke-rate edits on a hot note from A, then wait for the
//              server to hold the result and for B to see it (live fan-out)
//   concurrent A and B type into the SAME hot note at once, then both must
//              converge to identical bytes
//   closed     one edit to a cold note (no live room: room-free delivery)
// Hot-note content toggles between two states (type a word, erase it), so the
// server's embed path sees repeat content and stays cheap.
//
// Run (sim.py spawns this):
//   ENGRAM_PLUGIN_SRC=<plugin> ENGRAM_API_URL=<api> \
//     bun --preload ./e2e/headless/preload.ts ./e2e/load/crdt_load.ts <config.json>
// config: { sessions:[{token,userId,vaultId,label}], start, schedule:{...}, rates:{...}, out }
// Emits one JSON line per op to `out` (jsonl): {t, op, ms, ok, err?}.

import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { barrier } from "../headless/barriers";
import { Replica, realRequestUrl, type Session } from "../headless/run";

type Schedule = { warmup: number; steady: number; burst: number; burstAt: number; burstLen: number; duration: number };
type Cfg = {
	sessions: (Session & { label: string })[];
	start: number;
	schedule: Schedule;
	rates: { burst: number; concurrent: number; closed: number };
	out: string;
	apiUrl: string;
};

const cfg: Cfg = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
const out = fs.openSync(cfg.out, "a");
const KEYSTROKE_MS = 120; // ~8 chars/s, a fast typist
const WORD = "lorem";

function mult(t: number, s: Schedule): number {
	if (t < s.warmup) return 1 + ((s.steady - 1) * t) / s.warmup;
	if (t >= s.burstAt && t < s.burstAt + s.burstLen) return s.burst;
	return s.steady;
}

function record(op: string, ms: number, ok: boolean, err?: string): void {
	fs.writeSync(out, `${JSON.stringify({ t: Date.now() / 1000, op, ms: Math.round(ms), ok, err })}\n`);
}

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

async function timed(op: string, fn: () => Promise<void>): Promise<void> {
	const t0 = performance.now();
	try {
		await fn();
		record(op, performance.now() - t0, true);
	} catch (e) {
		record(op, performance.now() - t0, false, String((e as Error).message).slice(0, 200));
	}
}

async function typeWord(r: Replica, p: string, base: () => string, set: (s: string) => void, erase: boolean) {
	for (let i = 0; i < WORD.length; i++) {
		const cur = base();
		const next = erase ? cur.slice(0, -1) : cur + WORD[i];
		set(next);
		await r.editNote(p, next);
		await sleep(KEYSTROKE_MS);
	}
}

async function main(): Promise<void> {
	const obs = await import("obsidian");
	(obs as unknown as { setRequestUrlHandler: (fn: typeof realRequestUrl) => void }).setRequestUrlHandler(realRequestUrl);
	const root = fs.mkdtempSync(path.join(os.tmpdir(), "engram-load-crdt-"));
	const end = cfg.start + cfg.schedule.duration;

	await Promise.all(
		cfg.sessions.map(async (s) => {
			const a = await Replica.boot(s, `${s.label}-A`, root);
			const b = await Replica.boot(s, `${s.label}-B`, root);
			await timed("crdt_handshake", () => Promise.all([barrier.synced(a), barrier.synced(b)]).then(() => {}));
			const serverHas = (p: string, c: string) =>
				barrier.serverHasContent(cfg.apiUrl, s.token, s.vaultId, p, barrier.sha256(c));

			// Hot notes + cold notes, created once per run (stable paths, stable base).
			const hot = [0, 1].map((i) => `Hot/${s.label}-h${i}.md`);
			const cold = [0, 1, 2, 3, 4].map((i) => `Cold/${s.label}-c${i}.md`);
			const text = new Map<string, string>();
			for (const p of [...hot, ...cold]) {
				const body = `# ${path.basename(p, ".md")}\n\nshared editing surface for the load sim.\n`;
				text.set(p, body);
				const exists = fs.existsSync(path.join(a.vaultDir, p));
				await timed("crdt_create", async () => {
					if (exists) await a.editNote(p, body);
					else await a.createNote(p, body);
					await serverHas(p, body);
				});
				await barrier.noteVisible(b, p, barrier.sha256(body)).catch(() => {});
			}
			const erased = new Map<string, boolean>(hot.map((p) => [p, false]));
			const get = (p: string) => () => text.get(p) as string;
			const put = (p: string) => (v: string) => text.set(p, v);

			const loops = (["burst", "concurrent", "closed"] as const).map(async (op) => {
				while (Date.now() / 1000 < end) {
					const rate = cfg.rates[op] * mult(Date.now() / 1000 - cfg.start, cfg.schedule);
					await sleep(Math.min(60_000, (-Math.log(1 - Math.random()) / rate) * 1000));
					if (Date.now() / 1000 >= end) break;
					if (op === "burst") {
						const p = hot[0];
						await timed("crdt_burst_persist", async () => {
							await typeWord(a, p, get(p), put(p), erased.get(p) as boolean);
							erased.set(p, !erased.get(p));
							await serverHas(p, get(p)());
						});
						await timed("crdt_fanout_b", () => barrier.noteVisible(b, p, barrier.sha256(get(p)())));
					} else if (op === "concurrent") {
						// Each device types its own word at its own end of the note.
						const p = hot[1];
						await timed("crdt_two_device_converge", async () => {
							const base = get(p)();
							let ta = base;
							let tb = base;
							for (let i = 0; i < WORD.length; i++) {
								ta = `${WORD.slice(0, i + 1)}${base}`;
								tb = `${base}${WORD.slice(0, i + 1).toUpperCase()}`;
								await Promise.all([a.editNote(p, ta), b.editNote(p, tb)]);
								await sleep(KEYSTROKE_MS);
							}
							// Converged = both replicas hold the same bytes, and the server agrees.
							const deadline = Date.now() + 60_000;
							for (;;) {
								const fa = fs.readFileSync(path.join(a.vaultDir, p), "utf8");
								const fb = fs.readFileSync(path.join(b.vaultDir, p), "utf8");
								if (fa === fb && fa.includes(WORD) && fa.includes(WORD.toUpperCase())) {
									await serverHas(p, fa);
									// Reset to the base so the next round reuses content.
									text.set(p, base);
									await a.editNote(p, base);
									await serverHas(p, base);
									await barrier.noteVisible(b, p, barrier.sha256(base));
									return;
								}
								if (Date.now() > deadline) throw new Error(`no convergence: a=${fa.length}B b=${fb.length}B`);
								await sleep(100);
							}
						});
					} else {
						const p = cold[Math.floor(Math.random() * cold.length)];
						const cur = get(p)();
						const next = cur.endsWith("x\n") ? cur.slice(0, -2) : `${cur}x\n`;
						text.set(p, next);
						await timed("crdt_closed_edit_persist", async () => {
							await a.editNote(p, next);
							await serverHas(p, next);
						});
					}
				}
			});
			await Promise.all(loops);
			a.disconnect();
			b.disconnect();
		}),
	);
	fs.rmSync(root, { recursive: true, force: true });
	process.exit(0);
}

main().catch((e) => {
	record("crdt_fatal", 0, false, String((e as Error).stack ?? e).slice(0, 500));
	console.error("[crdt_load] fatal:", e);
	process.exit(1);
});
