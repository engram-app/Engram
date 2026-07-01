import { describe, expect, it, vi, beforeEach } from "vitest";
import { render, screen } from "@testing-library/react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import type { ReactElement } from "react";
import { MemoryRouter } from "react-router";
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
vi.mock("./use-onboarding-actions", () => ({
	useOnboardingActions: () => ({
		isLoading: false,
		vaultCount: 0,
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
// stays focused on the shell's modal/orchestration behaviour.
vi.mock("./checklist-widget", () => ({
	ChecklistWidget: () => <div data-testid="checklist-widget" />,
}));

describe("OnboardingShell", () => {
	beforeEach(() => {
		mockRecord.mockClear();
	});

	it("renders the vault modal when vault_count is zero", () => {
		renderShell(
			<OnboardingShell>
				<p>dashboard</p>
			</OnboardingShell>,
		);
		expect(screen.getByRole("heading", { name: /first vault/i })).toBeInTheDocument();
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
