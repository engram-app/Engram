import { render, screen, fireEvent, waitFor } from "@testing-library/react";
import { describe, it, expect, vi, beforeEach } from "vitest";

const deleteMutate = vi.fn();
vi.mock("@/api/queries", () => ({
	useDeleteVault: () => ({ mutate: deleteMutate, isPending: false }),
}));
vi.mock("sonner", () => ({ toast: { success: vi.fn(), error: vi.fn() } }));

import { DeleteVaultDialog } from "./delete-vault-dialog";

const vault = {
	id: "7",
	name: "Work",
	description: null,
	slug: "work",
	is_default: false,
	created_at: "",
	encrypted: true,
	encryption_status: "encrypted" as const,
	encrypted_at: null,
	decrypt_requested_at: null,
	last_toggle_at: null,
	cooldown_days: null,
	note_count: 142,
	attachment_count: 3,
};

describe("DeleteVaultDialog", () => {
	beforeEach(() => vi.clearAllMocks());

	it("educates about the 30-day window and remote-only scope", () => {
		render(<DeleteVaultDialog vault={vault} open onOpenChange={() => {}} />);
		expect(screen.getByText(/30 days/i)).toBeInTheDocument();
		expect(screen.getByText(/synced to your devices/i)).toBeInTheDocument();
		expect(screen.getByText(/142/)).toBeInTheDocument();
	});

	it("keeps the delete button disabled until the name is typed", async () => {
		render(<DeleteVaultDialog vault={vault} open onOpenChange={() => {}} />);
		const confirmBtn = screen.getByRole("button", { name: /delete vault/i });
		expect(confirmBtn).toBeDisabled();
		fireEvent.change(screen.getByLabelText(/type .*work.* to confirm/i), {
			target: { value: "Work" },
		});
		expect(confirmBtn).toBeEnabled();
		fireEvent.click(confirmBtn);
		await waitFor(() => expect(deleteMutate).toHaveBeenCalledWith("7", expect.anything()));
	});
});
