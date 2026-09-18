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

	// H1: posthog-js attaches $current_url/$pathname/$referrer/etc. to every
	// capture() regardless of autocapture/capture_pageview, and a vault route
	// (/v/:slug) embeds the vault name in plaintext. Invoke the actual
	// sanitize_properties function passed to posthog.init with a synthetic
	// SDK-shaped payload — asserting on what real code reaches
	// posthog.capture, not just on the properties we pass ourselves.
	it("strips every URL-bearing property posthog-js attaches, including ones we never enumerated", async () => {
		const { initAnalytics } = await import("./analytics/init");
		await initAnalytics("phc_test");
		const config = posthogInit.mock.calls[0]![1] as {
			sanitize_properties: (
				props: Record<string, unknown>,
				event: string,
			) => Record<string, unknown>;
		};
		const dirtyProperties = {
			$current_url: "https://app.engram.page/v/my-private-journal",
			$pathname: "/v/my-private-journal",
			$host: "app.engram.page",
			$referrer: "https://app.engram.page/v/my-private-journal",
			$referring_domain: "app.engram.page",
			$initial_current_url: "https://app.engram.page/v/my-private-journal",
			$session_entry_url: "https://app.engram.page/v/my-private-journal",
			// simulates a property posthog-js might add in a future version
			// under a name this test (and init.ts) never enumerated
			$some_future_url_property: "https://app.engram.page/v/my-private-journal",
			step: "vault",
			vault_id: "11111111-1111-1111-1111-111111111111",
		};

		const cleaned = config.sanitize_properties(dirtyProperties, "onboarding_blocked");

		expect(JSON.stringify(cleaned)).not.toContain("my-private-journal");
		expect(cleaned).toEqual({ step: "vault", vault_id: "11111111-1111-1111-1111-111111111111" });
	});
});
