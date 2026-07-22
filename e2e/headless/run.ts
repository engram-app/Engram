// e2e/headless/run.ts
//
// Headless PROTOCOL tier: boots the REAL plugin SyncEngine + CrdtManager +
// NoteChannel headless (obsidian shimmed, vault = real temp-dir fs) and points
// them at the REAL backend over REAL WebSockets in REAL time. Unlike the plugin
// sim tier — which uses a seeded scheduler + model server to prove CLIENT merge
// logic — this tier's job is the PROTOCOL: it proves the real server persists
// and delivers over real Phoenix channels. It reuses ONLY the sim's obsidian
// shim + fs vault adapter + the main.ts boot wiring order; the sim's
// scheduler/clock/model-server are NOT used (real time, real server).
//
// Run:  ENGRAM_PLUGIN_SRC=<plugin worktree> ENGRAM_API_URL=http://localhost:8100/api \
//         bun --preload ./e2e/headless/preload.ts ./e2e/headless/run.ts
//
// Exit 0 = all GREEN gate scenarios passed; exit 1 = any GREEN scenario failed
// or setup failed. The #282 repro (see below) is reported but NEVER fails the
// process — it documents an OPEN main bug, like the #285 TODO.
//
// GATE COVERAGE (do NOT over-read): the 4 green scenarios prove catch-up
// delivery (server -> replica) + server persistence. They do NOT prove live
// real-time A->B fan-out — that path is NOT gated (blocked by plugin #282 that
// this tier reproduces below). See e2e/headless/README.md "Deferred scenarios".
//
// DEFERRED (not yet in the gate, disclosed like the payloads below):
//   - edit->deliver, offline-queue flush — achievable via catch-up WITHOUT
//     #282; good next additions.
//   - rename both-paths — deferred.
//   - live A->B fan-out — NOT gated; blocked by plugin #282.
//   - stale-head #285 regression — TODO, needs #1073 in the image.
//
// ---------------------------------------------------------------------------
// TWO deferred/known payloads this tier exists to pin (both are protocol/server
// bugs the client-only sim tier cannot see by construction):
//
// TODO(headless): stale-head #285 regression — terminate_room via the
//   backend_rpc HTTP seam, edit via REST, reconnect a replica, MUST converge
//   (the #285 e2e-equivalent, deterministic in minutes not dice). Needs the
//   #285 server fix in the image (unmerged PR #1073). Add once #1073 merges.
//
// #282 (fence v<=v collision masks heal) — REPRODUCED HERE, deterministically,
//   by the `HEADLESS_REPRO_282` scenario below. A LIVE note_yjs_update to an
//   idle (never-live-bound) receiver routes through adoptHistoryLessNote ->
//   REST getUpdates; that pull loses a commit race (404) so the content never
//   applies, but the op's seq still stamps the per-path fence (syncState.seq).
//   The follow-up seq-replay then sees the content op at `seq <= fence` and
//   SKIPS it as history — the note is stuck empty forever. Confirmed against
//   the running 0.6.0 image: the SAME note converges cleanly for a late-joiner
//   / a reconnecting replica (no live op ever stamped the fence), so the server
//   delivery path is sound; the bug is purely the client fence collision. This
//   scenario is the tier's live payload — it is RED on main and gated OFF the
//   green exit code until plugin #282 lands.
// ---------------------------------------------------------------------------

import { execFileSync } from "node:child_process";
import { randomUUID } from "node:crypto";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { CatchupSignal, barrier } from "./barriers";

const PLUGIN_SRC = requireEnv("ENGRAM_PLUGIN_SRC");
const API_URL = (process.env.ENGRAM_API_URL ?? "http://localhost:8100/api").replace(/\/+$/, "");
// Postgres container for the plan-override grant (mirrors e2e/helpers/billing.py).
const CI_POSTGRES_CONTAINER = process.env.CI_POSTGRES_CONTAINER ?? "engram-crdt-postgres-1";

function requireEnv(name: string): string {
	const v = process.env[name];
	if (!v) throw new Error(`${name} is required`);
	return v;
}

