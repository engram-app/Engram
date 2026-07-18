import { afterEach, describe, expect, it, vi } from "vitest";
import { beacon } from "../observability/trace";
import { setTracingEnabled } from "./base";
import { pushFailureBeacon } from "./channel";

describe("pushFailureBeacon", () => {
	afterEach(() => {
		setTracingEnabled(false);
		vi.restoreAllMocks();
	});

	it("no-ops entirely when tracing is disabled", () => {
		setTracingEnabled(false);
		const enqueue = vi.spyOn(beacon, "enqueue");
		pushFailureBeacon("019f45c5-7818-771b-9242-9ae8c7fd214f", Date.now() * 1000, "timeout");
		expect(enqueue).not.toHaveBeenCalled();
	});

	it("enqueues a web.crdt.push span with note_id + reason when tracing is on", () => {
		setTracingEnabled(true);
		const enqueue = vi.spyOn(beacon, "enqueue").mockImplementation(() => {});
		pushFailureBeacon("019f45c5-7818-771b-9242-9ae8c7fd214f", Date.now() * 1000, "rate_limited");
		expect(enqueue).toHaveBeenCalledTimes(1);
		const entry = enqueue.mock.calls[0]?.[0];
		expect(entry?.name).toBe("web.crdt.push");
		expect(entry?.attributes).toMatchObject({
			"engram.surface": "web",
			"engram.event_type": "push_failed",
			"engram.note_id": "019f45c5-7818-771b-9242-9ae8c7fd214f",
			"engram.reason": "rate_limited",
		});
		expect(entry?.trace_id).toMatch(/^[0-9a-f]{32}$/);
		expect(entry?.parent_span_id).toMatch(/^[0-9a-f]{16}$/);
	});

	it("bounds the reason attribute to the sanitizer's 64-byte contract", () => {
		setTracingEnabled(true);
		const enqueue = vi.spyOn(beacon, "enqueue").mockImplementation(() => {});
		pushFailureBeacon("019f45c5-7818-771b-9242-9ae8c7fd214f", Date.now() * 1000, "x".repeat(200));
		const entry = enqueue.mock.calls[0]?.[0];
		expect((entry?.attributes["engram.reason"] ?? "").length).toBeLessThanOrEqual(64);
	});
});
