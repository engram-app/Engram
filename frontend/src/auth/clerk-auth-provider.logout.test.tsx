import { render } from "@testing-library/react";
import { type ReactNode, useContext } from "react";
import { toast } from "sonner";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { type AuthAdapter, AuthContext } from "./auth-context";
import ClerkAuthProvider from "./clerk-auth-provider";

const hoisted = vi.hoisted(() => ({ signOut: vi.fn(), captureError: vi.fn() }));

vi.mock("sonner", () => ({
	toast: { loading: vi.fn(), dismiss: vi.fn(), error: vi.fn() },
}));
vi.mock("@clerk/react", () => ({
	ClerkProvider: (props: { children: ReactNode }) => <>{props.children}</>,
	useAuth: () => ({ isLoaded: true, isSignedIn: true, getToken: vi.fn() }),
	useClerk: () => ({ user: null, signOut: hoisted.signOut, status: "ready" }),
}));
vi.mock("@clerk/themes", () => ({ dark: {} }));
vi.mock("../api/client", () => ({ setTokenGetter: vi.fn() }));
vi.mock("../api/queries", () => ({ useMe: () => ({ data: undefined }) }));
vi.mock("../api/query-client", () => ({ queryClient: {} }));
vi.mock("../config-context", () => ({ useConfig: () => ({ clerkPublishableKey: "pk_test" }) }));
vi.mock("../router", () => ({ getAppRouter: () => ({ navigate: vi.fn() }) }));
vi.mock("../theme/theme-provider", () => ({ useTheme: () => ({ resolved: "light" }) }));
vi.mock("../sentry", () => ({
	captureError: hoisted.captureError,
	sentryReady: Promise.resolve(null),
}));
vi.mock("./use-clear-query-cache-on-user-change", () => ({
	useClearQueryCacheOnUserChange: vi.fn(),
}));
vi.mock("./use-identify-user-on-auth-change", () => ({ useIdentifyUserOnAuthChange: vi.fn() }));
vi.mock("./use-wipe-crdt-on-user-change", () => ({ useWipeCrdtOnUserChange: vi.fn() }));
vi.mock("../i18n/locale-provider", () => ({
	useT: () => ({ renderedLocale: "en", t: (key: string) => key }),
}));
vi.mock("../i18n/vendor-locales", () => ({ clerkLocalizationLoaders: {} }));
// The browser holds the clear-cache response open until it has wiped its HTTP
// cache: seconds on desktop, minutes on Android Chrome. Model that as forever.
vi.mock("./clear-http-cache", () => ({ clearHttpCache: () => new Promise(() => undefined) }));

function mountAdapter(): AuthAdapter {
	const grabbed: { adapter: AuthAdapter | null } = { adapter: null };
	function Grab() {
		grabbed.adapter = useContext(AuthContext);
		return null;
	}
	render(
		<ClerkAuthProvider>
			<Grab />
		</ClerkAuthProvider>,
	);
	if (!grabbed.adapter) {
		throw new Error("AuthContext not provided");
	}
	return grabbed.adapter;
}

describe("Clerk logout", () => {
	beforeEach(() => {
		vi.clearAllMocks();
		hoisted.signOut.mockResolvedValue(undefined);
	});

	// Prod: 13 logout taps over ~3 min from a phone, session still signed in,
	// because logout awaited the cache clear before it ever called clerk.signOut().
	it("signs out without waiting for the HTTP cache clear", async () => {
		mountAdapter().logout();

		await vi.waitFor(() => expect(hoisted.signOut).toHaveBeenCalledTimes(1));
	});

	it("shows Signing out at once, then dismisses it", async () => {
		await mountAdapter().logout();

		expect(toast.loading).toHaveBeenCalledWith("Signing out…", { id: "sign-out" });
		expect(toast.dismiss).toHaveBeenCalledWith("sign-out");
	});

	it("ignores repeat taps while a sign-out is in flight", async () => {
		let finish: () => void = () => undefined;
		hoisted.signOut.mockReturnValue(
			new Promise<void>((resolve) => {
				finish = resolve;
			}),
		);
		const { logout } = mountAdapter();

		const first = logout();
		await logout();
		await logout();
		expect(hoisted.signOut).toHaveBeenCalledTimes(1);

		finish();
		await first;
		// Settled: a later tap (say, after an error) signs out again.
		await logout();
		expect(hoisted.signOut).toHaveBeenCalledTimes(2);
	});

	it("gives up on a hung signOut after 15s: error shown, taps work again", async () => {
		vi.useFakeTimers();
		try {
			hoisted.signOut.mockReturnValue(new Promise(() => undefined));
			const { logout } = mountAdapter();

			const first = logout();
			await vi.advanceTimersByTimeAsync(14_999);
			expect(toast.error).not.toHaveBeenCalled();
			await vi.advanceTimersByTimeAsync(1);
			await first;

			expect(toast.error).toHaveBeenCalledWith("Could not sign out", { id: "sign-out" });
			logout();
			expect(hoisted.signOut).toHaveBeenCalledTimes(2);
		} finally {
			vi.useRealTimers();
		}
	});

	it("shows an error and reports it when Clerk's signOut rejects", async () => {
		const failure = new Error("network");
		hoisted.signOut.mockRejectedValue(failure);

		await expect(mountAdapter().logout()).resolves.toBeUndefined();

		expect(toast.error).toHaveBeenCalledWith("Could not sign out", { id: "sign-out" });
		expect(hoisted.captureError).toHaveBeenCalledWith(failure);
	});
});
