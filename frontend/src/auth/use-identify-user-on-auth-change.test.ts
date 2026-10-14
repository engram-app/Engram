import { renderHook } from "@testing-library/react";
import type { PostHog } from "posthog-js";
import { afterEach, describe, expect, it, vi } from "vitest";
import { setAnalyticsClient } from "../analytics/client";
import { useIdentifyUserOnAuthChange } from "./use-identify-user-on-auth-change";

const identify = vi.fn();
const reset = vi.fn();
const optOut = vi.fn();
const optIn = vi.fn();
let optedOut = false;
const setSentryUser = vi.fn((_id: string | null) => Promise.resolve());

vi.mock("../sentry", () => ({ setSentryUser: (id: string | null) => setSentryUser(id) }));
// identity.ts reaches PostHog through the loaded client, so a stand-in is enough.
setAnalyticsClient({
	identify,
	reset,
	opt_out_capturing: optOut,
	opt_in_capturing: optIn,
	has_opted_out_capturing: () => optedOut,
} as unknown as PostHog);

const render = (props: {
	isLoaded: boolean;
	isSignedIn: boolean;
	id?: string;
	analyticsId?: string;
	analyticsOptOut?: boolean;
}) => renderHook((p: typeof props) => useIdentifyUserOnAuthChange(p), { initialProps: props });

describe("useIdentifyUserOnAuthChange", () => {
	afterEach(() => {
		identify.mockClear();
		reset.mockClear();
		optOut.mockClear();
		optIn.mockClear();
		optedOut = false;
		vi.unstubAllGlobals();
		setSentryUser.mockClear();
	});

	// Clerk reports isSignedIn:false while it is still resolving. Acting on that
	// would reset the user on every page load, breaking event attribution.
	it("does nothing until auth has resolved", () => {
		render({ isLoaded: false, isSignedIn: false });
		expect(identify).not.toHaveBeenCalled();
		expect(reset).not.toHaveBeenCalled();
		expect(setSentryUser).not.toHaveBeenCalled();
	});

	it("identifies with the analytics id and never with an email", () => {
		renderHook(() =>
			useIdentifyUserOnAuthChange({
				isLoaded: true,
				isSignedIn: true,
				analyticsId: "a".repeat(64),
				id: "user_3J50JyLu",
			}),
		);

		expect(identify).toHaveBeenCalledWith("a".repeat(64));
		// One argument only. A second argument is how a raw email reaches PostHog,
		// and our privacy policy says it does not.
		expect(identify.mock.calls[0]).toHaveLength(1);
	});

	// The privacy policy promises an objecting user's analytics stop entirely,
	// including the anonymous events the SPA would otherwise keep sending.
	it("stops all capture for a user who opted out of analytics", () => {
		render({ isLoaded: true, isSignedIn: true, id: "user_x", analyticsOptOut: true });
		expect(optOut).toHaveBeenCalledTimes(1);
		expect(identify).not.toHaveBeenCalled();
	});

	// posthog-js persists an opt-out in localStorage, which is what keeps an
	// objecting user silent from page load, before /me answers. It must not
	// also silence the next person to sign in on this browser.
	it("lifts a previous user's persisted opt-out before identifying", () => {
		optedOut = true;
		render({ isLoaded: true, isSignedIn: true, id: "u2", analyticsId: "b".repeat(64) });
		expect(optIn).toHaveBeenCalledWith({ captureEventName: false });
		expect(identify).toHaveBeenCalledWith("b".repeat(64));
		const [optInAt] = optIn.mock.invocationCallOrder;
		const [identifyAt] = identify.mock.invocationCallOrder;
		expect(optInAt).toBeLessThan(identifyAt ?? 0);
	});

	it("never opts back in a browser that sends Do Not Track", () => {
		optedOut = true;
		vi.stubGlobal("navigator", { ...navigator, doNotTrack: "1" });
		render({ isLoaded: true, isSignedIn: true, id: "u2", analyticsId: "b".repeat(64) });
		expect(optIn).not.toHaveBeenCalled();
	});

	it("does not identify before the analytics id has loaded", () => {
		renderHook(() =>
			useIdentifyUserOnAuthChange({ isLoaded: true, isSignedIn: true, id: "user_3J50JyLu" }),
		);
		expect(identify).not.toHaveBeenCalled();
	});

	it("identifies Sentry with the Clerk id when signed in", () => {
		render({ isLoaded: true, isSignedIn: true, id: "user_1", analyticsId: "a".repeat(64) });
		expect(setSentryUser).toHaveBeenCalledWith("user_1");
	});

	it("clears BOTH on sign-out", () => {
		const { rerender } = render({
			isLoaded: true,
			isSignedIn: true,
			id: "user_1",
			analyticsId: "a".repeat(64),
		});
		identify.mockClear();
		setSentryUser.mockClear();

		rerender({ isLoaded: true, isSignedIn: false });
		expect(reset).toHaveBeenCalledTimes(1);
		expect(setSentryUser).toHaveBeenCalledWith(null);
	});

	// A signed-in state with no id yet is a transient Clerk frame, not a
	// sign-out. Resetting there would unbind the user mid-session.
	it("does not clear on a signed-in frame that has no id yet", () => {
		render({ isLoaded: true, isSignedIn: true });
		expect(reset).not.toHaveBeenCalled();
		expect(setSentryUser).not.toHaveBeenCalled();
	});
});
