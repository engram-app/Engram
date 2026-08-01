/**
 * CRDT outbound op queue: a durable, bounded, hold-and-retry buffer for the web
 * SPA's terminal CRDT socket ops (create / delete). A faithful mirror of the
 * plugin's `crdt-op-queue.ts` (Engram-obsidian #251) — hold the constants and
 * semantics identical so the two interfaces give the same reliability guarantee
 * (issue #1030).
 *
 * Ops enqueued while the CRDT topic is not joined are HELD; nothing is sent
 * until `onJoined()` fires. Sends are retried with exponential backoff on
 * failure, coalesced per docId (one pending op per docId, newest supersedes),
 * bounded in count, and dropped once they age past a TTL.
 *
 * Pure logic: every side-effecting dep (send, clock, drop/ack notify) is
 * injected and retries are driven off the injected clock via `tick()`, so the
 * whole thing is deterministic under test — no real timers, no real socket.
 *
 * Live-edit `crdt_msg` updates are deliberately NOT queued here (they self-heal
 * via the Yjs sync protocol on reconnect) — matching the plugin. Only genesis
 * create + delete ride this queue.
 */

/** One outbound CRDT op. `attempts` counts failed send attempts so far. */
export interface CrdtOp {
	id: string;
	kind: "create" | "delete";
	docId: string;
	payload: unknown;
	enqueuedAt: number;
	attempts: number;
}

/** Why an op was dropped without being acked. */
export type DropReason = "ttl" | "overflow" | "max-attempts";

/** Result of an outbound send attempt. */
export type SendResult = "ok" | "error" | "timeout";

/** Max distinct pending docId ops. Bounds memory across long offline spells;
 *  overflow drops the oldest pending op rather than growing unbounded. */
export const MAX_QUEUE = 500;

/** Ops older than this (by `enqueuedAt`) are stale and dropped, never sent. A
 *  CRDT op held 5 min past creation is better dropped than delivered late — the
 *  peer reconverges via full sync, so a late op only causes churn. */
export const OP_TTL_MS = 5 * 60 * 1000;

/** Give up (drop + notify) after this many failed send attempts. */
export const MAX_ATTEMPTS = 8;

/** First retry delay; each subsequent retry doubles it up to MAX_BACKOFF_MS. */
export const BASE_BACKOFF_MS = 500;

/** Ceiling on retry backoff so a persistently-failing op still gets retried
 *  roughly twice a minute rather than backing off into hours. */
export const MAX_BACKOFF_MS = 30_000;

/** Default persist debounce, coalescing rapid mutations into one write. */
export const PERSIST_DELAY_MS = 1000;

export interface CrdtOpQueueOptions {
	maxQueue: number;
	opTtlMs: number;
	maxAttempts: number;
	baseBackoffMs: number;
	maxBackoffMs: number;
}

export interface CrdtOpQueueDeps {
	send: (op: CrdtOp) => Promise<SendResult>;
	now: () => number;
	/** An op removed from the queue on a server `ok` (delivered). */
	onAck?: (op: CrdtOp) => void;
	/** An op dropped without delivery (ttl / overflow / max-attempts). */
	onDrop?: (op: CrdtOp, reason: DropReason) => void;
	options?: Partial<CrdtOpQueueOptions>;
	persistDelayMs?: number;
}

export const DEFAULT_OPTIONS: CrdtOpQueueOptions = {
	maxQueue: MAX_QUEUE,
	opTtlMs: OP_TTL_MS,
	maxAttempts: MAX_ATTEMPTS,
	baseBackoffMs: BASE_BACKOFF_MS,
	maxBackoffMs: MAX_BACKOFF_MS,
};

/** Internal record: the op plus the clock time at which it may next be sent. */
export interface Entry {
	op: CrdtOp;
	nextAttemptAt: number;
}

export class CrdtOpQueue {
	/** Keyed by docId → at most one pending op per doc (newest supersedes). */
	private readonly entries: Map<string, Entry> = new Map();
	private joined = false;
	/** Re-entrancy guard so overlapping flush/tick calls don't double-send. */
	private flushing = false;

	private readonly send: (op: CrdtOp) => Promise<SendResult>;
	private readonly now: () => number;
	private readonly onAck?: (op: CrdtOp) => void;
	private readonly onDrop?: (op: CrdtOp, reason: DropReason) => void;
	private readonly opts: CrdtOpQueueOptions;

	private persistFn: ((ops: CrdtOp[]) => Promise<void> | void) | null = null;
	private persistTimer: ReturnType<typeof setTimeout> | null = null;
	private readonly persistDelayMs: number;

	constructor(deps: CrdtOpQueueDeps) {
		this.send = deps.send;
		this.now = deps.now;
		this.onAck = deps.onAck;
		this.onDrop = deps.onDrop;
		this.opts = { ...DEFAULT_OPTIONS, ...deps.options };
		this.persistDelayMs = deps.persistDelayMs ?? PERSIST_DELAY_MS;
	}

	/** Number of distinct pending ops (docIds). */
	size(): number {
		return this.entries.size;
	}

	/** Flat snapshot of pending ops, for the persist blob. */
	all(): CrdtOp[] {
		return this.pending();
	}

	/** Register a callback to persist the flat pending op list. */
	setPersist(fn: (ops: CrdtOp[]) => Promise<void> | void): void {
		this.persistFn = fn;
	}

