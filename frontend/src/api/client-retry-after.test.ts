import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { ApiError, api } from "./client";

// 2026-10-31: the backend sheds a write with 429 + `retry-after: 2` when the
// vault's write gate is busy (SeqGate.BusyError). The client waits it out on
// requests that are safe to send twice. A 429 WITHOUT retry-after (an MCP
// cap-0 refusal) means "no", and is never retried.

function tooBusy(retryAfter?: string) {
	const headers: Record<string, string> = { "Content-Type": "application/json" };
	if (retryAfter !== undefined) {
		headers["retry-after"] = retryAfter;
	}
	return new Response(JSON.stringify({ error: "busy" }), { status: 429, headers });
}

const ok = () =>
	new Response(JSON.stringify({ ok: true }), {
		status: 200,
		headers: { "Content-Type": "application/json" },
	});

/** Header value the n-th fetch call (0-based) was sent with. */
function sentHeader(fetchMock: ReturnType<typeof vi.fn>, n: number, name: string) {
	return new Headers(fetchMock.mock.calls[n]?.[1]?.headers).get(name);
}

describe("api client retries a 429 that carries retry-after", () => {
	beforeEach(() => {
		vi.useFakeTimers();
	});
	afterEach(() => {
		vi.useRealTimers();
	});

	it("resends an idempotent request after the retry-after delay", async () => {
		const fetchMock = vi.fn().mockResolvedValueOnce(tooBusy("2")).mockResolvedValueOnce(ok());
		globalThis.fetch = fetchMock;

		const result = api.get<{ ok: boolean }>("/notes");
		await vi.advanceTimersByTimeAsync(1999);
		expect(fetchMock).toHaveBeenCalledTimes(1);
		await vi.advanceTimersByTimeAsync(1);
		await expect(result).resolves.toEqual({ ok: true });
		expect(fetchMock).toHaveBeenCalledTimes(2);
	});

	it("does not retry a 429 without retry-after", async () => {
		const fetchMock = vi.fn().mockResolvedValue(tooBusy());
		globalThis.fetch = fetchMock;

		await expect(api.get("/notes")).rejects.toMatchObject({ status: 429 });
		expect(fetchMock).toHaveBeenCalledTimes(1);
	});

	it("does not retry a POST that carries no idempotency key", async () => {
		const fetchMock = vi.fn().mockResolvedValueOnce(tooBusy("2")).mockResolvedValueOnce(ok());
		globalThis.fetch = fetchMock;

		const result = api.post("/notes/append", { text: "x" });
		const settled = expect(result).rejects.toMatchObject({ status: 429, retryAfterS: 2 });
		await vi.advanceTimersByTimeAsync(5000);
		await settled;
		expect(fetchMock).toHaveBeenCalledTimes(1);
	});

	it("resends an idempotency-keyed POST with the same key", async () => {
		const fetchMock = vi.fn().mockResolvedValueOnce(tooBusy("1")).mockResolvedValueOnce(ok());
		globalThis.fetch = fetchMock;
		const key = "0b9e5b8a-2d8f-4a43-9f53-3f1f3b7b7a11";

		const result = api.post(
			"/folders/batch-delete",
			{ ids: [] },
			{
				headers: { "X-Idempotency-Key": key },
			},
		);
		await vi.advanceTimersByTimeAsync(1000);
		await expect(result).resolves.toEqual({ ok: true });
		expect(fetchMock).toHaveBeenCalledTimes(2);
		expect(sentHeader(fetchMock, 1, "X-Idempotency-Key")).toBe(key);
	});

	it("clamps a huge retry-after to 30s", async () => {
		const fetchMock = vi.fn().mockResolvedValueOnce(tooBusy("3600")).mockResolvedValueOnce(ok());
		globalThis.fetch = fetchMock;

		const result = api.get("/notes");
		await vi.advanceTimersByTimeAsync(29_999);
		expect(fetchMock).toHaveBeenCalledTimes(1);
		await vi.advanceTimersByTimeAsync(1);
		await expect(result).resolves.toEqual({ ok: true });
	});

	it("gives up after 3 attempts and surfaces the last 429 as today", async () => {
		const fetchMock = vi.fn().mockImplementation(() => Promise.resolve(tooBusy("2")));
		globalThis.fetch = fetchMock;

		const result = api.del("/folders/abc");
		const settled = expect(result).rejects.toBeInstanceOf(ApiError);
		await vi.advanceTimersByTimeAsync(10_000);
		await settled;
		await expect(result).rejects.toMatchObject({ status: 429, retryAfterS: 2 });
		expect(fetchMock).toHaveBeenCalledTimes(3);
	});

	it("stops waiting when the caller aborts", async () => {
		const fetchMock = vi
			.fn()
			.mockImplementation((_url, init?: RequestInit) =>
				init?.signal?.aborted
					? Promise.reject(new DOMException("aborted", "AbortError"))
					: Promise.resolve(tooBusy("30")),
			);
		globalThis.fetch = fetchMock;
		const ctl = new AbortController();

		const result = api.get("/notes", { signal: ctl.signal });
		const settled = expect(result).rejects.toMatchObject({ name: "AbortError" });
		await vi.advanceTimersByTimeAsync(10);
		ctl.abort();
		await vi.advanceTimersByTimeAsync(0);
		await settled;
	});
});
