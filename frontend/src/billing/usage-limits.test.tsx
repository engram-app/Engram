import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { render, screen, waitFor } from "@testing-library/react";
import type { ReactNode } from "react";
import { MemoryRouter } from "react-router";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { BillingUsage } from "../api/queries";
import { UsageBanner, UsagePanel } from "./usage-limits";

const { get } = vi.hoisted(() => ({ get: vi.fn() }));
vi.mock("../api/client", () => ({
	api: { get, post: vi.fn(), patch: vi.fn(), del: vi.fn() },
	setTokenGetter: vi.fn(),
}));

let qc: QueryClient;

beforeEach(() => {
	get.mockReset();
	qc = new QueryClient({ defaultOptions: { queries: { retry: false } } });
});

afterEach(() => qc.clear());

function Wrapper({ children }: { children: ReactNode }) {
	return (
		<MemoryRouter>
			<QueryClientProvider client={qc}>{children}</QueryClientProvider>
		</MemoryRouter>
	);
}

// `/billing/config` reports which limit set is enforced; the banner and the
// panel exist only with the v5 one (INDEX_BUDGET_ENABLED), as on main
// before it.
function serve(body: BillingUsage, limits: "v5" | "legacy" = "v5") {
	get.mockImplementation((path: string) =>
		Promise.resolve(path === "/billing/config" ? { plan_limits: limits } : body),
	);
}

function usage(over: Partial<BillingUsage["usage"]> = {}): BillingUsage {
	return {
		tier: "free",
		usage: {
			notes: { used: 100, limit: 2000 },
			index_points: { used: 600, limit: 12_000 },
			floor_notes: 0,
			...over,
		},
	};
}

describe("UsagePanel", () => {
	it("shows notes and search passages against their caps", async () => {
		serve(usage());
		render(<UsagePanel />, { wrapper: Wrapper });

		expect(await screen.findByText("Notes: 100 of 2000")).toBeTruthy();
		expect(screen.getByText("Full search: 600 of 12000 passages")).toBeTruthy();
	});

	it("hides the passages row while there is no passages limit", async () => {
		serve(usage({ index_points: { used: 600, limit: null } }));
		render(<UsagePanel />, { wrapper: Wrapper });

		expect(await screen.findByText("Notes: 100 of 2000")).toBeTruthy();
		expect(screen.queryByText(/passages/)).toBeNull();
	});

	it("says how many notes are keyword-only", async () => {
		serve(usage({ floor_notes: 3 }));
		render(<UsagePanel />, { wrapper: Wrapper });

		expect(
			await screen.findByText("3 notes are found by keyword only (exact words, not meaning)."),
		).toBeTruthy();
	});
});

describe("UsageBanner", () => {
	it("is silent well under every cap", async () => {
		serve(usage());
		const { container } = render(<UsageBanner />, { wrapper: Wrapper });
		await screen.findByTestId("usage-banner-ready");
		expect(container.querySelector("aside")).toBeNull();
	});

	it("warns at 80% of the notes cap and says what happens at it", async () => {
		serve(usage({ notes: { used: 1700, limit: 2000 } }));
		render(<UsageBanner />, { wrapper: Wrapper });

		expect(
			await screen.findByText(
				"You have used 85% of your 2000 notes. At 2000, new notes stop syncing until you upgrade or remove some.",
			),
		).toBeTruthy();
	});

	it("explains keyword-only search when the passages are full", async () => {
		serve(usage({ index_points: { used: 12_000, limit: 12_000 }, floor_notes: 4 }));
		render(<UsageBanner />, { wrapper: Wrapper });

		expect(
			await screen.findByText(
				"Your full-search passages are used up. 4 older notes are found by keyword only (exact words, not meaning). Nothing is deleted. Upgrade to bring full search back.",
			),
		).toBeTruthy();
	});
});

describe("with the legacy limits (INDEX_BUDGET_ENABLED off)", () => {
	it("renders neither banner nor panel, and never asks for usage", async () => {
		serve(usage({ notes: { used: 2900, limit: 3000 } }), "legacy");
		const { container } = render(
			<>
				<UsageBanner />
				<UsagePanel />
			</>,
			{ wrapper: Wrapper },
		);

		await waitFor(() => expect(get).toHaveBeenCalledWith("/billing/config"));
		expect(container.innerHTML).toBe("");
		expect(get).not.toHaveBeenCalledWith("/billing/usage");
	});
});
