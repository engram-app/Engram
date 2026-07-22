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
// or setup failed. Every scenario here is a GREEN gate — this tier is the
// deterministic replacement for the demoted plugin<->backend contract e2e.
//
// GATE COVERAGE: catch-up delivery (server -> replica, late-join + reconnect) +
// server persistence + LIVE real-time A->B fan-out (both replicas enrolled, no
// reconnect) + the #285 stale-head-after-room-recreate regression.
//
// Two protocol/server payloads the client-only sim tier cannot see, now BOTH
// gated green because their fixes landed on main:
//
//   - live A->B fan-out — was RED pre-plugin-#282 (an equal-seq fence collision
//     masked the heal so the note stuck empty). Fixed by the content-hash-aware
//     equal-seq fence (plugin #296 / #282). Now gated: `live A->B fan-out`.
//
//   - stale head after room recreate — was RED pre-backend-#1073 (a room
//     recreated by a post-terminate edit could serve a stale head to a
//     reconnecting replica). Fixed by #1073. Gated deterministically via the
//     backend_rpc `terminate_room` seam: `stale head after room recreate (#285)`.
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
// Engram release container for backend_rpc (mirrors e2e/helpers/backend_rpc.py) —
// used to stage a server-side state a client API can't reach (terminate_room).
const CI_ENGRAM_CONTAINER = process.env.CI_ENGRAM_CONTAINER ?? "engram-crdt-engram-1";

/** Evaluate an Elixir expr on the running backend node via the release's rpc,
 *  same docker-exec seam as e2e/helpers/backend_rpc.py. Throws on non-zero exit
 *  so a mis-staged scenario fails loudly at the stage step, not later. */
function backendRpc(expr: string): string {
	return execFileSync(
		"docker",
		["exec", "-i", CI_ENGRAM_CONTAINER, "/app/bin/engram", "rpc", expr],
		{ timeout: 20_000, encoding: "utf8" },
	).trim();
}

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