// Dynamic import of plugin source — its bare `obsidian` imports are aliased by
// preload.ts; its relative + node_modules imports resolve inside the worktree.
// biome-ignore lint/suspicious/noExplicitAny: cross-repo dynamic import, no shared types.
function imp(rel: string): Promise<any> {
	return import(path.join(PLUGIN_SRC, rel));
}

// ---------------------------------------------------------------------------
// requestUrl -> real fetch. Mirrors obsidian's requestUrl contract the engine
// relies on (api.ts): parsed `.json`, raw `.text`, numeric `.status`; throws an
// Error carrying `.status` on >=400 unless `throw:false` (callers classify on
// .status for 402/401/404/409).
// ---------------------------------------------------------------------------
async function realRequestUrl(opts: {
	url: string;
	method?: string;
	headers?: Record<string, string>;
	body?: string;
	throw?: boolean;
}): Promise<unknown> {
	const res = await fetch(opts.url, { method: opts.method ?? "GET", headers: opts.headers, body: opts.body });
	const text = await res.text();
	let json: unknown;
	try {
		json = text ? JSON.parse(text) : undefined;
	} catch {
		json = undefined;
	}
	if (res.status >= 400 && opts.throw !== false) {
		throw Object.assign(new Error(`request failed: ${res.status}`), { status: res.status });
	}
	return { status: res.status, json, text, arrayBuffer: new ArrayBuffer(0), headers: {} };
}

// ---------------------------------------------------------------------------
// REST setup against the real backend: one shared local user + api key + vault
// (both replicas = two devices on ONE account + ONE vault, so they share the
// crdt:<user>:<vault> room). Mirrors e2e/helpers/auth_provider.py LocalAuthProvider.
// ---------------------------------------------------------------------------
interface Session {
	token: string;
	userId: string;
	vaultId: string;
}

// biome-ignore lint/suspicious/noExplicitAny: dynamic JSON bodies.
async function jsonFetch(pathname: string, init: RequestInit): Promise<{ status: number; body: any }> {
	const res = await fetch(`${API_URL}${pathname}`, init);
	const text = await res.text();
	let body: unknown;
	try {
		body = text ? JSON.parse(text) : undefined;
	} catch {
		body = text;
	}
	return { status: res.status, body };
}

// Pricing v2 §G gates default Free-tier limits that block API-key traffic
// (api_rps_cap=0 -> 429, api_write_enabled=false -> 403) and cap devices at 1
// (our two replicas = two devices on one account). Lift them via SQL keyed on
// email, exactly as e2e/helpers/billing.py grant_test_plan does — the first
// api-key-authed request would itself 429 before any HTTP grant could land.
const TEST_USER_OVERRIDES: Record<string, unknown> = {
	api_write_enabled: true,
	api_rps_cap: 1000,
	obsidian_connections_cap: -1,
	mcp_connections_cap: -1,
	concurrent_devices: -1,
};

function grantTestPlan(email: string): void {
	const values = Object.entries(TEST_USER_OVERRIDES)
		.map(
			([k, v]) =>
				`((SELECT id FROM users WHERE email = '${email}'), '${k}', '${JSON.stringify({ v })}'::jsonb, 'headless-tier', 'e2e')`,
		)
		.join(", ");
	const sql =
		"INSERT INTO user_limit_overrides (user_id, key, value, reason, set_by) " +
		`VALUES ${values} ` +
		"ON CONFLICT (user_id, key) DO UPDATE SET value = EXCLUDED.value, set_at = NOW();";
	execFileSync(
		"docker",
		["exec", "-i", CI_POSTGRES_CONTAINER, "psql", "-U", "engram", "-d", "engram", "-tA", "-c", sql],
		{ timeout: 10_000 },
	);
}

