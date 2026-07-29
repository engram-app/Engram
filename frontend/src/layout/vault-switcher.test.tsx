import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { fireEvent, render, screen } from "@testing-library/react";
import { MemoryRouter } from "react-router";
import { describe, expect, it, vi } from "vitest";
import VaultSwitcher from "./vault-switcher";

// Switching vaults must NAVIGATE (VaultRoute owns writing the active-vault
// store from the URL). A direct setActiveVaultId write with no URL change is
// the unrecoverable-spinner bug: the store and the URL disagree forever and
// VaultRoute holds its Outlet in LoadingPane.
const { navigate, setActiveVaultId } = vi.hoisted(() => ({
	navigate: vi.fn(),
	setActiveVaultId: vi.fn(),
}));

vi.mock("react-router", async () => {
	const actual = await vi.importActual<typeof import("react-router")>("react-router");
	return { ...actual, useNavigate: () => navigate };
});

vi.mock("../api/active-vault", () => ({
	useActiveVaultId: () => "id-a",
	setActiveVaultId,
}));

const vaults = [
	{ id: "id-a", slug: "work", is_default: true, name: "Work" },
	{ id: "id-b", slug: "personal", is_default: false, name: "Personal" },
];
vi.mock("../api/queries", () => ({
	useVaults: () => ({ data: vaults, isLoading: false }),
}));

function renderSwitcher() {
	const qc = new QueryClient();
	return render(
		<QueryClientProvider client={qc}>
			{/* Current URL carries a note id from the vault being left, and the
			 * switch must not carry it into the new vault's URL. */}
			<MemoryRouter initialEntries={["/work/old-note-id"]}>
				<VaultSwitcher />
			</MemoryRouter>
		</QueryClientProvider>,
	);
}

describe("VaultSwitcher", () => {
	it("navigates to the target vault's root instead of writing the store", async () => {
		renderSwitcher();
		const trigger = screen.getByRole("button", { name: /vault/i });
		// Radix DropdownMenu opens on pointerdown in happy-dom.
		fireEvent.pointerDown(trigger, { button: 0, ctrlKey: false });
		fireEvent.click(trigger);
		const item = await screen.findByRole("menuitemradio", { name: "Personal" });
		fireEvent.click(item);

		expect(navigate).toHaveBeenCalledWith("/personal");
		expect(setActiveVaultId).not.toHaveBeenCalled();
	});

	it("does not carry the previous vault's note id into the target URL", async () => {
		renderSwitcher();
		const trigger = screen.getByRole("button", { name: /vault/i });
		fireEvent.pointerDown(trigger, { button: 0, ctrlKey: false });
		fireEvent.click(trigger);
		const item = await screen.findByRole("menuitemradio", { name: "Personal" });
		fireEvent.click(item);

		const target = navigate.mock.calls[0]?.[0];
		expect(target).not.toContain("old-note-id");
	});
});
