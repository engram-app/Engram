import type { PostHog } from "posthog-js";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { setAnalyticsClient } from "./client";
import { forgetUser, identifyUser, setPersonProperties, stopCapture } from "./identity";

// A stand-in that tracks posthog-js's persisted opt-out.
let optedOut = false;
const posthog = {
	has_opted_out_capturing: () => optedOut,
	opt_out_capturing: vi.fn(() => {
		optedOut = true;
	}),
	opt_in_capturing: vi.fn(() => {
		optedOut = false;
	}),
	identify: vi.fn(),
	reset: vi.fn(),
	setPersonProperties: vi.fn(),
};
setAnalyticsClient(posthog as unknown as PostHog);

beforeEach(() => {
	forgetUser();
	optedOut = false;
	vi.clearAllMocks();
});

describe("setPersonProperties", () => {
	it("sends properties while capturing", () => {
		setPersonProperties({ locale: "ja" });
		expect(posthog.setPersonProperties).toHaveBeenCalledWith({ locale: "ja" });
	});

	// On re-opt-in the locale effect runs before the identify hook lifts the
	// opt-out, and never re-runs. Holding the properties is what still lands it.
	it("holds properties set while opted out and sends them after identify", () => {
		stopCapture();
		setPersonProperties({ locale: "ja" });
		expect(posthog.setPersonProperties).not.toHaveBeenCalled();

		identifyUser("id-1");
		expect(posthog.identify).toHaveBeenCalledWith("id-1");
		expect(posthog.setPersonProperties).toHaveBeenCalledWith({ locale: "ja" });
	});

	it("drops held properties on sign-out", () => {
		stopCapture();
		setPersonProperties({ locale: "ja" });
		forgetUser();

		identifyUser("id-2");
		expect(posthog.setPersonProperties).not.toHaveBeenCalled();
	});

	it("keeps holding while capture stays off (Do Not Track)", () => {
		vi.stubGlobal("navigator", { doNotTrack: "1" });
		stopCapture();
		setPersonProperties({ locale: "ja" });

		identifyUser("id-1");
		expect(posthog.setPersonProperties).not.toHaveBeenCalled();
		vi.unstubAllGlobals();
	});
});
