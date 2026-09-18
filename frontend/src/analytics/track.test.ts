import { describe, expect, it, vi } from "vitest";
import posthog from "posthog-js";
import { track } from "./track";

vi.mock("posthog-js", () => ({ default: { capture: vi.fn() } }));

describe("track property validation", () => {
	it("allows uuids, enum members, booleans and numbers", () => {
		track("onboarding_step_viewed", {
			step: "billing",
			vault_id: "12dc6735-52f2-4ce4-9117-91f0ce2389a7",
			is_retry: false,
			duration_ms: 1420,
		});
		expect(posthog.capture).toHaveBeenCalledOnce();
	});

	it.each([
		["a note title", { step: "vault", title: "My private journal" }],
		["a vault path", { step: "vault", path: "Work/2026/Q3 review.md" }],
		["a search query", { step: "done", query: "salary negotiation" }],
		["a raw email", { step: "done", email: "sabio@web.de" }],
	])("rejects %s", (_label, props) => {
		expect(() => track("onboarding_step_viewed", props)).toThrow(/not an allowed/i);
	});
});
