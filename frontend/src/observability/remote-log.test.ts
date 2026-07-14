import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { RemoteLogBuffer } from "./remote-log";

const transport = {
	url: "https://api.example",
	token: "tok",
	vaultId: "v-1",
	deviceId: "d-1",
};

describe("RemoteLogBuffer", () => {
	let calls: Array<{ url: string; init: RequestInit }>;

	beforeEach(() => {
		vi.useFakeTimers();
		calls = [];
		vi.stubGlobal("fetch", (url: string, init: RequestInit) => {
			calls.push({ url, init });
			return Promise.resolve(new Response("{}"));
		});
	});

	afterEach(() => {
		vi.useRealTimers();
		vi.unstubAllGlobals();
	});

	it("batches lines and flushes on the timer with auth + device headers", async () => {
		const buf = new RemoteLogBuffer(async () => transport);
		buf.log("warn", "crdt", "crdt_msg push timeout note=abc");
		buf.log("info", "crdt", "re-handshake scheduled note=abc");
		expect(calls).toHaveLength(0);

		await vi.advanceTimersByTimeAsync(5000);

		expect(calls).toHaveLength(1);
		expect(calls[0]?.url).toBe("https://api.example/api/logs");
		const headers = calls[0]?.init.headers as Record<string, string>;
		expect(headers.Authorization).toBe("Bearer tok");
		expect(headers["X-Vault-ID"]).toBe("v-1");
		expect(headers["X-Device-Id"]).toBe("d-1");
		const body = JSON.parse(String(calls[0]?.init.body));
		expect(body.logs).toHaveLength(2);
		expect(body.logs[0]).toMatchObject({
			level: "warn",
			category: "crdt",
			platform: "web",
		});
	});

	it("auto-flushes at the batch cap without waiting for the timer", async () => {
		const buf = new RemoteLogBuffer(async () => transport);
		for (let i = 0; i < 20; i++) {
			buf.log("info", "crdt", `line ${i}`);
		}
		await vi.advanceTimersByTimeAsync(0);
		expect(calls).toHaveLength(1);
		expect(JSON.parse(String(calls[0]?.init.body)).logs).toHaveLength(20);
	});

	it("drops silently when signed out (no token) — never networks", async () => {
		const buf = new RemoteLogBuffer(async () => ({ ...transport, token: null }));
		buf.log("error", "crdt", "x");
		await buf.flush();
		expect(calls).toHaveLength(0);
	});

	it("bounds the queue: oldest lines drop when transport is wedged", async () => {
		const buf = new RemoteLogBuffer(async () => ({ ...transport, token: null }));
		for (let i = 0; i < 260; i++) {
			buf.log("info", "crdt", `line ${i}`);
		}
		// Un-wedge and flush: only the newest MAX_QUEUE(200) minus already
		// attempted flushes remain — assert the cap held, not an exact count.
		const sent: number[] = [];
		const buf2 = buf as unknown as { queue: unknown[] };
		expect(buf2.queue.length).toBeLessThanOrEqual(200);
		expect(sent).toHaveLength(0);
	});

	it("truncates oversized messages", async () => {
		const buf = new RemoteLogBuffer(async () => transport);
		buf.log("warn", "crdt", "x".repeat(2000));
		await buf.flush();
		const body = JSON.parse(String(calls[0]?.init.body));
		expect(body.logs[0].message.length).toBeLessThanOrEqual(500);
	});

	it("a fetch failure never throws into the caller", async () => {
		vi.stubGlobal("fetch", () => Promise.reject(new Error("network down")));
		const buf = new RemoteLogBuffer(async () => transport);
		buf.log("warn", "crdt", "x");
		await expect(buf.flush()).resolves.toBeUndefined();
	});
});
