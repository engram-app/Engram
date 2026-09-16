import { beforeEach, describe, expect, it } from "vitest";
import { stashPendingAuthorization } from "../oauth/pending-authorization";
import { onboardingDoneTarget, onboardingNext } from "./onboarding-next";

const SEARCH = "?client_id=cli&state=xyz";

describe("onboardingNext", () => {
	beforeEach(() => {
		window.sessionStorage.clear();
	});

	it("routes to the named step while the wizard is unfinished", () => {
		expect(onboardingNext({ next_step: "agreement" })).toBe("/onboard/agreement");
		expect(onboardingNext({ next_step: "billing" })).toBe("/onboard/billing");
		expect(onboardingNext({ next_step: "vault" })).toBe("/onboard/vault");
	});

	it("sends a finished user home when nothing is pending", () => {
		expect(onboardingNext({ next_step: "done" })).toBe("/");
	});

	// The whole point: a user pulled into the wizard mid-OAuth lands back on
	// consent with the request intact, instead of on the dashboard wondering
	// what happened to the app that sent them.
	it("returns a finished user to a pending authorization", () => {
		stashPendingAuthorization(SEARCH, "antigravity");

		expect(onboardingNext({ next_step: "done" })).toBe(`/oauth/consent${SEARCH}`);
	});

	// A pending authorization must not short-circuit the wizard. It is only
	// consulted once every step is genuinely done.
	it("does not divert an unfinished wizard", () => {
		stashPendingAuthorization(SEARCH, "antigravity");

		expect(onboardingNext({ next_step: "billing" })).toBe("/onboard/billing");
	});
});

describe("onboardingDoneTarget", () => {
	beforeEach(() => {
		window.sessionStorage.clear();
	});

	it("is home by default", () => {
		expect(onboardingDoneTarget()).toBe("/");
	});

	it("is the pending authorization when one exists", () => {
		stashPendingAuthorization(SEARCH, null);

		expect(onboardingDoneTarget()).toBe(`/oauth/consent${SEARCH}`);
	});
});
