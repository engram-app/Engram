import { beforeEach, describe, expect, it, vi } from "vitest";
import {
	BASE_BACKOFF_MS,
	type CrdtOp,
	CrdtOpQueue,
	MAX_ATTEMPTS,
	type SendResult,
} from "./op-queue";

// Deterministic clock: tests advance `clock` and call tick()/onJoined() to drive
// retries — no real timers.
let clock = 0;
const now = () => clock;

function op(docId: string, kind: CrdtOp["kind"] = "create", enqueuedAt = clock): CrdtOp {
	return {
		id: `op-${docId}`,
		kind,
		docId,
		payload: { path: `${docId}.md` },
		enqueuedAt,
		attempts: 0,
	};
}

beforeEach(() => {
	clock = 0;
});

describe("CrdtOpQueue — enqueue-until-joined", () => {
	it("holds ops until joined, then flushes them FIFO", async () => {
		const sent: string[] = [];
		const send = vi.fn(async (o: CrdtOp): Promise<SendResult> => {
			sent.push(o.docId);
			return "ok";
		});
		const q = new CrdtOpQueue({ send, now });

		q.enqueue(op("a"));
		q.enqueue(op("b"));
		expect(send).not.toHaveBeenCalled(); // held — not joined
		expect(q.size()).toBe(2);

		await q.onJoined();
		expect(sent).toEqual(["a", "b"]); // FIFO
		expect(q.size()).toBe(0); // acked → removed
	});

	it("does not send after onLeft until the next join", async () => {
		const send = vi.fn(async (): Promise<SendResult> => "ok");
		const q = new CrdtOpQueue({ send, now });
		await q.onJoined();
		q.onLeft();
		q.enqueue(op("a"));
		await q.tick();
		expect(send).not.toHaveBeenCalled();
		await q.onJoined();
		expect(send).toHaveBeenCalledTimes(1);
	});
});

describe("CrdtOpQueue — ack + retry", () => {
	it("removes an op only on ok and fires onAck", async () => {
		const acked: string[] = [];
		const send = vi.fn(async (): Promise<SendResult> => "ok");
		const q = new CrdtOpQueue({ send, now, onAck: (o) => acked.push(o.docId) });
		q.enqueue(op("a"));
		await q.onJoined();
		expect(acked).toEqual(["a"]);
		expect(q.size()).toBe(0);
	});

	it("retries a failed op with exponential backoff, keeping it queued", async () => {
		let result: SendResult = "error";
		const send = vi.fn(async (): Promise<SendResult> => result);
		const q = new CrdtOpQueue({ send, now });
		q.enqueue(op("a"));

		await q.onJoined(); // attempt 1 fails
		expect(send).toHaveBeenCalledTimes(1);
		expect(q.size()).toBe(1); // still queued

		// Not yet due — backoff is BASE_BACKOFF_MS after the first failure.
		clock += BASE_BACKOFF_MS - 1;
		await q.tick();
		expect(send).toHaveBeenCalledTimes(1); // not due

		clock += 1; // now due
		result = "ok";
		await q.tick();
		expect(send).toHaveBeenCalledTimes(2);
		expect(q.size()).toBe(0);
	});

	it("treats timeout like a retryable error", async () => {
		let result: SendResult = "timeout";
		const send = vi.fn(async (): Promise<SendResult> => result);
		const q = new CrdtOpQueue({ send, now });
		q.enqueue(op("a"));
		await q.onJoined();
		expect(q.size()).toBe(1);
		clock += BASE_BACKOFF_MS;
		result = "ok";
		await q.tick();
		expect(q.size()).toBe(0);
	});

	it("drops after MAX_ATTEMPTS failures with onDrop 'max-attempts'", async () => {
		const dropped: { docId: string; reason: string }[] = [];
		const send = vi.fn(async (): Promise<SendResult> => "error");
		const q = new CrdtOpQueue({
			send,
			now,
			onDrop: (o, r) => dropped.push({ docId: o.docId, reason: r }),
			options: { opTtlMs: 10_000_000 }, // large TTL so only max-attempts can drop it
		});
		q.enqueue(op("a"));
		await q.onJoined();
		// Drive enough ticks (advancing past each backoff) to exhaust attempts.
		for (let i = 0; i < MAX_ATTEMPTS + 2; i++) {
			clock += 60_000; // past any backoff ceiling
			await q.tick();
		}
		expect(send).toHaveBeenCalledTimes(MAX_ATTEMPTS);
		expect(q.size()).toBe(0);
		expect(dropped).toEqual([{ docId: "a", reason: "max-attempts" }]);
	});
});

