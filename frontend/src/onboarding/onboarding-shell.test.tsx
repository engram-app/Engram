import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import type { ReactElement } from "react";
import { MemoryRouter, Outlet, Route, Routes } from "react-router";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { setActiveVaultId } from "../api/active-vault";
import type { Vault } from "../api/queries";
import VaultRoute from "../viewer/vault-route";
import { OnboardingShell } from "./onboarding-shell";

// NotFoundPage (rendered if VaultRoute 404s) pulls in ThemeToggle via
// AuthShell, which needs a ThemeProvider we are not wiring up here. Same
// mock as src/viewer/vault-route.test.tsx.
vi.mock("../theme/theme-toggle", () => ({
	default: () => <button type="button">theme</button>,
}));

function renderShell(ui: ReactElement) {
	const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } });
	return render(
		<QueryClientProvider client={qc}>
			<MemoryRouter>{ui}</MemoryRouter>
		</QueryClientProvider>,
	);
}

const mockRecord = vi.fn(() => Promise.resolve());
// Mutable so the "real router" describe block below can simulate a user who
// already has a vault (vaultCount: 1), skipping the first-vault modal that
// would otherwise aria-hide the checklist behind it.
let mockVaultCount = 0;
vi.mock("./use-onboarding-actions", () => ({
	useOnboardingActions: () => ({
		isLoading: false,
		get vaultCount() {
			return mockVaultCount;
		},
		has: () => false,
		record: mockRecord,
		recordAsync: mockRecord,
	}),
}));

// Driver.js touches the DOM in ways jsdom doesn't fully model; the TourController
// behaviour is exercised in its own test file. Stub it to a no-op here so the
// shell's flow can be asserted in isolation.
vi.mock("./tour/controller", () => ({
	TourController: () => null,
}));

// The checklist widget has its own dedicated suite — stub here so this test
// stays focused on the shell's modal/orchestration behaviour. The stub still
// exposes `onStartTour` via a real button so the router test below can drive
// tour entry the same way a user click does.
vi.mock("./checklist-widget", () => ({
	ChecklistWidget: ({ onStartTour }: { onStartTour: () => void }) => (
		<div data-testid="checklist-widget">
			<button type="button" onClick={onStartTour}>
				Start tour
			</button>
		</div>
	),
}));

describe("OnboardingShell", () => {
	beforeEach(() => {
		mockRecord.mockClear();
		mockVaultCount = 0;
	});

	it("renders the vault modal when vault_count is zero", () => {
		renderShell(
			<OnboardingShell>
				<p>dashboard</p>
			</OnboardingShell>,
		);
		expect(screen.getByRole("heading", { name: /first vault/iu })).toBeInTheDocument();
	});

	it("mounts the checklist widget alongside dashboard content", () => {
		renderShell(
			<OnboardingShell>
				<p>dashboard</p>
			</OnboardingShell>,
		);
		expect(screen.getByText("dashboard")).toBeInTheDocument();
		expect(screen.getByTestId("checklist-widget")).toBeInTheDocument();
	});
});

// Regression test for the tour-from-a-real-vault-URL 404: demo mode makes
// useVaults() return ONLY the two synthetic demo vaults, so a real slug like
// `/work` stops resolving in VaultRoute once the tour activates. Drives tour
// entry through an actual router (VaultRoute + real useVaults/useDemoVault),
// which no other test does.
describe("starting the tour from a real vault URL", () => {
	const vaults: Vault[] = [
		{
			id: "vault-1",
			name: "Work",
			slug: "work",
			description: null,
			is_default: true,
			created_at: new Date(0).toISOString(),
			encrypted: false,
			encryption_status: "none",
			encrypted_at: null,
			decrypt_requested_at: null,
			last_toggle_at: null,
			cooldown_days: null,
		},
	];

	beforeEach(() => {
		// A user already has a vault at this URL, so skip the first-vault modal,
		// which otherwise aria-hides the checklist button behind it.
		mockVaultCount = 1;
		setActiveVaultId(null);
		globalThis.fetch = vi.fn((input: RequestInfo | URL) => {
			const url = String(input);
			if (url.includes("/demo-vault.json")) {
				return Promise.resolve({
					ok: true,
					json: () =>
						Promise.resolve({
							vault: { id: "demo-vault", name: "Demo Vault" },
							folders: [],
							notes: [],
						}),
				} as Response);
			}
			if (url.includes("/api/vaults")) {
				return Promise.resolve({ ok: true, json: () => Promise.resolve({ vaults }) } as Response);
			}
			return Promise.reject(new Error(`unexpected fetch in test: ${url}`));
		}) as unknown as typeof fetch;
	});

	function renderAtWork() {
		const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } });
		return render(
			<QueryClientProvider client={qc}>
				<MemoryRouter initialEntries={["/work"]}>
					<Routes>
						<Route element={<OnboardingShell>{<Outlet />}</OnboardingShell>}>
							<Route path="/" element={<p>home</p>} />
							<Route path="/:slug" element={<VaultRoute />}>
								<Route index element={<p>vault dashboard</p>} />
							</Route>
						</Route>
					</Routes>
				</MemoryRouter>
			</QueryClientProvider>,
		);
	}

	it("does not land on the 404 page after clicking Take the tour", async () => {
		renderAtWork();
		expect(await screen.findByText("vault dashboard")).toBeInTheDocument();

		fireEvent.click(screen.getByRole("button", { name: /start tour/iu }));

		await waitFor(() => {
			expect(screen.getByText("home")).toBeInTheDocument();
		});
		expect(screen.queryByText(/page not found/iu)).toBeNull();
	});
});
