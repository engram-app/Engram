import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { fireEvent, render, screen } from "@testing-library/react";
import type React from "react";
import { MemoryRouter } from "react-router";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { BillingStatus, OnboardingStatus } from "../api/queries";

const mutateAsync = vi.fn().mockResolvedValue({});

let onboardingStatus: { data: OnboardingStatus | undefined; isLoading: boolean } = {
	data: {
		enabled: true,
		next_step: "tools",
		steps: [],
		actions: [],
		vault_count: 0,
		profile: { uses_obsidian: false, tools: [] },
	} as OnboardingStatus,
	isLoading: false,
};

let billingStatus: { data: Partial<BillingStatus> | undefined; isLoading: boolean } = {
	data: { tier: "free", active: false } as Partial<BillingStatus>,
	isLoading: false,
};

// SaaS by default; self-host flips this false (no billing, unlimited connections).
let billingEnabled = true;

vi.mock("../api/queries", async () => {
	const actual = await vi.importActual<typeof import("../api/queries")>("../api/queries");
	return {
		...actual,
		useOnboardingStatus: () => onboardingStatus,
		useSetOnboardingProfile: () => ({
			mutateAsync,
			isPending: false,
			isError: false,
		}),
		useBillingStatus: () => billingStatus,
	};
});

vi.mock("../config-context", async () => {
	const actual = await vi.importActual<typeof import("../config-context")>("../config-context");
	return {
		...actual,
		useConfig: () => ({ billingEnabled }) as ReturnType<typeof actual.useConfig>,
	};
});

// Import after mocks
import OnboardToolsPage from "./onboard-tools-page";

function wrap(ui: React.ReactNode) {
	const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } });
	return (
		<QueryClientProvider client={qc}>
			<MemoryRouter>{ui}</MemoryRouter>
		</QueryClientProvider>
	);
}

beforeEach(() => {
	mutateAsync.mockClear();
	onboardingStatus = {
		data: {
			enabled: true,
			next_step: "tools",
			steps: [],
			actions: [],
			vault_count: 0,
			profile: { uses_obsidian: false, tools: [] },
		} as OnboardingStatus,
		isLoading: false,
	};
	billingStatus = {
		data: { tier: "free", active: false } as Partial<BillingStatus>,
		isLoading: false,
	};
	billingEnabled = true;
});

describe("OnboardToolsPage — Free tier", () => {
	it("shows the Free-tier banner with an Upgrade link to /onboard/billing", () => {
		render(wrap(<OnboardToolsPage />));

		expect(screen.getByText(/free tier.*pick 1 to start/iu)).toBeInTheDocument();
		const link = screen.getByRole("link", { name: /upgrade/iu });
		expect(link).toHaveAttribute("href", "/onboard/billing");
	});

	it("single-select: picking a second tool deselects the first", () => {
		render(wrap(<OnboardToolsPage />));

		// Click Claude first.
		const claude = screen.getByLabelText(/^Claude$/iu);
		fireEvent.click(claude);
		expect(claude).toHaveAttribute("data-state", "checked");

		// Then click Cursor — Claude should deselect.
		const cursor = screen.getByLabelText(/^Cursor$/iu);
		fireEvent.click(cursor);
		expect(cursor).toHaveAttribute("data-state", "checked");
		expect(claude).toHaveAttribute("data-state", "unchecked");
	});
});

describe("OnboardToolsPage — Self-host (billing disabled)", () => {
	beforeEach(() => {
		// Self-host: no billing. tier is still "free" (no subscription) but
		// connections are unlimited, so the step must not gate to a single pick.
		billingEnabled = false;
		billingStatus = {
			data: { tier: "free", active: false } as Partial<BillingStatus>,
			isLoading: false,
		};
	});

	it("does not render the Free-tier single-select banner", () => {
		render(wrap(<OnboardToolsPage />));
		expect(screen.queryByText(/free tier.*pick 1 to start/iu)).toBeNull();
	});

	it("allows multi-select (no auto-deselect)", () => {
		render(wrap(<OnboardToolsPage />));

		const claude = screen.getByLabelText(/^Claude$/iu);
		fireEvent.click(claude);
		const cursor = screen.getByLabelText(/^Cursor$/iu);
		fireEvent.click(cursor);

		expect(claude).toHaveAttribute("data-state", "checked");
		expect(cursor).toHaveAttribute("data-state", "checked");
	});
});

describe("OnboardToolsPage — Paid tier", () => {
	beforeEach(() => {
		billingStatus = {
			data: { tier: "pro", active: true } as Partial<BillingStatus>,
			isLoading: false,
		};
	});

	it("does not render the Free banner", () => {
		render(wrap(<OnboardToolsPage />));
		expect(screen.queryByText(/free tier.*pick 1 to start/iu)).toBeNull();
	});

	it("allows multi-select (no auto-deselect)", () => {
		render(wrap(<OnboardToolsPage />));

		const claude = screen.getByLabelText(/^Claude$/iu);
		fireEvent.click(claude);
		const cursor = screen.getByLabelText(/^Cursor$/iu);
		fireEvent.click(cursor);

		expect(claude).toHaveAttribute("data-state", "checked");
		expect(cursor).toHaveAttribute("data-state", "checked");
	});
});