async function setupSession(): Promise<Session> {
	const email = `headless-${Date.now()}-${randomUUID().slice(0, 8)}@e2e.local`;
	const password = "headless-Passw0rd!";
	const clientId = `headless-shared-${randomUUID().slice(0, 8)}`;

	const reg = await jsonFetch("/auth/register", {
		method: "POST",
		headers: { "Content-Type": "application/json" },
		body: JSON.stringify({ email, password }),
	});
	if (reg.status !== 201) throw new Error(`register failed: ${reg.status} ${JSON.stringify(reg.body)}`);
	const accessToken = reg.body.access_token as string;
	// Lift the Free-tier gates before any api-key-authed request (which would 429).
	grantTestPlan(email);
	const bearer = { Authorization: `Bearer ${accessToken}`, "Content-Type": "application/json" };

	const key = await jsonFetch("/api-keys", {
		method: "POST",
		headers: bearer,
		body: JSON.stringify({ name: "headless-tier" }),
	});
	if (key.status !== 200) throw new Error(`api-key failed: ${key.status} ${JSON.stringify(key.body)}`);
	const token = key.body.key as string;

	const onboard = await jsonFetch("/onboarding/profile", {
		method: "PATCH",
		headers: bearer,
		body: JSON.stringify({ uses_obsidian: true, tools: ["claude"] }),
	});
	if (![200, 201].includes(onboard.status)) {
		throw new Error(`onboarding failed: ${onboard.status} ${JSON.stringify(onboard.body)}`);
	}

	const vault = await jsonFetch("/vaults/register", {
		method: "POST",
		headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
		body: JSON.stringify({ name: "headless-vault", client_id: clientId }),
	});
	if (![200, 201].includes(vault.status)) {
		throw new Error(`vault register failed: ${vault.status} ${JSON.stringify(vault.body)}`);
	}
	const vaultId = (vault.body.id ?? vault.body.vault?.id) as string;

	const me = await jsonFetch("/me", { method: "GET", headers: { Authorization: `Bearer ${token}` } });
	if (me.status !== 200) throw new Error(`/me failed: ${me.status} ${JSON.stringify(me.body)}`);
	const userId = me.body.user.id as string;

	return { token, userId, vaultId };
}

// ---------------------------------------------------------------------------
// Replica: the real SyncEngine booted headless, wired in main.ts production
// order (transcribed from the sim tier's replica.ts boot, minus the sim
// scheduler/clock/socket — real global WebSocket + real fetch + real time).
// Every `main.ts:NNNN` citation names the line transcribed.
// ---------------------------------------------------------------------------
class Replica {
	readonly id: string;
	readonly vaultDir: string;
	// biome-ignore lint/suspicious/noExplicitAny: cross-repo dynamic types.
	private readonly app: any;
	// biome-ignore lint/suspicious/noExplicitAny: cross-repo dynamic types.
	private readonly channel: any;
	private readonly signal: CatchupSignal;

	private constructor(args: {
		id: string;
		vaultDir: string;
		// biome-ignore lint/suspicious/noExplicitAny: cross-repo dynamic types.
		app: any;
		// biome-ignore lint/suspicious/noExplicitAny: cross-repo dynamic types.
		channel: any;
		signal: CatchupSignal;
	}) {
		this.id = args.id;
		this.vaultDir = args.vaultDir;
		this.app = args.app;
		this.channel = args.channel;
		this.signal = args.signal;
	}

	get catchupCount(): number {
		return this.signal.catchupCount;
	}

	waitCatchup(sinceCount: number, deadlineMs: number): Promise<void> {
		return this.signal.waitCatchup(sinceCount, deadlineMs, this.id);
	}

