/**
 * Owns the durable CrdtOpQueue for one live connection and bridges it to the
 * callers (issue #1030). `enqueueCreate` / `enqueueDelete` return a promise that
 * settles on the op's FINAL outcome — resolve on server ack (the authoritative
 * id for create), reject on terminal drop (ttl / overflow / max-attempts /
 * terminal server reason). So the TanStack mutations keep their optimistic /
 * rollback shape: the promise just stays pending while offline (the op is HELD)
 * and completes on reconnect instead of rejecting.
 *
 * The queue + dispatch + persister are all deterministic/injected, so this
 * controller is unit-testable without a real socket or IndexedDB.
 */

import { CrdtOpError } from "../api/crdt-ops";
import { type CrdtOpChannel, type CrdtSendHooks, makeCrdtOpSend } from "./op-dispatch";
import { type CrdtOp, CrdtOpQueue, type CrdtOpQueueOptions, type DropReason } from "./op-queue";
import type { Persister } from "./op-queue-persist";

interface Deferred<T> {
	resolve: (v: T) => void;
	reject: (e: unknown) => void;
}

function opEvent(op: CrdtOp): string {
	return op.kind === "create" ? "crdt_create" : "crdt_delete";
}

/** How often (ms) to drive queued retries while joined. Matches the plugin. */
export const TICK_MS = 5000;

export interface CrdtOpQueueControllerDeps {
	/** The joined channel adapter, or null when no socket is up. */
	channel: () => CrdtOpChannel | null;
	/** Remap the cache id when a create ADOPTS a different live note (serverId
	 *  differs from the minted localId). */
	remapId: (localId: string, serverId: string) => void;
	/** An op dropped without delivery — surface it (log + reconcile cache). */
	onDropSurfaced: (op: CrdtOp, reason: DropReason | "terminal") => void;
	/** A transient plan-limit block — surface once (upgrade toast). */
	onLimitSurfaced: (op: CrdtOp, reason: string) => void;
	persister: Persister;
	mintId: () => string;
	now?: () => number;
	tickMs?: number;
	queueOptions?: Partial<CrdtOpQueueOptions>;
}

export class CrdtOpQueueController {
	private readonly queue: CrdtOpQueue;
	private readonly deferreds = new Map<string, Deferred<unknown>>();
	private readonly persister: Persister;
	private readonly mintId: () => string;
	private readonly now: () => number;
	private readonly tickMs: number;
	private tickTimer: ReturnType<typeof setInterval> | null = null;

	constructor(deps: CrdtOpQueueControllerDeps) {
		this.persister = deps.persister;
		this.mintId = deps.mintId;
		this.now = deps.now ?? (() => Date.now());
		this.tickMs = deps.tickMs ?? TICK_MS;

		const hooks: CrdtSendHooks = {
			channel: deps.channel,
			onCreated: (localId, serverId) => {
				if (serverId !== localId) {
					deps.remapId(localId, serverId);
				}
				this.settleResolve(localId, serverId);
			},
			onDeleted: (docId) => this.settleResolve(docId, { doc_id: docId }),
			onTerminal: (op, reason) => {
				this.settleReject(op.docId, new CrdtOpError(reason, opEvent(op)));
				deps.onDropSurfaced(op, "terminal");
			},
			onLimit: (op, reason) => deps.onLimitSurfaced(op, reason),
		};

		this.queue = new CrdtOpQueue({
			send: makeCrdtOpSend(hooks),
			now: this.now,
			options: deps.queueOptions,
			onDrop: (op, reason) => {
				this.settleReject(op.docId, new CrdtOpError(reason, opEvent(op)));
				deps.onDropSurfaced(op, reason);
			},
		});
	}

	/** Load persisted ops, wire persistence, and start the retry ticker. */
	async start(): Promise<void> {
		this.queue.load(await this.persister.load());
		this.queue.setPersist((ops) => this.persister.save(ops));
		this.tickTimer = setInterval(() => this.kickTick(), this.tickMs);
	}

	/** Drive a flush, swallowing errors — retries resume on the next tick. */
	private kickTick(): void {
		this.queue.tick().catch(() => {
			// a flush error is transient; the next tick re-drives due ops
		});
	}

	/** CRDT topic (re)joined → flush held ops. */
	joined(): Promise<void> {
		return this.queue.onJoined();
	}

	/** CRDT topic dropped → hold sends until the next join. */
	left(): void {
		this.queue.onLeft();
	}

	/** Number of pending ops (for diagnostics / tests). */
	size(): number {
		return this.queue.size();
	}

	/**
	 * Stop the ticker and reject any still-pending caller promises — the
	 * connection is going away (teardown / vault switch); a held op belongs to the
	 * OLD context and its persisted copy will reload under the new controller.
	 */
	stop(): void {
		if (this.tickTimer !== null) {
			clearInterval(this.tickTimer);
			this.tickTimer = null;
		}
		this.queue.dispose();
		for (const [docId, d] of this.deferreds) {
			d.reject(new CrdtOpError("disconnected", `crdt_op:${docId}`));
		}
		this.deferreds.clear();
	}

	/** Enqueue a genesis create; resolves with the authoritative server id. */
	enqueueCreate(docId: string, path: string): Promise<string> {
		return this.enqueue<string>({ kind: "create", docId, payload: { path } });
	}

	/** Enqueue a delete; resolves once the server acks. */
	enqueueDelete(docId: string): Promise<{ doc_id: string }> {
		return this.enqueue<{ doc_id: string }>({ kind: "delete", docId, payload: {} });
	}

	private enqueue<T>(spec: Pick<CrdtOp, "kind" | "docId" | "payload">): Promise<T> {
		// A newer op for the same doc supersedes the queued one — settle the prior
		// caller so its promise doesn't hang (the note's fate is now the new op's).
		const prior = this.deferreds.get(spec.docId);
		if (prior) {
			this.deferreds.delete(spec.docId);
			prior.reject(new CrdtOpError("superseded", `crdt_op:${spec.docId}`));
		}
		const op: CrdtOp = {
			id: this.mintId(),
			kind: spec.kind,
			docId: spec.docId,
			payload: spec.payload,
			enqueuedAt: this.now(),
			attempts: 0,
		};
		return new Promise<T>((resolve, reject) => {
			this.deferreds.set(spec.docId, { resolve: resolve as (v: unknown) => void, reject });
			this.queue.enqueue(op);
			// Kick an immediate flush so an op issued while joined sends now rather
			// than waiting up to tickMs; a no-op when the topic isn't joined (held).
			this.kickTick();
		});
	}

	private settleResolve(docId: string, value: unknown): void {
		const d = this.deferreds.get(docId);
		if (d) {
			this.deferreds.delete(docId);
			d.resolve(value);
		}
	}

	private settleReject(docId: string, err: unknown): void {
		const d = this.deferreds.get(docId);
		if (d) {
			this.deferreds.delete(docId);
			d.reject(err);
		}
	}
}
