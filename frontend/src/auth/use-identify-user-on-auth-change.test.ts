import { renderHook } from "@testing-library/react";
import { afterEach, describe, expect, it, vi } from "vitest";
import { useIdentifyUserOnAuthChange } from "./use-identify-user-on-auth-change";

const identify = vi.fn();
const reset = vi.fn();
const setSentryUser = vi.fn((_id: string | null) => Promise.resolve());

vi.mock("posthog-js", () => ({
	default: {
		identify: (...args: unknown[]) => identify(...args),
		reset: () => reset(),
	},
}));
vi.mock("../sentry", () => ({ setSentryUser: (id: string | null) => setSentryUser(id) }));

const render = (props: {
	isLoaded: boolean;
	isSignedIn: boolean;
	id?: string;
	analyticsId?: string;
}) => renderHook((p: typeof props) => useIdentifyUserOnAuthChange(p), { initialProps: props });

describe("useIdentifyUserOnAuthChange", () => {
	afterEach(() => {
		identify.mockClear();
		reset.mockClear();
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
