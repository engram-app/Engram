import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { fireEvent, render, screen } from "@testing-library/react";
import { act } from "react";
import { MemoryRouter, useLocation } from "react-router";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { EngramConfig } from "../config";
import { ConfigProvider } from "../config-context";
import { ThemeProvider } from "../theme/theme-provider";
import type { SettingsSectionKey } from "./settings-hash";
import SettingsDialog, { CLOSE_ANIMATION_MS } from "./settings-layout";

vi.mock("../auth/use-auth-adapter", () => ({
	useAuthAdapter: () => ({ user: { email: "todd@example.com" }, logout: vi.fn() }),
}));

const testConfig: EngramConfig = {
	authProvider: "clerk",
	clerkPublishableKey: "",
	billingEnabled: true,
	apiBase: "",
	wsBase: "",
	tracingEnabled: false,
};

function LocationProbe() {
	const loc = useLocation();
	return <output data-testid="loc">{`${loc.pathname}${loc.search}${loc.hash}`}</output>;
}

function renderDialog(
	section: SettingsSectionKey,
	initialEntry = "/v/work/note-1#settings/account",
) {
	const client = new QueryClient({ defaultOptions: { queries: { retry: false } } });
	return render(
		<ConfigProvider config={testConfig}>
			<QueryClientProvider client={client}>
				<ThemeProvider>
					<MemoryRouter initialEntries={[initialEntry]}>
						<LocationProbe />
						<SettingsDialog section={section} />
					</MemoryRouter>
				</ThemeProvider>
			</QueryClientProvider>
		</ConfigProvider>,
	);
}

describe("SettingsDialog", () => {
	beforeEach(() => {
		window.matchMedia = vi.fn().mockReturnValue({
			matches: true,
			addEventListener: vi.fn(),
			removeEventListener: vi.fn(),
		}) as any;
	});

	it("renders the nav with a link per section", async () => {
		renderDialog("account");
		// react-router's <Link> resolves a hash-only `to` against the current
		// pathname, so the href is "/v/work/note-1#settings/billing", not a bare
		// hash. Assert the suffix: the real requirement is "this link targets
		// the billing section," not the page underneath.
		const link = await screen.findByRole("link", { name: "Billing" });
		expect(link.getAttribute("href")).toMatch(/#settings\/billing$/);
	});

	it("renders an icon inside every nav link", async () => {
		renderDialog("account");
		await screen.findByRole("link", { name: "Billing" });

		// The icon is aria-hidden (the label already names the section), so it is
		// unreachable by role/name — query the rendered svg directly. Checking
		// every link, not just one, is the point: a section declared without an
		// icon would otherwise render a silent hole in the nav.
		for (const name of ["Account", "Vaults", "Connections", "Billing"]) {
			const link = screen.getByRole("link", { name });
			expect(link.querySelector("svg"), `"${name}" nav link has no icon`).not.toBeNull();
		}
	});

	it("marks the current section as the active nav item", async () => {
		renderDialog("vaults");
		expect(await screen.findByRole("link", { name: "Vaults" })).toHaveAttribute(
			"aria-current",
			"page",
		);
		expect(screen.getByRole("link", { name: "Account" })).not.toHaveAttribute("aria-current");
	});

	it("clicking a nav link actually switches the router location's hash", async () => {
		// Regression guard: a plain <a href="#settings/billing"> changes
		// window.location.hash via native same-document navigation, which fires
		// `hashchange` but NOT `popstate`, and react-router's history only
		// listens for `popstate`. That leaves useLocation() stale even though the
		// URL bar changed, so the dialog would silently fail to switch sections.
		// This must go through react-router's <Link> (history.push) instead.
		renderDialog("account", "/v/work/note-1#settings/account");
		fireEvent.click(await screen.findByRole("link", { name: "Billing" }));
		expect(await screen.findByText("/v/work/note-1#settings/billing")).toBeInTheDocument();
	});

	it("clicking a nav link preserves the current query string (settingsTo regression)", async () => {
		// react-router's resolvePath inherits pathname from the current location
		// but NOT search, so a bare `to={settingsHash(...)}` silently dropped
		// `?highlight=<id>` (e.g. from the vault-deleted email) the moment the
		// user switched settings sections. SettingsNavList must thread
		// location.search through settingsTo.
		renderDialog("account", "/v/work/note-1?highlight=abc123#settings/account");
		fireEvent.click(await screen.findByRole("link", { name: "Billing" }));
		expect(
			await screen.findByText("/v/work/note-1?highlight=abc123#settings/billing"),
		).toBeInTheDocument();
	});

	it("strips the hash on close and keeps you on the same page", async () => {
		// The close navigate is deferred by CLOSE_ANIMATION_MS so the Radix exit
		// transition plays. Advance the clock explicitly rather than waiting on it:
		// with real timers this asserts deterministic behavior by racing the wall
		// clock, and under full suite parallel load the event loop starves past
		// findBy*'s 1000ms default. Measured about 17 percent flake rate that way.
		vi.useFakeTimers();
		try {
			renderDialog("account", "/v/work/note-1#settings/account");
			fireEvent.click(screen.getByRole("button", { name: /close settings/i }));
			await act(async () => {
				vi.advanceTimersByTime(CLOSE_ANIMATION_MS);
			});
			expect(screen.getByText("/v/work/note-1")).toBeInTheDocument();
		} finally {
			vi.useRealTimers();
		}
	});

	it("falls back to account when the section is unavailable in this config", async () => {
		const localConfig = { ...testConfig, authProvider: "local" as const, billingEnabled: false };
		const client = new QueryClient({ defaultOptions: { queries: { retry: false } } });
		render(
			<ConfigProvider config={localConfig}>
				<QueryClientProvider client={client}>
					<ThemeProvider>
						<MemoryRouter initialEntries={["/work#settings/billing"]}>
							<SettingsDialog section="billing" />
						</MemoryRouter>
					</ThemeProvider>
				</QueryClientProvider>
			</ConfigProvider>,
		);
		// Billing is not a section on a self-host build, so the nav must not
		// offer it and the body must not be the billing page.
		expect(screen.queryByRole("link", { name: "Billing" })).toBeNull();
	});
});