describe("CrdtOpQueue — coalesce + bounds", () => {
	it("coalesces one op per docId (delete supersedes a pending create)", async () => {
		const sent: CrdtOp[] = [];
		const send = vi.fn(async (o: CrdtOp): Promise<SendResult> => {
			sent.push(o);
			return "ok";
		});
		const q = new CrdtOpQueue({ send, now });
		q.enqueue(op("a", "create"));
		q.enqueue(op("a", "delete")); // supersede
		expect(q.size()).toBe(1);
		await q.onJoined();
		expect(sent).toHaveLength(1);
		expect(sent[0]?.kind).toBe("delete");
	});

	it("drops the oldest pending op on overflow (onDrop 'overflow')", async () => {
		const dropped: string[] = [];
		const send = vi.fn(async (): Promise<SendResult> => "ok");
		const q = new CrdtOpQueue({
			send,
			now,
			onDrop: (o, r) => r === "overflow" && dropped.push(o.docId),
			options: { maxQueue: 2 },
		});
		q.enqueue(op("a"));
		q.enqueue(op("b"));
		q.enqueue(op("c")); // overflow → evict oldest "a"
		expect(q.size()).toBe(2);
		expect(dropped).toEqual(["a"]);
	});
});

describe("CrdtOpQueue — TTL", () => {
	it("drops an op past its TTL on flush instead of sending it (onDrop 'ttl')", async () => {
		const dropped: string[] = [];
		const send = vi.fn(async (): Promise<SendResult> => "ok");
		const q = new CrdtOpQueue({
			send,
			now,
			onDrop: (o, r) => r === "ttl" && dropped.push(o.docId),
			options: { opTtlMs: 1000 },
		});
		q.enqueue(op("a", "create", 0));
		clock = 1001; // aged past TTL while offline
		await q.onJoined();
		expect(send).not.toHaveBeenCalled();
		expect(dropped).toEqual(["a"]);
		expect(q.size()).toBe(0);
	});
});

describe("CrdtOpQueue — load (restore)", () => {
	it("prunes TTL-expired ops, resets attempts, and honors maxQueue", async () => {
		const dropped: { docId: string; reason: string }[] = [];
		const send = vi.fn(async (): Promise<SendResult> => "ok");
		clock = 10_000;
		const q = new CrdtOpQueue({
			send,
			now,
			onDrop: (o, r) => dropped.push({ docId: o.docId, reason: r }),
			options: { opTtlMs: 5000, maxQueue: 2 },
		});
		q.load([
			{ ...op("stale", "create", 0), attempts: 4 }, // 10s old > 5s TTL → pruned
			{ ...op("x", "create", 8000), attempts: 4 },
			{ ...op("y", "create", 9000), attempts: 4 },
			{ ...op("z", "create", 9500), attempts: 4 }, // over maxQueue → evict oldest kept
		]);
		expect(dropped).toContainEqual({ docId: "stale", reason: "ttl" });
		expect(q.size()).toBe(2);
		// attempts reset → all deliver in one joined flush
		await q.onJoined();
		expect(q.size()).toBe(0);
	});
});

describe("CrdtOpQueue — persistence", () => {
	it("debounces persist writes across rapid mutations", async () => {
		vi.useFakeTimers();
		try {
			const persist = vi.fn();
			const send = vi.fn(async (): Promise<SendResult> => "ok");
			const q = new CrdtOpQueue({ send, now, persistDelayMs: 1000 });
			q.setPersist(persist);
			q.enqueue(op("a"));
			q.enqueue(op("b"));
			q.enqueue(op("c"));
			expect(persist).not.toHaveBeenCalled(); // debounced
			vi.advanceTimersByTime(1000);
			expect(persist).toHaveBeenCalledTimes(1);
			expect(persist.mock.calls[0]?.[0]).toHaveLength(3);
		} finally {
			vi.useRealTimers();
		}
	});
});
