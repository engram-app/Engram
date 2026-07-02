import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { DeleteVaultDialog } from "./delete-vault-dialog";

const deleteMutate = vi.fn();
vi.mock("@/api/queries", () => ({
	useDeleteVault: () => ({ mutate: deleteMutate, isPending: false }),
}));
vi.mock("sonner", () => ({ toast: { success: vi.fn(), error: vi.fn() } }));

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
		expect(screen.getByText(/30 days/iu)).toBeInTheDocument();
		expect(screen.getByText(/synced to your devices/iu)).toBeInTheDocument();
		expect(screen.getByText(/142/u)).toBeInTheDocument();
	});

	it("keeps the delete button disabled until the name is typed", async () => {
		render(<DeleteVaultDialog vault={vault} open onOpenChange={() => {}} />);
		const confirmBtn = screen.getByRole("button", { name: /delete vault/iu });
		expect(confirmBtn).toBeDisabled();
		fireEvent.change(screen.getByLabelText(/type .*work.* to confirm/iu), {
			target: { value: "Work" },
		});
		expect(confirmBtn).toBeEnabled();
		fireEvent.click(confirmBtn);
		await waitFor(() => expect(deleteMutate).toHaveBeenCalledWith("7", expect.anything()));
	});
});
