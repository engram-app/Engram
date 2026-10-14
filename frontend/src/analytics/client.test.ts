import type { PostHog } from "posthog-js";
import { afterEach, describe, expect, it, vi } from "vitest";
import { setAnalyticsClient } from "./client";
import { forgetUser, identifyUser } from "./identity";
import { track } from "./track";

const posthog = {
	capture: vi.fn(),
	identify: vi.fn(),
	reset: vi.fn(),
	has_opted_out_capturing: () => false,
};

afterEach(() => setAnalyticsClient(null));

// posthog-js is ~300 KB. It reaches the page only through init.ts's dynamic
// import, which hands the loaded instance to client.ts. Until then (and always
// on self-host or under GPC) every call is a no-op, never a static import.
describe("analytics client", () => {
	it("sends nothing before analytics has loaded", () => {
		track("plugin_listing_opened", {});
		identifyUser("a1");
		forgetUser();
		expect(posthog.capture).not.toHaveBeenCalled();
		expect(posthog.identify).not.toHaveBeenCalled();
		expect(posthog.reset).not.toHaveBeenCalled();
	});

	it("routes calls to the loaded instance", () => {
		setAnalyticsClient(posthog as unknown as PostHog);
		identifyUser("a1");
		expect(posthog.identify).toHaveBeenCalledWith("a1");
	});
});
