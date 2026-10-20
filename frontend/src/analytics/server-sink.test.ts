import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { ServerEventSink } from "./server-sink";

const transport = { url: "https://api.example", token: "tok" };

describe("ServerEventSink", () => {
	let calls: Array<{ url: string; init: RequestInit }>;

	beforeEach(() => {
		vi.useFakeTimers();
		calls = [];
		vi.stubGlobal("fetch", (url: string, init: RequestInit) => {
			calls.push({ url, init });
			return Promise.resolve(new Response(null, { status: 204 }));
		});
		vi.stubGlobal("navigator", {});
	});

	afterEach(() => {
		vi.useRealTimers();
		vi.unstubAllGlobals();
	});

	const body = (i: number) => JSON.parse(String(calls[i]?.init.body));

	it("holds events until the user is known, then posts them in one keepalive batch", async () => {
		const sink = new ServerEventSink(async () => transport);
		sink.add("paywall_shown", { limit_key: "notes_cap_exceeded" });
		sink.add("checkout_opened", { tier: "pro" });
		await vi.advanceTimersByTimeAsync(10_000);
		expect(calls).toHaveLength(0);

		sink.enable();
		await vi.advanceTimersByTimeAsync(5000);

		expect(calls).toHaveLength(1);
		expect(calls[0]?.url).toBe("https://api.example/api/analytics/events");
		expect(calls[0]?.init.keepalive).toBe(true);
		const headers = calls[0]?.init.headers as Record<string, string>;
		expect(headers.Authorization).toBe("Bearer tok");
		expect(body(0).events).toEqual([
			{ event: "paywall_shown", props: { limit_key: "notes_cap_exceeded" } },
			{ event: "checkout_opened", props: { tier: "pro" } },
		]);
	});

	it("sends at most 20 events per request", async () => {
		const sink = new ServerEventSink(async () => transport);
		sink.enable();
		for (let i = 0; i < 25; i++) {
			sink.add("plugin_listing_opened", {});
		}
		await sink.flush();
		await vi.advanceTimersByTimeAsync(5000);

		expect(calls.map((_, i) => body(i).events.length)).toEqual([20, 5]);
	});

	// An opt-out, or a sign-out: nothing is sent, and nothing held is sent later.
	it("sends nothing once disabled and drops what it held", async () => {
		const sink = new ServerEventSink(async () => transport);
		sink.add("plugin_listing_opened", {});
		sink.disable();
		sink.add("plugin_listing_opened", {});
		sink.enable();
		await sink.flush();
		expect(calls).toHaveLength(0);
	});

	it.each([
		["Global Privacy Control", { globalPrivacyControl: true }],
		["Do Not Track", { doNotTrack: "1" }],
	])("sends nothing under %s", async (_label, nav) => {
		vi.stubGlobal("navigator", nav);
		const sink = new ServerEventSink(async () => transport);
		sink.enable();
		sink.add("plugin_listing_opened", {});
		await sink.flush();
		await vi.advanceTimersByTimeAsync(5000);
		expect(calls).toHaveLength(0);
	});

	it("drops the batch when signed out, without a request", async () => {
		const sink = new ServerEventSink(async () => ({ ...transport, token: null }));
		sink.enable();
		sink.add("plugin_listing_opened", {});
		await sink.flush();
		expect(calls).toHaveLength(0);
	});
});
