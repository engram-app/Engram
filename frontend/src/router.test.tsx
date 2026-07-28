import { render, screen } from "@testing-library/react";
import { RouterProvider } from "react-router";
import { describe, expect, it, vi } from "vitest";
import type { EngramConfig } from "./config";
import { createAppRouter } from "./router";

// AuthGuard's only dependency. Stub it signed-in so the route tree past it
// renders instead of redirecting to /sign-in.
vi.mock("./auth/use-auth-adapter", () => ({
	useAuthAdapter: () => ({ isLoaded: true, isSignedIn: true }),
}));

// The dialog pulls the whole settings surface (Clerk hooks, billing, admin);
// stub it the same way settings-overlay-host.test.tsx does, so this file
// only proves the ROUTE WIRING, not settings' internals.
vi.mock("./settings/settings-layout", () => ({
	default: ({ section }: { section: string }) => <p data-testid="dialog">section:{section}</p>,
}));

// /link and /oauth/consent each have their own dedicated test file covering
// behavior; both pull in react-query + API calls this file has no reason to
// wire up. Stub them to a marker so we only assert THEY mounted at all.
vi.mock("./device/device-link-page", () => ({
	default: () => <p data-testid="device-link">device link page</p>,
}));
vi.mock("./oauth/oauth-authorize-page", () => ({
	default: () => <p data-testid="oauth-consent">oauth consent page</p>,
}));

const config: EngramConfig = {
	authProvider: "local",
	clerkPublishableKey: "",
	billingEnabled: false,
	clerkWaitlistMode: false,
	apiBase: "",
	wsBase: "",
	tracingEnabled: false,
};

// createAppRouter builds a createBrowserRouter, which reads its initial
// location off the real window at construction time. pushState first, then
// build; mirrors createMemoryRouter's initialEntries without reshaping the
// production router to accept injected history.
function renderAt(entry: string) {
	window.history.pushState({}, "", entry);
	return render(<RouterProvider router={createAppRouter(config)} />);
}

describe("createAppRouter - settings overlay mount point", () => {
	// The overlay must sit ABOVE AuthGuard's other children, not inside
	// AppLayout, because /link and /oauth/consent render outside the app
	// shell. If SettingsOverlayHost were moved inside AppLayout, these two
	// routes would never see it and #settings/billing would be a silent
	// no-op on both. That regression is exactly what this test guards.
	it("overlays the settings dialog atop /link (outside the app shell)", async () => {
		renderAt("/link#settings/billing");
		expect(await screen.findByTestId("device-link")).toBeInTheDocument();
		expect(await screen.findByTestId("dialog")).toHaveTextContent("section:billing");
	});

	it("overlays the settings dialog atop /oauth/consent (outside the app shell)", async () => {
		renderAt("/oauth/consent#settings/billing");
		expect(await screen.findByTestId("oauth-consent")).toBeInTheDocument();
		expect(await screen.findByTestId("dialog")).toHaveTextContent("section:billing");
	});
});