	static async boot(session: Session, id: string, rootDir: string): Promise<Replica> {
		const { EngramApi } = await imp("src/api");
		const { NoteChannel } = await imp("src/channel");
		const { makeCrdtOpSend } = await imp("src/crdt-op-dispatch");
		const { CrdtOpQueue } = await imp("src/crdt-op-queue");
		const { NoteIdMap } = await imp("src/crdt/note-id-map");
		const { createCrdtWiring } = await imp("src/crdt/wiring");
		const { SyncEngine } = await imp("src/sync");
		const { SyncLog } = await imp("src/sync-log");
		const { DEFAULT_SETTINGS } = await imp("src/types");
		const { TFile, TFolder } = await imp("tests/__mocks__/obsidian");
		const { makeVault } = await imp("tests/sim/vault-fs");

		const signal = new CatchupSignal();
		const vaultDir = path.join(rootDir, id);
		const noteIdMap = new NoteIdMap();

		// biome-ignore lint/suspicious/noExplicitAny: engine is dynamically typed here.
		let engine: any;
		// biome-ignore lint/suspicious/noExplicitAny: dynamically typed vault app.
		let app: any;

		// Vault events -> engine handlers, exactly as main.ts registerEvent wires
		// them (main.ts:575-578 / 852-857 / 609-614 / 618-619).
		const events = {
			onModify: (p: string) => {
				const f = app.vault.getAbstractFileByPath(p);
				if (f instanceof TFile) engine.handleModify(f);
			},
			onCreate: (p: string) => {
				const f = app.vault.getAbstractFileByPath(p);
				if (f instanceof TFolder) void engine.handleFolderCreate(f);
				else if (f instanceof TFile) engine.handleModify(f);
			},
			onDelete: (p: string) => {
				const f = app.vault.getAbstractFileByPath(p);
				if (f instanceof TFolder) void engine.handleFolderDelete(f);
				else if (f instanceof TFile) void engine.handleDelete(f);
			},
			onRename: (oldP: string, newP: string) => {
				const f = app.vault.getAbstractFileByPath(newP);
				if (f) void engine.handleRename(f, oldP);
			},
		};
		app = makeVault(vaultDir, events);

		const settings = {
			...DEFAULT_SETTINGS,
			apiUrl: API_URL,
			apiKey: session.token,
			vaultId: session.vaultId,
			enableCrdt: true,
			userEmail: "headless@e2e.local",
			debounceMs: 10,
			clientId: `client-${id}`,
		};

		// --- EngramApi (main.ts:359-365) ---
		const api = new EngramApi(settings.apiUrl, settings.apiKey);
		api.setVaultId(settings.vaultId);
		api.setDeviceId(id);

		// --- SyncEngine construction (main.ts:387-400). saveData persists the
		// seq cursor; a `catchupSeq` write is the post-catch-up signal (sync.ts:3448).
		engine = new SyncEngine(app, api, settings, async (data: Record<string, unknown>) => {
			if (data && Object.hasOwn(data, "catchupSeq")) signal.notify();
		});

		// --- post-construction setters, in main.ts order ---
		let noteStream: ReturnType<typeof NoteChannel> | null = null; // main.ts:1804 forward-ref holder
		engine.syncLog = new SyncLog(); // main.ts:402-403
		engine.setCrdtLiveCheck(() => noteStream?.isCrdtConnected() ?? false); // main.ts:412
		engine.setNoteIdMap(noteIdMap); // main.ts:418
		engine.setDeviceId(id); // main.ts:423
		engine.setCrdtEditorDetach(() => {}); // main.ts:429 (no editor headless)
		engine.setCrdtEditorRebind(() => {}); // main.ts:434

		// --- durable outbound CRDT op queue (main.ts:480-530) ---
		const crdtOpQueue = new CrdtOpQueue({
			send: makeCrdtOpSend({
				channel: () => noteStream,
				onCreated: (localId: string, serverId: string, p: string) =>
					engine.applyCrdtCreateAck(localId, serverId, p),
				onTerminal: () => {},
			}),
			now: () => Date.now(),
		});
		engine.setCrdtEnqueue((op: { kind: string; docId: string; path: string }) => {
			crdtOpQueue.enqueue({
				id: randomUUID(),
				kind: op.kind,
				docId: op.docId,
				payload: { path: op.path },
				enqueuedAt: Date.now(),
				attempts: 0,
			});
			window.setTimeout(() => void crdtOpQueue.tick(), 0);
		});

		// --- connectChannel (main.ts:1666-2013), real userId/vaultId. ---
		const channel = new NoteChannel(
			settings.apiUrl,
			settings.apiKey,
			session.userId,
			settings.vaultId,
			settings.enableCrdt,
			id, // deviceId -> WS device_id param
		);
		noteStream = channel;

		channel.onEvent = (event: unknown) => void engine.handleStreamEvent(event); // main.ts:1710-1712

		let crdtEverJoined = false;
		channel.onStatusChange = (connected: boolean) => {
			if (connected) engine.clearConfirmedNoteIds(); // main.ts:1734
			else if (!crdtEverJoined) engine.setCrdtManager(null); // main.ts:1757-1758
			if (!connected) manager.clearSynced(); // main.ts:1776
		};

		engine.setCrdtCreate((docId: string, p: string) => channel.crdtCreate(docId, p)); // main.ts:1815
		engine.setCrdtCreateBatch((creates: unknown) => channel.crdtCreateBatch(creates));
		engine.setCrdtDelete((docId: string) => channel.crdtDeleteAcked(docId));
		engine.setCrdtCatchupSince((cursorSeq: number, limit: number) =>
			channel.crdtCatchupSince(cursorSeq, limit),
		);

		// CRDT data-plane wiring (main.ts:1875-2003).
		const wiring = createCrdtWiring({
			noteIdMap,
			syncEngine: engine,
			sendCrdt: (docId: string, frame: unknown) => channel.sendCrdt(docId, frame),
			isBound: () => false, // no live editor headless
			canSendLive: (noteId: string) => engine.hasServerNote(noteId), // main.ts:1890
			dbPrefix: id, // per-replica IDB store (see preload.ts header)
		});
		const manager = wiring.manager;
		engine.setCrdtEnrollment(wiring.enrollment); // main.ts:1900
		channel.onCrdtMessage = wiring.onCrdtMessage; // main.ts:1937
		channel.onCrdtDocReady = wiring.onCrdtDocReady; // main.ts:1938
		channel.onCrdtNoteNotFound = wiring.onCrdtNoteNotFound; // main.ts:1939
		channel.onNoteYjsUpdate = wiring.onNoteYjsUpdate; // main.ts:1940

		// Deferred activation on the crdt: join ack (main.ts:1945-1968) — the
		// deaf-note-race fix. onCrdtTopicJoined runs the reconnect convergence.
		channel.onCrdtJoined = () => {
			crdtEverJoined = true;
			engine.setCrdtManager(manager);
			void (async () => {
				await crdtOpQueue.onJoined();
				await onCrdtTopicJoined();
			})();
		};
		channel.onCrdtJoinError = () => {
			crdtEverJoined = false;
			engine.setCrdtManager(null);
			manager.clearSynced();
			wiring.enrollment.resetAll();
		};

		async function onCrdtTopicJoined(): Promise<void> {
			try {
				await engine.reconcileNoteIdMapFromManifest();
			} catch {
				/* self-heals via strand-heal */
			}
			wiring.enrollment.resetAll();
			wiring.clearStrandHealAttempts();
			try {
				await engine.catchupViaSeqReplay();
			} catch {
				/* resumes from persisted cursor next join */
			}
		}

		engine.setReady(); // main.ts (gate opens)
		void channel.connect(); // main.ts:2013

		return new Replica({ id, vaultDir, app, channel, signal });
	}