/** Resolve a note's server id from its path (GET /notes/*path -> flat `{id}`). */
async function getNoteId(token: string, vaultId: string, notePath: string): Promise<string> {
	const url = `${API_URL}/notes/${encodeURIComponent(notePath)}`;
	const res = await fetch(url, { headers: { Authorization: `Bearer ${token}`, "X-Vault-ID": vaultId } });
	if (res.status !== 200) throw new Error(`getNoteId: GET ${notePath} -> ${res.status}`);
	const body = (await res.json()) as { id?: string };
	if (!body.id) throw new Error(`getNoteId: no id in response for ${notePath}`);
	return body.id;
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
// Scenarios. Every one is a GREEN gate = must pass (exit 1 on failure). They
// prove real protocol behavior against current main: A's write persists
// server-side, a receiver converges via clean catch-up (late-join + reconnect),
// live A->B fan-out delivers over the socket, and a recreated room serves a
// consistent head (#285). Each < 30s.
// ---------------------------------------------------------------------------
async function main(): Promise<void> {
	const obs = await import("obsidian");
	(obs as unknown as { setRequestUrlHandler: (fn: typeof realRequestUrl) => void }).setRequestUrlHandler(
		realRequestUrl,
	);

	const session = await setupSession();
	const rootDir = fs.mkdtempSync(path.join(os.tmpdir(), "headless-tier-"));
	console.log(`[headless] api=${API_URL} vault=${session.vaultId} root=${rootDir}`);

	const results: { name: string; ok: boolean; ms: number; err?: string }[] = [];
	async function scenario(name: string, run: () => Promise<void>): Promise<void> {
		const t0 = Date.now();
		try {
			await run();
			results.push({ name, ok: true, ms: Date.now() - t0 });
			console.log(`[headless] PASS  ${name}  (${Date.now() - t0}ms)`);
		} catch (e) {
			results.push({ name, ok: false, ms: Date.now() - t0, err: (e as Error).message });
			console.error(`[headless] FAIL  ${name}  (${Date.now() - t0}ms)`);
			console.error(`        ${(e as Error).message}`);
		}
	}
	const serverHas = (p: string, hash: string) =>
		barrier.serverHasContent(API_URL, session.token, session.vaultId, p, hash);

	// GREEN 1 — handshake: two devices join the crdt room + complete catch-up.
	const a = await Replica.boot(session, "A", rootDir);
	const b = await Replica.boot(session, "B", rootDir);
	await scenario("handshake: A+B join + complete catch-up", async () => {
		await Promise.all([barrier.synced(a), barrier.synced(b)]);
	});

	// GREEN 2 — A's create persists server-side over the real CRDT protocol.
	const persistPath = "Headless/Persist.md";
	const persistBody = `# Persist\n\nA -> server ${Date.now()}`;
	await scenario("create -> server persists content (A -> server)", async () => {
		await a.createNote(persistPath, persistBody);
		await serverHas(persistPath, barrier.sha256(persistBody));
	});

	// GREEN 3 — late-joiner catch-up: a FRESH replica that joins after the note
	// exists converges via its initial catch-up (server -> new replica).
	const latePath = "Headless/Late.md";
	const lateBody = `# Late\n\nlate-join content ${Date.now()}`;
	await scenario("late-joiner catch-up delivery (server -> fresh replica)", async () => {
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
	await scenario("reconnect catch-up (B offline, A creates, B reconnects)", async () => {
		const before = b.catchupCount;
		await b.goOffline();
		await a.createNote(reconPath, reconBody);
		await serverHas(reconPath, barrier.sha256(reconBody)); // durable before B catches up
		const synced = barrier.synced(b, before); // arm BEFORE reconnect
		await b.goOnline();
		await synced;
		await barrier.noteVisible(b, reconPath, barrier.sha256(reconBody));
	});

	// GREEN 5 — LIVE A->B fan-out: both replicas enrolled/live (B never
	// reconnects here), A creates then live-edits, B converges via the live
	// socket push (note_yjs_update fan-out), NOT a catch-up. This is the path
	// that was RED pre-plugin-#282 (an equal-seq fence collision masked the heal
	// so the note stuck empty); the content-hash-aware fence (#296) converges it.
	const fanoutPath = "Headless/Fanout.md";
	const fanoutCreate = `# Fanout\n\ncreated live ${Date.now()}`;
	const fanoutEdit = `${fanoutCreate}\n\nlive edit fanned out.`;
	await scenario("live A->B fan-out (create + live edit, no reconnect)", async () => {
		await a.createNote(fanoutPath, fanoutCreate);
		await barrier.noteVisible(b, fanoutPath, barrier.sha256(fanoutCreate)); // create fans out live
		await a.editNote(fanoutPath, fanoutEdit);
		await barrier.noteVisible(b, fanoutPath, barrier.sha256(fanoutEdit)); // live delta fans out
	});

	// GREEN 6 — stale head after room recreate (#285). Kill the note's CRDT room
	// via the backend_rpc terminate_room seam; a subsequent edit recreates the
	// room with a NEW head; a replica that reconnects MUST read that new head,
	// not the stale pre-terminate one. RED pre-backend-#1073; deterministic here
	// (the terminate is a staged server state, not a timing dice-roll).
	const stalePath = "Headless/Stale285.md";
	const staleBase = `# Stale\n\nbase ${Date.now()}`;
	const staleEdit = `${staleBase}\n\nedit after room recreate.`;
	await scenario("stale head after room recreate (#285)", async () => {
		await a.createNote(stalePath, staleBase);
		await serverHas(stalePath, barrier.sha256(staleBase)); // durable head before terminate
		const noteId = await getNoteId(session.token, session.vaultId, stalePath);
		backendRpc(`Engram.Notes.CrdtRegistry.terminate_room("${noteId}")`);
		// B offline -> it MUST converge via a reconnect catch-up that reads the
		// head the recreate leaves behind (the exact leg #285 broke).
		const before = b.catchupCount;
		await b.goOffline();
		await a.editNote(stalePath, staleEdit); // A's live edit recreates the terminated room
		await serverHas(stalePath, barrier.sha256(staleEdit)); // durable new head
		const synced = barrier.synced(b, before); // arm BEFORE reconnect
		await b.goOnline();
		await synced;
		await barrier.noteVisible(b, stalePath, barrier.sha256(staleEdit));
	});

	a.disconnect();
	b.disconnect();
	fs.rmSync(rootDir, { recursive: true, force: true });

	const fails = results.filter((r) => !r.ok);
	if (fails.length > 0) {
		console.error(`[headless] ${fails.length} gate scenario(s) FAILED`);
		process.exit(1);
	}
	console.log(`[headless] all ${results.length} gate scenarios PASSED`);
	process.exit(0);
}

main().catch((e) => {
	console.error("[headless] fatal:", e);
	process.exit(1);
});
