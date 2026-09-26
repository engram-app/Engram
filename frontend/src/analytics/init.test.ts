import { describe, expect, it } from "vitest";
import { posthogInitOptions } from "./init";

// Every capture surface PostHog can switch on from the PROJECT dashboard must be
// pinned off in code. Heatmaps key their payload by the full location.href (the
// vault slug is a user-typed vault name), dead clicks and rageclicks carry
// element text, exception autocapture carries messages, and none of them pass
// through sanitize_properties' URL-key check.
describe("posthogInitOptions", () => {
	const options = posthogInitOptions();

	it.each([
		"autocapture",
		"capture_pageview",
		"capture_pageleave",
		"capture_heatmaps",
		"capture_dead_clicks",
		"capture_exceptions",
		"capture_performance",
		"rageclick",
	] as const)("pins %s off", (flag) => {
		expect(options[flag]).toBe(false);
	});

	it("disables session recording and surveys", () => {
		expect(options.disable_session_recording).toBe(true);
		expect(options.disable_surveys).toBe(true);
	});

	it("keeps the URL-stripping sanitizer wired", () => {
		const clean = options.sanitize_properties?.(
			{ $current_url: "https://app.engram.page/v/divorce-2026", step: "vault" },
			"x",
		);
		expect(clean).toEqual({ step: "vault" });
	});
});