	// --- ops ---
	async createNote(p: string, content: string): Promise<void> {
		await this.app.vault.create(p, content);
	}
	async editNote(p: string, content: string): Promise<void> {
		const file = this.app.vault.getFileByPath(p);
		if (!file) throw new Error(`editNote: no file at ${p}`);
		await this.app.vault.modify(file, content);
	}
	async goOffline(): Promise<void> {
		this.channel.disconnect();
	}
	async goOnline(): Promise<void> {
		await this.channel.connect();
	}
	disconnect(): void {
		this.channel.disconnect();
	}
}

// ---------------------------------------------------------------------------
// Scenarios. GREEN gate = must pass (exit 1 on failure). All prove real
// protocol behavior against current main: A's write persists server-side, and a
// receiver converges via clean catch-up (late-join + reconnect). Each < 30s.
// ---------------------------------------------------------------------------
async function main(): Promise<void> {
	const obs = await import("obsidian");
	(obs as unknown as { setRequestUrlHandler: (fn: typeof realRequestUrl) => void }).setRequestUrlHandler(
		realRequestUrl,
	);

	const session = await setupSession();
	const rootDir = fs.mkdtempSync(path.join(os.tmpdir(), "headless-tier-"));
	console.log(`[headless] api=${API_URL} vault=${session.vaultId} root=${rootDir}`);

	const results: { name: string; ok: boolean; ms: number; err?: string; gate: boolean }[] = [];
	async function scenario(name: string, gate: boolean, run: () => Promise<void>): Promise<void> {
		const t0 = Date.now();
		try {
			await run();
			results.push({ name, ok: true, ms: Date.now() - t0, gate });
			console.log(`[headless] PASS  ${name}  (${Date.now() - t0}ms)`);
		} catch (e) {
			results.push({ name, ok: false, ms: Date.now() - t0, err: (e as Error).message, gate });
			console.error(`[headless] ${gate ? "FAIL" : "known-red"}  ${name}  (${Date.now() - t0}ms)`);
			console.error(`        ${(e as Error).message}`);
		}
	}
	const serverHas = (p: string, hash: string) =>
		barrier.serverHasContent(API_URL, session.token, session.vaultId, p, hash);

	// GREEN 1 — handshake: two devices join the crdt room + complete catch-up.
	const a = await Replica.boot(session, "A", rootDir);
	const b = await Replica.boot(session, "B", rootDir);
	await scenario("handshake: A+B join + complete catch-up", true, async () => {
		await Promise.all([barrier.synced(a), barrier.synced(b)]);
	});

	// GREEN 2 — A's create persists server-side over the real CRDT protocol.
	const persistPath = "Headless/Persist.md";
	const persistBody = `# Persist\n\nA -> server ${Date.now()}`;
	await scenario("create -> server persists content (A -> server)", true, async () => {
		await a.createNote(persistPath, persistBody);
		await serverHas(persistPath, barrier.sha256(persistBody));
	});

	// GREEN 3 — late-joiner catch-up: a FRESH replica that joins after the note
	// exists converges via its initial catch-up (server -> new replica).
	const latePath = "Headless/Late.md";
	const lateBody = `# Late\n\nlate-join content ${Date.now()}`;
	await scenario("late-joiner catch-up delivery (server -> fresh replica)", true, async () => {
		await a.createNote(latePath, lateBody);
		await serverHas(latePath, barrier.sha256(lateBody)); // durable before the joiner catches up
		const c = await Replica.boot(session, "C", rootDir);
		await barrier.synced(c);
		await barrier.noteVisible(c, latePath, barrier.sha256(lateBody));
		c.disconnect();
	});

	// GREEN 4 — reconnect catch-up: B offline, A creates, B reconnects + converges.
	const reconPath = "Headless/Reconnect.md";
	const reconBody = `# Reconnect\n\ncreated while B offline ${Date.now()}`;
	await scenario("reconnect catch-up (B offline, A creates, B reconnects)", true, async () => {
		const before = b.catchupCount;
		await b.goOffline();
		await a.createNote(reconPath, reconBody);
		await serverHas(reconPath, barrier.sha256(reconBody)); // durable before B catches up
		const synced = barrier.synced(b, before); // arm BEFORE reconnect
		await b.goOnline();
		await synced;
		await barrier.noteVisible(b, reconPath, barrier.sha256(reconBody));
	});

	// KNOWN-RED payload — LIVE delivery to an already-present idle receiver.
	// Reproduces plugin #282 (fence v<=v collision masks heal, see file header).
	// Gated OFF the exit code: RED on main by design until #282 lands.
	if (process.env.HEADLESS_REPRO_282) {
		const livePath = "Headless/Live282.md";
		const liveBody = `# Live\n\nlive delivery ${Date.now()}`;
		await scenario("live create -> deliver to idle B [#282 repro, known-red]", false, async () => {
			await a.createNote(livePath, liveBody);
			await barrier.noteVisible(b, livePath, barrier.sha256(liveBody));
		});
	}

	a.disconnect();
	b.disconnect();
	fs.rmSync(rootDir, { recursive: true, force: true });

	const gateFails = results.filter((r) => r.gate && !r.ok);
	const knownRed = results.filter((r) => !r.gate && !r.ok);
	if (knownRed.length > 0) {
		console.log(`[headless] ${knownRed.length} known-red repro(s) failed as expected (not fatal)`);
	}
	if (gateFails.length > 0) {
		console.error(`[headless] ${gateFails.length} GREEN gate scenario(s) FAILED`);
		process.exit(1);
	}
	console.log(`[headless] all ${results.filter((r) => r.gate).length} GREEN gate scenarios PASSED`);
	process.exit(0);
}

main().catch((e) => {
	console.error("[headless] fatal:", e);
	process.exit(1);
});
