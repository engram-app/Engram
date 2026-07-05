import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { getTracingEnabled, setTracingEnabled } from "../api/base";
import { api } from "../api/client";
import { BeaconBuffer, type BeaconEntry, newTraceContext, parseTraceparent } from "./trace";

const entry = (): BeaconEntry => ({
	trace_id: "1".repeat(32),
	parent_span_id: "2".repeat(16),
	name: "browser.live_sync.render",
	start_us: 1,
	end_us: 2,
	attributes: {},
});

describe("newTraceContext", () => {
	it("returns a well-formed sampled traceparent", () => {
		const { traceparent, traceId, spanId } = newTraceContext();
		expect(traceparent).toMatch(/^00-[0-9a-f]{32}-[0-9a-f]{16}-01$/);
		expect(traceparent).toBe(`00-${traceId}-${spanId}-01`);
	});

	it("mints distinct ids across calls", () => {
		expect(newTraceContext().traceId).not.toBe(newTraceContext().traceId);
	});
});

describe("parseTraceparent", () => {
	it("round-trips a well-formed traceparent", () => {
		const { traceparent, traceId, spanId } = newTraceContext();
		expect(parseTraceparent(traceparent)).toEqual({ traceId, parentSpanId: spanId });
	});

	it("returns null on garbage", () => {
		expect(parseTraceparent("nope")).toBeNull();
	});
});

describe("BeaconBuffer", () => {
	it("batches all queued spans into one request", async () => {
		const calls: Array<{ url: string; opts: RequestInit }> = [];
		vi.stubGlobal("fetch", (url: string, opts: RequestInit) => {
			calls.push({ url, opts });
			return Promise.resolve(new Response(null, { status: 202 }));
		});

		const buf = new BeaconBuffer(() => ({ url: "https://api.example", token: "t", vaultId: "v" }));
		buf.enqueue(entry());
		buf.enqueue(entry());
		await buf.flush();

		expect(calls).toHaveLength(1);
		expect(calls[0]!.url).toBe("https://api.example/api/telemetry/spans");
		expect((calls[0]!.opts as RequestInit).keepalive).toBe(true);
		const body = JSON.parse(calls[0]!.opts.body as string);
		expect(body.spans).toHaveLength(2);

		const headers = calls[0]!.opts.headers as Record<string, string>;
		expect(headers.Authorization).toBe("Bearer t");
		expect(headers["X-Vault-ID"]).toBe("v");
	});

	it("null transport (disabled) issues no request", async () => {
		const calls: unknown[] = [];
		vi.stubGlobal("fetch", (...args: unknown[]) => {
			calls.push(args);
			return Promise.resolve(new Response(null, { status: 202 }));
		});

		const buf = new BeaconBuffer(() => null);
		buf.enqueue(entry());
		await buf.flush();

		expect(calls).toHaveLength(0);
	});

	it("never throws when fetch rejects", async () => {
		vi.stubGlobal("fetch", () => Promise.reject(new Error("network")));

		const buf = new BeaconBuffer(() => ({ url: "https://api.example", token: "t", vaultId: "v" }));
		buf.enqueue(entry());

		await expect(buf.flush()).resolves.toBeUndefined();
	});

	it("flushing an empty queue issues no request", async () => {
		const calls: unknown[] = [];
		vi.stubGlobal("fetch", (...args: unknown[]) => {
			calls.push(args);
			return Promise.resolve(new Response(null, { status: 202 }));
		});

		const buf = new BeaconBuffer(() => ({ url: "https://api.example", token: "t", vaultId: "v" }));
		await buf.flush();

		expect(calls).toHaveLength(0);
	});
});

describe("authFetch traceparent injection (disabled = zero work)", () => {
	const originalTracingEnabled = getTracingEnabled();

	beforeEach(() => {
		setTracingEnabled(false);
	});

	afterEach(() => {
		setTracingEnabled(originalTracingEnabled);
		vi.unstubAllGlobals();
	});

	it("adds no traceparent header when tracing is disabled", async () => {
		const fetchMock = vi.fn().mockResolvedValue(new Response("{}", { status: 200 }));
		vi.stubGlobal("fetch", fetchMock);

		await api.get("/anything");

		const init = fetchMock.mock.calls[0]![1] as RequestInit;
		const headers = init.headers as Headers;
		expect(headers.has("traceparent")).toBe(false);
	});

	it("adds a well-formed traceparent header when tracing is enabled", async () => {
		setTracingEnabled(true);
		const fetchMock = vi.fn().mockResolvedValue(new Response("{}", { status: 200 }));
		vi.stubGlobal("fetch", fetchMock);

		await api.get("/anything");

		const init = fetchMock.mock.calls[0]![1] as RequestInit;
		const headers = init.headers as Headers;
		expect(headers.get("traceparent")).toMatch(/^00-[0-9a-f]{32}-[0-9a-f]{16}-01$/);
	});
});
