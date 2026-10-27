import { render } from "@testing-library/react";
import { type ReactNode, useContext } from "react";
import { expect, it, vi } from "vitest";
import { type AuthAdapter, AuthContext } from "./auth-context";
import ClerkAuthProvider from "./clerk-auth-provider";

const hoisted = vi.hoisted(() => ({ signOut: vi.fn().mockResolvedValue(undefined) }));

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
vi.mock("../sentry", () => ({ captureError: vi.fn(), sentryReady: Promise.resolve(null) }));
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

// Prod: 13 logout taps over ~3 min from a phone, session still signed in,
// because logout awaited the cache clear before it ever called clerk.signOut().
it("signs out without waiting for the HTTP cache clear", async () => {
	let adapter: AuthAdapter | null = null;
	function Grab() {
		adapter = useContext(AuthContext);
		return null;
	}
	render(
		<ClerkAuthProvider>
			<Grab />
		</ClerkAuthProvider>,
	);

	void adapter?.logout();

	await vi.waitFor(() => expect(hoisted.signOut).toHaveBeenCalledTimes(1));
});
