import { render, screen, fireEvent, waitFor, within } from "@testing-library/react";
import { describe, it, expect, vi, beforeEach } from "vitest";
import type { ReactElement } from "react";
import { MemoryRouter } from "react-router";

const restoreMutate = vi.fn();
const purgeMutate = vi.fn();
const deleted = [
	{
		id: 5,
		name: "Old",
		description: null,
		slug: "old",
		is_default: false,
		created_at: "",
		encrypted: true,
		deleted_at: "2026-05-28T00:00:00Z",
		purge_at: "2026-06-27T00:00:00Z",
		note_count: 5,
		attachment_count: 2,
	},
];
let activeCount = 1;
const cap = 1;

vi.mock("@/api/queries", () => ({
	useDeletedVaults: () => ({ data: deleted, isLoading: false }),
	useVaults: () => ({ data: new Array(activeCount).fill({ id: 99 }) }),
	useRestoreVault: () => ({ mutate: restoreMutate, isPending: false }),
	usePurgeVault: () => ({ mutate: purgeMutate, isPending: false }),
	useBillingConfig: () => ({ data: { vaults_cap: cap } }),
}));
vi.mock("sonner", () => ({ toast: { success: vi.fn(), error: vi.fn() } }));

import { DeletedVaultsSection } from "./deleted-vaults-section";

function renderWithRouter(ui: ReactElement, { route = "/settings/vaults" } = {}) {
	return render(<MemoryRouter initialEntries={[route]}>{ui}</MemoryRouter>);
}

describe("DeletedVaultsSection", () => {
	beforeEach(() => {
		vi.clearAllMocks();
		activeCount = 1;
	});

	it("shows counts and the purge date", () => {
		renderWithRouter(<DeletedVaultsSection />);
		const row = within(screen.getByText("Old").closest("tr") as HTMLElement);
		expect(row.getByText("5")).toBeInTheDocument();
		expect(row.getByText("2")).toBeInTheDocument();
		expect(screen.getByText(/purges/i)).toBeInTheDocument();
	});

	it("disables restore when at the cap", () => {
		activeCount = 1;
		renderWithRouter(<DeletedVaultsSection />);
		expect(screen.getByRole("button", { name: /restore/i })).toBeDisabled();
	});

	it("restores when under cap", async () => {
		activeCount = 0;
		renderWithRouter(<DeletedVaultsSection />);
		const btn = screen.getByRole("button", { name: /restore/i });
		expect(btn).toBeEnabled();
		fireEvent.click(btn);
		await waitFor(() => expect(restoreMutate).toHaveBeenCalledWith(5, expect.anything()));
	});

	it("purges permanently when confirmed", async () => {
		window.confirm = vi.fn().mockReturnValue(true);
		renderWithRouter(<DeletedVaultsSection />);
		fireEvent.click(screen.getByRole("button", { name: /permanently delete .*old/i }));
		await waitFor(() => expect(purgeMutate).toHaveBeenCalledWith(5, expect.anything()));
	});

	it("does not purge when confirmation is dismissed", () => {
		window.confirm = vi.fn().mockReturnValue(false);
		renderWithRouter(<DeletedVaultsSection />);
		fireEvent.click(screen.getByRole("button", { name: /permanently delete .*old/i }));
		expect(purgeMutate).not.toHaveBeenCalled();
	});

	it("highlights the row matching ?highlight=<id>", () => {
		renderWithRouter(<DeletedVaultsSection />, { route: "/settings/vaults?highlight=5" });
		expect(screen.getByText("Old").closest("tr")).toHaveAttribute("data-highlighted", "true");
	});
});
