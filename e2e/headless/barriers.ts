// e2e/headless/barriers.ts
//
// Event barriers for the headless protocol tier. This tier runs the REAL
// plugin SyncEngine against the REAL backend over REAL WebSockets in REAL
// time — so the ONLY honest way to wait is on an actual signal, never a
// wall-clock sleep-then-assert:
//
//   - synced(replica)      resolves on the engine's post-join/catch-up-complete
//                          signal. The real signal is the seq-cursor persist:
//                          `catchupViaSeqReplay` calls the engine's `saveData`
//                          hook with a `catchupSeq` key at the end of every
//                          replay pass (sync.ts:3446-3448). boot() feeds that
//                          hook into a CatchupSignal — no new plumbing, no timer.
//
//   - noteVisible(r, path, hash)  assert-polls the replica's real vault file at
//                          <=100ms until its sha256 matches, with a 120s deadline
//                          that is a TRUE-BREAKAGE bound (E2E_DELIVERY_TIMEOUT),
//                          not a padded sleep: convergence normally lands in well
//                          under a second; the deadline only fires when delivery
//                          is genuinely broken.

import { createHash } from "node:crypto";
import * as fs from "node:fs";
import * as path from "node:path";

/** True-breakage delivery bound (seconds -> ms). Reuses E2E_DELIVERY_TIMEOUT
 *  semantics: this is the "delivery is broken" ceiling, not an expected wait. */
export const DELIVERY_TIMEOUT_MS = Number(process.env.E2E_DELIVERY_TIMEOUT ?? 120) * 1000;

export function sha256(s: string): string {
	return createHash("sha256").update(s, "utf8").digest("hex");
}

/**
 * The catch-up-complete signal. boot() hands `notify()` to the SyncEngine's
 * `saveData` hook (fired with `{ catchupSeq }` at the end of every seq-replay
 * pass), and the Replica delegates `catchupCount` / `waitCatchup` here.
 *
 * `count` is monotonic; a waiter arms against a threshold and resolves once the
 * count moves past it. `synced(replica)` (threshold 0) resolves on the FIRST
 * catch-up — including one that already fired before the wait began (no arm-race
 * on the initial join). For a reconnect, capture `catchupCount` BEFORE going
 * online and pass it as the threshold, so the wait resolves only on the NEW
 * post-reconnect catch-up.
 */
export class CatchupSignal {
	private count = 0;
	private waiters: Array<{ threshold: number; resolve: () => void; reject: (e: Error) => void; timer: ReturnType<typeof setTimeout> }> = [];

	get catchupCount(): number {
		return this.count;
	}

	notify(): void {
		this.count += 1;
		const still: typeof this.waiters = [];
		for (const w of this.waiters) {
			if (this.count > w.threshold) {
				clearTimeout(w.timer);
				w.resolve();
			} else {
				still.push(w);
			}
		}
		this.waiters = still;
	}

	waitCatchup(sinceCount: number, deadlineMs: number, label: string): Promise<void> {
		if (this.count > sinceCount) return Promise.resolve();
		return new Promise<void>((resolve, reject) => {
			const timer = setTimeout(() => {
				this.waiters = this.waiters.filter((w) => w.timer !== timer);
				reject(
					new Error(
						`synced() timeout: ${label} did not complete a catch-up > ${sinceCount} within ${deadlineMs}ms (count=${this.count})`,
					),
				);
			}, deadlineMs);
			this.waiters.push({ threshold: sinceCount, resolve, reject, timer });
		});
	}
}

/** Minimal surface the barriers need — a real Replica satisfies this. */
export interface ReplicaLike {
	readonly id: string;
	readonly vaultDir: string;
	readonly catchupCount: number;
	waitCatchup(sinceCount: number, deadlineMs: number): Promise<void>;
}

/** Resolve once `replica` has completed a catch-up strictly newer than
 *  `sinceCount` (default 0 = the first catch-up ever, i.e. initial join). */
export async function synced(replica: ReplicaLike, sinceCount = 0): Promise<void> {
	await replica.waitCatchup(sinceCount, DELIVERY_TIMEOUT_MS);
}

/** Resolve once `replica`'s vault file at `notePath` has content hashing to
 *  `contentHash`. Assert-polls the REAL file at <=100ms; throws on the 120s
 *  true-breakage deadline. */
export async function noteVisible(replica: ReplicaLike, notePath: string, contentHash: string): Promise<void> {
	const abs = path.join(replica.vaultDir, notePath);
	const deadline = Date.now() + DELIVERY_TIMEOUT_MS;
	let last: string | null = null;
	for (;;) {
		try {
			last = sha256(fs.readFileSync(abs, "utf8"));
		} catch {
			last = null; // not written yet
		}
		if (last === contentHash) return;
		if (Date.now() > deadline) {
			throw new Error(
				`noteVisible timeout: ${replica.id}:${notePath} expected ${contentHash.slice(0, 12)} ` +
					`got ${last ? last.slice(0, 12) : "<absent>"} after ${DELIVERY_TIMEOUT_MS}ms`,
			);
		}
		await new Promise((r) => setTimeout(r, 100));
	}
}

/** Resolve once the SERVER durably holds `notePath` with content hashing to
 *  `contentHash`. Assert-polls REST `GET /notes/{path}` at <=100ms; throws on
 *  the 120s deadline. This is the "A's write is durably persisted server-side"
 *  gate a receiver's catch-up depends on — a real condition poll, not a sleep.
 *  (Gating a reconnect on this, rather than a fixed wait, is what makes the
 *  catch-up scenarios deterministic rather than racing A's server persist.) */
export async function serverHasContent(
	apiUrl: string,
	token: string,
	vaultId: string,
	notePath: string,
	contentHash: string,
): Promise<void> {
	const url = `${apiUrl.replace(/\/+$/, "")}/notes/${encodeURIComponent(notePath)}`;
	const headers = { Authorization: `Bearer ${token}`, "X-Vault-ID": vaultId };
	const deadline = Date.now() + DELIVERY_TIMEOUT_MS;
	let last = "<none>";
	for (;;) {
		const res = await fetch(url, { headers });
		if (res.status === 200) {
			const body = (await res.json()) as { content?: string };
			const h = sha256(body.content ?? "");
			if (h === contentHash) return;
			last = `hash ${h.slice(0, 12)}`;
		} else {
			last = `status ${res.status}`;
		}
		if (Date.now() > deadline) {
			throw new Error(
				`serverHasContent timeout: ${notePath} expected ${contentHash.slice(0, 12)} got ${last} after ${DELIVERY_TIMEOUT_MS}ms`,
			);
		}
		await new Promise((r) => setTimeout(r, 100));
	}
}

export const barrier = { synced, noteVisible, serverHasContent, sha256 };
