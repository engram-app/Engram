import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { fireEvent, render, screen } from "@testing-library/react";
import type { ReactElement } from "react";
import { MemoryRouter } from "react-router";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { track } from "../analytics/track";
import { OnboardingShell } from "./onboarding-shell";

vi.mock("../analytics/track", () => ({ track: vi.fn() }));
const mockTrack = vi.mocked(track);

const DEMO_VAULT = { id: "01923a4b-cdef-7000-89ab-cdef01234567", name: "My Vault" };

vi.mock("../components/vault-create-form", () => ({
	VaultCreateForm: ({ onCreated }: { onCreated: (vault: typeof DEMO_VAULT) => void }) => (
		<button type="button" onClick={() => onCreated(DEMO_VAULT)}>
			fake-create
		</button>
	),
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
let mockVaultCount = 0;
vi.mock("./use-onboarding-actions", () => ({
	useOnboardingActions: () => ({
		isLoading: false,
		get vaultCount() {
			return mockVaultCount;
		},
		has: () => false,
		recordAsync: mockRecord,
	}),
}));

// The checklist widget has its own dedicated suite — stub here so this test
// stays focused on the shell's modal/orchestration behaviour.
vi.mock("./checklist-widget", () => ({
	ChecklistWidget: () => <div data-testid="checklist-widget" />,
}));

describe("OnboardingShell", () => {
	beforeEach(() => {
		mockRecord.mockClear();
		mockVaultCount = 0;
		mockTrack.mockClear();
	});

	it("renders the vault modal when vault_count is zero", () => {
		renderShell(
			<OnboardingShell>
				<p>dashboard</p>
			</OnboardingShell>,
		);
		expect(screen.getByRole("heading", { name: /first vault/iu })).toBeInTheDocument();
	});

	// Covers the recovery path (a done user with 0 vaults, e.g. after a
	// deletion) — the same milestone the wizard's own vault step reports,
	// reached from a different, later trigger.
	it("emits onboarding_step_completed for the vault step when the first vault is created", () => {
		renderShell(
			<OnboardingShell>
				<p>dashboard</p>
			</OnboardingShell>,
		);
		fireEvent.click(screen.getByText("fake-create"));

		expect(mockTrack).toHaveBeenCalledWith(
			"onboarding_step_completed",
			expect.objectContaining({ step: "vault", vault_id: DEMO_VAULT.id }),
		);
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
