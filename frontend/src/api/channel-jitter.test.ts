import { afterEach, describe, expect, it } from "vitest";
import {
	RECONNECT_JITTER_DEFAULT_MS,
	RECONNECT_JITTER_MAX_MS,
	clampReconnectJitter,
	computeReconnectMs,
	captureServerJitter,
	__getServerJitterMs,
	__resetServerJitterMs,
} from "./channel";

afterEach(() => __resetServerJitterMs());

describe("clampReconnectJitter", () => {
	it("accepts a valid number", () => expect(clampReconnectJitter(8000)).toBe(8000));
	it("clamps above the ceiling", () =>
		expect(clampReconnectJitter(999_999)).toBe(RECONNECT_JITTER_MAX_MS));
	it("rejects negatives", () => expect(clampReconnectJitter(-1)).toBeNull());
	it("rejects zero (coalesces to default, not no-jitter)", () =>
		expect(clampReconnectJitter(0)).toBeNull());
	it("rejects NaN/Infinity", () => {
		expect(clampReconnectJitter(NaN)).toBeNull();
		expect(clampReconnectJitter(Infinity)).toBeNull();
	});
	it("rejects non-numbers", () => expect(clampReconnectJitter("5000")).toBeNull());
});

describe("computeReconnectMs", () => {
	it("full-jitters the first reconnect over [0, window]", () =>
		expect(computeReconnectMs(1, 8000, () => 0.5)).toBe(4000));
	it("uses the default window when none cached", () =>
		expect(computeReconnectMs(1, null, () => 0.5)).toBe(RECONNECT_JITTER_DEFAULT_MS * 0.5));
	it("keeps stepped backoff for later tries", () =>
		expect(computeReconnectMs(3, 8000, () => 0.5)).toBe(100));
});

describe("captureServerJitter", () => {
	it("stores a clamped value from the join reply", () => {
		captureServerJitter({ reconnect_jitter_max_ms: 999_999 });
		expect(__getServerJitterMs()).toBe(RECONNECT_JITTER_MAX_MS);
	});
	it("ignores a malformed value", () => {
		captureServerJitter({ reconnect_jitter_max_ms: "nope" });
		expect(__getServerJitterMs()).toBeNull();
	});
});
