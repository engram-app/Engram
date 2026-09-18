/**
 * initAnalytics was extracted out of main.tsx's inline `if (posthogKey) {...}`
 * block into src/analytics/init.ts (alongside the existing track.ts/events.ts,
 * mirroring sentry.ts's own-module pattern) — specifically so it's importable
 * here without dragging in
 * main.tsx's module-scope side effects (createRoot(document.getElementById
 * ("root")!).render(...), which has no #root element in a unit test and
 * would boot the whole app).
 */
import { afterEach, describe, expect, it, vi } from "vitest";

const posthogInit = vi.fn();
vi.mock("posthog-js", () => ({ default: { init: posthogInit } }));

afterEach(() => {
	posthogInit.mockClear();
	Object.defineProperty(navigator, "globalPrivacyControl", {
		value: undefined,
		configurable: true,
	});
});

describe("initAnalytics", () => {
	it("does not init when the GPC signal is set", async () => {
		Object.defineProperty(navigator, "globalPrivacyControl", { value: true, configurable: true });
		const { initAnalytics } = await import("./analytics/init");
		await initAnalytics("phc_test");
		expect(posthogInit).not.toHaveBeenCalled();
	});

	it("uses identified_only person profiles", async () => {
		const { initAnalytics } = await import("./analytics/init");
		await initAnalytics("phc_test");
		expect(posthogInit).toHaveBeenCalledWith(
			"phc_test",
			expect.objectContaining({ person_profiles: "identified_only", persistence: "memory" }),
		);
	});

	it("does nothing at all without a key (the self-host shape)", async () => {
		const { initAnalytics } = await import("./analytics/init");
		await initAnalytics("");
		expect(posthogInit).not.toHaveBeenCalled();
	});

	it("leaves the other privacy-load-bearing options untouched", async () => {
		const { initAnalytics } = await import("./analytics/init");
		await initAnalytics("phc_test");
		expect(posthogInit).toHaveBeenCalledWith(
			"phc_test",
			expect.objectContaining({
				autocapture: false,
				capture_pageview: false,
				capture_pageleave: false,
				disable_session_recording: true,
			}),
		);
	});
});
