import { afterEach, describe, expect, it, vi } from "vitest";
import posthog from "posthog-js";
import { captureError } from "../sentry";
import { track } from "./track";

vi.mock("posthog-js", () => ({ default: { capture: vi.fn() } }));
// Mirrors route-error-boundary.test.tsx's convention: assert WHAT gets
// reported without a real Sentry SDK. Default: "delivered nothing".
vi.mock("../sentry", () => ({ captureError: vi.fn(() => Promise.resolve(undefined)) }));
const mockCapture = vi.mocked(captureError);

afterEach(() => {
	vi.unstubAllEnvs();
	mockCapture.mockClear();
	vi.mocked(posthog.capture).mockClear();
});

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
		// The point of this round: a value that is valid SOMEWHERE (a UUID, an
		// onboarding step) must still be rejected under a key its event's
		// schema never declared. Checking the value's shape is not enough.
		["a valid enum value under an undeclared key", { step: "vault", title: "done" }],
		["a uuid-shaped string under an undeclared key", { step: "vault", user_uuid: "12dc6735-52f2-4ce4-9117-91f0ce2389a7" }],
	])("rejects %s", (_label, props) => {
		expect(() => track("onboarding_step_viewed", props)).toThrow(/not an allowed/i);
	});

	it("rejects a declared key whose value is the wrong kind", () => {
		// `step` is declared as kind "step" for this event; a checkout method
		// string is the wrong kind for that key, not merely an unknown key.
		expect(() => track("onboarding_step_viewed", { step: "card" })).toThrow(/not an allowed/i);
	});

	describe("in production (no dev-throw)", () => {
		it("drops the event, warns, and reports the violation to Sentry with no value", () => {
			vi.stubEnv("DEV", false);
			const warn = vi.spyOn(console, "warn").mockImplementation(() => {});

			track("onboarding_step_viewed", { step: "vault", title: "My private journal" });

			expect(posthog.capture).not.toHaveBeenCalled();
			expect(warn).toHaveBeenCalled();
			expect(mockCapture).toHaveBeenCalledOnce();

			const reportedError = mockCapture.mock.calls[0]?.[0];
			const reportedMessage = String(reportedError);
			expect(reportedMessage).toContain("title");
			expect(reportedMessage).toContain("onboarding_step_viewed");
			// The offending value must never appear in what gets shipped to Sentry.
			expect(reportedMessage).not.toContain("My private journal");

			warn.mockRestore();
		});
	});
});
