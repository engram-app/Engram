import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { render, screen } from "@testing-library/react";
import type { ReactElement } from "react";
import { MemoryRouter } from "react-router";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { OnboardingShell } from "./onboarding-shell";

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
