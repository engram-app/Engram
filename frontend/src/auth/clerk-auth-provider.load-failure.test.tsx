import { fireEvent, render, screen } from "@testing-library/react";
import type { ReactNode } from "react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import ClerkAuthProvider from "./clerk-auth-provider";

const hoisted = vi.hoisted(() => ({
	status: "loading" as string,
	captureMessage: vi.fn(),
}));

vi.mock("@clerk/react", () => ({
	ClerkProvider: (props: { children: ReactNode }) => <>{props.children}</>,
	useAuth: () => ({ isLoaded: false, isSignedIn: undefined, getToken: vi.fn() }),
	useClerk: () => ({ user: null, signOut: vi.fn(), status: hoisted.status }),
}));
vi.mock("@clerk/themes", () => ({ dark: {} }));
vi.mock("../api/client", () => ({ setTokenGetter: vi.fn() }));
vi.mock("../api/queries", () => ({ useMe: () => ({ data: undefined }) }));
vi.mock("../api/query-client", () => ({ queryClient: {} }));
vi.mock("../config-context", () => ({ useConfig: () => ({ clerkPublishableKey: "pk_test" }) }));
vi.mock("../router", () => ({ getAppRouter: () => ({ navigate: vi.fn() }) }));
vi.mock("../theme/theme-provider", () => ({ useTheme: () => ({ resolved: "light" }) }));
vi.mock("../sentry", () => ({
	captureError: vi.fn(),
	sentryReady: Promise.resolve({ captureMessage: hoisted.captureMessage }),
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

function mount() {
	return render(
		<ClerkAuthProvider>
			<p>child</p>
		</ClerkAuthProvider>,
	);
}

// ENGRAM-FRONTEND-A: clerk.engram.page's script failed to load on /oauth/:seg.
// Clerk flips its status to "error" and never loads, so every auth-gated page
// waited forever on a spinner while the SDK's rejection escaped unhandled.
describe("ClerkAuthProvider when Clerk JS fails to load", () => {
	beforeEach(() => {
		hoisted.captureMessage.mockReset();
	});

	it("renders the app while Clerk loads", () => {
		hoisted.status = "loading";
		mount();
		expect(screen.getByText("child")).toBeInTheDocument();
		expect(screen.queryByRole("button", { name: "Reload" })).toBeNull();
	});

	it("shows a reloadable sign-in failure instead of the app", async () => {
		hoisted.status = "error";
		const reload = vi.fn();
		vi.spyOn(window, "location", "get").mockReturnValue({ ...window.location, reload });
		mount();

		expect(screen.getByRole("heading", { name: "Couldn't load sign-in" })).toBeInTheDocument();
		expect(screen.queryByText("child")).toBeNull();
		fireEvent.click(screen.getByRole("button", { name: "Reload" }));
		expect(reload).toHaveBeenCalledTimes(1);
		vi.restoreAllMocks();
	});

	it("reports the failure once, as a handled warning", async () => {
		hoisted.status = "error";
		const view = mount();
		view.rerender(
			<ClerkAuthProvider>
				<p>child</p>
			</ClerkAuthProvider>,
		);

		await vi.waitFor(() => expect(hoisted.captureMessage).toHaveBeenCalledTimes(1));
		expect(hoisted.captureMessage).toHaveBeenCalledWith("clerk_js_load_failed", "warning");
	});
});