	/**
	 * Restore persisted ops on startup. Prunes any op already past `opTtlMs`
	 * (fires onDrop "ttl") so a long downtime never resurrects stale ops, and
	 * never restores more than `maxQueue` (oldest-first, dropping the excess).
	 * `attempts`/`nextAttemptAt` are transient scheduling state and are reset: a
	 * reloaded op gets a fresh retry budget and is due immediately.
	 */
	load(ops: CrdtOp[]): void {
		this.entries.clear();
		const now = this.now();
		for (const op of ops) {
			if (now - op.enqueuedAt > this.opts.opTtlMs) {
				this.onDrop?.(op, "ttl");
				continue;
			}
			if (this.entries.size >= this.opts.maxQueue) {
				this.evictOldest();
			}
			this.entries.set(op.docId, { op: { ...op, attempts: 0 }, nextAttemptAt: 0 });
		}
	}

	/** Cancel any pending persist timer. Call on teardown / vault switch. */
	dispose(): void {
		if (this.persistTimer !== null) {
			clearTimeout(this.persistTimer);
			this.persistTimer = null;
		}
	}

	/**
	 * Add an op. Coalesced by docId: a newer op replaces any pending op for the
	 * same doc (delete supersedes create, latest wins). A brand-new docId beyond
	 * `maxQueue` evicts the oldest pending op (onDrop "overflow"). Does not send
	 * until the channel is joined.
	 */
	enqueue(op: CrdtOp): void {
		const existing = this.entries.get(op.docId);
		if (existing) {
			// Supersede in place; Map keeps the original FIFO slot for this docId.
			this.entries.set(op.docId, { op, nextAttemptAt: 0 });
			this.schedulePersist();
			return;
		}
		if (this.entries.size >= this.opts.maxQueue) {
			this.evictOldest();
		}
		this.entries.set(op.docId, { op, nextAttemptAt: 0 });
		this.schedulePersist();
	}

	/** Channel joined: flush all held ops FIFO, retrying failures via backoff. */
	async onJoined(): Promise<void> {
		this.joined = true;
		await this.flush();
	}

	/** Channel dropped: hold further sends until the next join. */
	onLeft(): void {
		this.joined = false;
	}

	/**
	 * Drive retries: send every op that is due (nextAttemptAt <= now) and not
	 * TTL-expired. Call after advancing the clock. No-op until joined.
	 */
	async tick(): Promise<void> {
		await this.flush();
	}

	private evictOldest(): void {
		const first = this.entries.keys().next();
		if (first.done) {
			return;
		}
		const entry = this.entries.get(first.value);
		this.entries.delete(first.value);
		if (entry) {
			this.onDrop?.(entry.op, "overflow");
		}
		this.schedulePersist();
	}

	/** Drop and notify if the op has aged past its TTL. Returns true if dropped. */
	private dropIfExpired(docId: string, entry: Entry): boolean {
		if (this.now() - entry.op.enqueuedAt <= this.opts.opTtlMs) {
			return false;
		}
		this.entries.delete(docId);
		this.onDrop?.(entry.op, "ttl");
		this.schedulePersist();
		return true;
	}

	/** Flat snapshot of pending ops, for persistence. */
	private pending(): CrdtOp[] {
		return [...this.entries.values()].map((e) => e.op);
	}

	/** Debounced persist: coalesces rapid mutations into one write. */
	private schedulePersist(): void {
		if (!this.persistFn || this.persistTimer !== null) {
			return;
		}
		this.persistTimer = setTimeout(() => {
			this.persistTimer = null;
			// Fire the (possibly async) persister; swallow its rejection — a failed
			// write just means the queue isn't durable across a reload this once.
			const written = this.persistFn?.(this.pending());
			if (written instanceof Promise) {
				written.catch(() => {
					// best-effort persistence; a failed write just skips durability once
				});
			}
		}, this.persistDelayMs);
	}

	private backoffFor(attempts: number): number {
		// attempts = number of failures so far (>=1): base, base*2, base*4, ...
		const delay = this.opts.baseBackoffMs * 2 ** (attempts - 1);
		return Math.min(delay, this.opts.maxBackoffMs);
	}

	private async flush(): Promise<void> {
		if (!this.joined || this.flushing) {
			return;
		}
		this.flushing = true;
		try {
			// Snapshot keys so eviction/supersede during iteration is safe.
			for (const docId of [...this.entries.keys()]) {
				const entry = this.entries.get(docId);
				if (!entry) {
					continue;
				}
				if (this.dropIfExpired(docId, entry)) {
					continue;
				}
				if (entry.nextAttemptAt > this.now()) {
					continue;
				}
				await this.attempt(docId, entry);
			}
		} finally {
			this.flushing = false;
		}
	}

	private async attempt(docId: string, entry: Entry): Promise<void> {
		const result = await this.send(entry.op);
		// The op may have been superseded/evicted while send was in flight; only
		// act on it if this exact entry is still the pending one.
		if (this.entries.get(docId) !== entry) {
			return;
		}

		if (result === "ok") {
			this.entries.delete(docId);
			this.onAck?.(entry.op);
			this.schedulePersist();
			return;
		}
		entry.op.attempts += 1;
		if (entry.op.attempts >= this.opts.maxAttempts) {
			this.entries.delete(docId);
			this.onDrop?.(entry.op, "max-attempts");
			this.schedulePersist();
			return;
		}
		entry.nextAttemptAt = this.now() + this.backoffFor(entry.op.attempts);
	}
}
