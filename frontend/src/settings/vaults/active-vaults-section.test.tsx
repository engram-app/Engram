import { render, screen, fireEvent, waitFor, within } from "@testing-library/react";
import { describe, it, expect, vi, beforeEach } from "vitest";

const deleteMutate = vi.fn();
const updateMutate = vi.fn();
const vaults = [
	{
		id: 1,
		name: "Work",
		description: null,
		slug: "work",
		is_default: true,
		created_at: "",
		encrypted: true,
		encryption_status: "none",
		encrypted_at: null,
		decrypt_requested_at: null,
		last_toggle_at: null,
		cooldown_days: null,
		note_count: 12,
		attachment_count: 3,
	},
	{
		id: 2,
		name: "Personal",
		description: null,
		slug: "personal",
		is_default: false,
		created_at: "",
		encrypted: true,
		encryption_status: "none",
		encrypted_at: null,
		decrypt_requested_at: null,
		last_toggle_at: null,
		cooldown_days: null,
		note_count: 0,
		attachment_count: 0,
	},
];

const billingState = { current: { caps: { vaults: null } } as { caps: { vaults: number | null } } };

vi.mock("@/api/queries", () => ({
	useVaults: () => ({ data: vaults, isLoading: false }),
	useDeleteVault: () => ({ mutate: deleteMutate, isPending: false }),
	useUpdateVault: () => ({ mutate: updateMutate, isPending: false }),
	useBillingStatus: () => ({ data: billingState.current }),
}));
vi.mock("sonner", () => ({ toast: { success: vi.fn(), error: vi.fn() } }));

import { ActiveVaultsSection } from "./active-vaults-section";

describe("ActiveVaultsSection", () => {
	beforeEach(() => {
		vi.clearAllMocks();
		billingState.current = { caps: { vaults: null } };
	});

	it("lists vaults with counts and marks the default", () => {
		render(<ActiveVaultsSection />);
		const workRow = within(screen.getByText("Work").closest("tr") as HTMLElement);
		expect(workRow.getByText("12")).toBeInTheDocument();
		expect(workRow.getByText("3")).toBeInTheDocument();
		expect(screen.getByText("Default")).toBeInTheDocument();
	});

	it("opens the delete dialog and deletes after typing the name", async () => {
		render(<ActiveVaultsSection />);
		const workRow = within(screen.getByText("Work").closest("tr") as HTMLElement);
		fireEvent.click(workRow.getByRole("button", { name: /delete .*work/i }));
		const confirmBtn = screen.getByRole("button", { name: /delete vault/i });
		expect(confirmBtn).toBeDisabled();
		fireEvent.change(screen.getByLabelText(/type .*work.* to confirm/i), {
			target: { value: "Work" },
		});
		fireEvent.click(confirmBtn);
		await waitFor(() => expect(deleteMutate).toHaveBeenCalledWith(1, expect.anything()));
	});

	it("sets a non-default vault as default", () => {
		render(<ActiveVaultsSection />);
		fireEvent.click(screen.getByRole("button", { name: /set .*personal.* as default/i }));
		expect(updateMutate).toHaveBeenCalledWith({ id: 2, is_default: true }, expect.anything());
	});

	it("shows the upgrade banner and hides New vault when at Free cap", () => {
		// 2 vaults in setup; pin Free cap=1 so we're over.
		billingState.current = { caps: { vaults: 1 } };
		render(<ActiveVaultsSection />);
		expect(screen.queryByRole("button", { name: /new vault/i })).not.toBeInTheDocument();
		expect(screen.getByText(/Free plan allows 1 vault/i)).toBeInTheDocument();
		expect(screen.getByRole("link", { name: /upgrade/i })).toBeInTheDocument();
		// Counter in the section title surfaces N / cap.
		expect(screen.getByText(/Vaults \(2 \/ 1\)/i)).toBeInTheDocument();
	});

	it("keeps New vault enabled when below cap", () => {
		billingState.current = { caps: { vaults: 5 } };
		render(<ActiveVaultsSection />);
		expect(screen.getByRole("button", { name: /new vault/i })).toBeInTheDocument();
		expect(screen.queryByText(/Free plan allows/i)).not.toBeInTheDocument();
		expect(screen.getByText(/Vaults \(2 \/ 5\)/i)).toBeInTheDocument();
	});
});
