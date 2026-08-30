import { render, screen } from "@testing-library/react";
import { matchRoutes, RouterProvider } from "react-router";
import { describe, expect, it, vi } from "vitest";
import type { EngramConfig } from "./config";
import { createAppRouter } from "./router";
import { VAULT_PREFIX } from "./routes";
import spaRoutes from "./spa-routes.json" with { type: "json" };

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
	// These wait on a CHAIN of two dynamic imports behind two Suspense
	// boundaries: SettingsOverlayHost is lazy() in router.tsx, and the dialog
	// is lazy() again inside the host. There is no fixed delay to advance, so
	// fake timers cannot help; the only correct bound is one generous enough
	// to survive suite contention. findBy*'s 1000ms default is arbitrary and
	// too tight: this test was observed timing out under parallel load while
	// taking 6.96s in isolation.
	it("overlays the settings dialog atop /link (outside the app shell)", async () => {
		renderAt("/link#settings/billing");
		expect(
			await screen.findByTestId("device-link", undefined, { timeout: 15_000 }),
		).toBeInTheDocument();
		expect(await screen.findByTestId("dialog", undefined, { timeout: 15_000 })).toHaveTextContent(
			"section:billing",
		);
	});

	it("overlays the settings dialog atop /oauth/consent (outside the app shell)", async () => {
		renderAt("/oauth/consent#settings/billing");
		expect(
			await screen.findByTestId("oauth-consent", undefined, { timeout: 15_000 }),
		).toBeInTheDocument();
		expect(await screen.findByTestId("dialog", undefined, { timeout: 15_000 })).toHaveTextContent(
			"section:billing",
		);
	});
});

interface RouteLike {
	path?: string;
	children?: RouteLike[];
}

/** Flattens the router config to full paths, resolving RR's relative children. */
function fullPaths(routes: RouteLike[], parent = ""): string[] {
	return routes.flatMap((r) => {
		const self = r.path?.startsWith("/")
			? r.path
			: r.path
				? `${parent}/${r.path}`.replace(/\/+/gu, "/")
				: parent;
		const here = r.path ? [self] : [];
		return [...here, ...fullPaths(r.children ?? [], self)];
	});
}

describe("createAppRouter - vault routes are namespaced under /v", () => {
	const paths = fullPaths(createAppRouter(config).routes as RouteLike[]);

	it("mounts the vault subtree at /v/:slug", () => {
		expect(paths).toContain("/v/:slug");
		expect(paths).toContain("/v/:slug/:itemId");
	});

	// THE regression guard for this whole refactor. Vault slugs are derived
	// from user-supplied names, so a dynamic segment at the root makes every
	// top-level route ambiguous: a vault named "link" is shadowed by /link,
	// and a typo'd /api/notez matches /:slug/:id. That ambiguity is what the
	// deleted reserved-slug list existed to paper over, and it silently
	// widened every time someone added a top-level route.
	//
	// Fails loudly if anyone re-introduces a root-level `/:param` route.
	// The bare catch-all "*" is exempt: it is the 404 handler and RR ranks it
	// last, so it shadows nothing.
	it("has no dynamic segment at the root", () => {
		const rootDynamic = paths.filter((p) => /^\/:/u.test(p));
		expect(rootDynamic).toEqual([]);
	});
});

describe("createAppRouter - hard-loadable route parity with Phoenix", () => {
	// The twin of test/engram_web/spa_route_parity_test.exs. Both read
	// src/spa-routes.json: this side proves the React router serves each
	// sample, that side proves Phoenix does. A route present on only one side
	// is exactly how /reset-password broke — it had a React route and no
	// Phoenix entry, surviving only on a root wildcard that was later
	// deleted, and every test stayed green because none crossed the boundary.
	const routes = createAppRouter(config).routes as RouteLike[];
	const samples: string[] = spaRoutes.hardLoadable;

	it.each(samples)("%s matches a real React route", (url) => {
		const matched = matchRoutes(routes as never, url);
		expect(matched, `${url} matched nothing`).not.toBeNull();
		// Matching ONLY the "*" catch-all is an in-app 404, not a served
		// route — that is a failure, not a pass.
		expect(
			matched?.some((m) => m.route.path !== undefined && m.route.path !== "*"),
			`${url} fell through to the catch-all`,
		).toBe(true);
	});

	it("pins VAULT_PREFIX to the shared manifest", () => {
		// Changing VAULT_PREFIX without updating the manifest (and so the
		// Phoenix side) would leave TS green while every hard load 404s.
		expect(VAULT_PREFIX).toBe(spaRoutes.vaultPrefix);
	});

	it("every STATIC top-level React route has a sample", () => {
		// Catches the /reset-password shape directly: add a static route to
		// router.tsx, forget the manifest, and this names the missing path.
		// Dynamic paths are excluded (no verbatim comparison possible) — the
		// it.each above covers those via explicit samples.
		const staticPaths = fullPaths(routes).filter(
			(p) => p.startsWith("/") && !p.includes(":") && !p.includes("*"),
		);
		const devOnly: string[] = spaRoutes.devOnly;
		const missing = staticPaths.filter((p) => !(samples.includes(p) || devOnly.includes(p)));
		expect(missing).toEqual([]);
	});
});
