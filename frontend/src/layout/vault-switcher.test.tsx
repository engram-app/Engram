import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { fireEvent, render, screen } from "@testing-library/react";
import { MemoryRouter } from "react-router";
import { beforeEach, describe, expect, it, vi } from "vitest";
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

const allVaults = [
	{ id: "id-a", slug: "work", is_default: true, name: "Work", encrypted: true },
	{ id: "id-b", slug: "personal", is_default: false, name: "Personal", encrypted: false },
];
let vaults = allVaults;

const { createMutate } = vi.hoisted(() => ({ createMutate: vi.fn() }));
vi.mock("../api/queries", () => ({
	useVaults: () => ({ data: vaults, isLoading: false }),
	useCreateVault: () => ({ mutate: createMutate, isPending: false }),
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

function openMenu() {
	const trigger = screen.getByRole("button", { name: /vault/i });
	// Radix DropdownMenu opens on pointerdown in happy-dom.
	fireEvent.pointerDown(trigger, { button: 0, ctrlKey: false });
	fireEvent.click(trigger);
	return trigger;
}

beforeEach(() => {
	vaults = allVaults;
	navigate.mockClear();
	createMutate.mockClear();
});

describe("VaultSwitcher", () => {
	it("navigates to the target vault's root instead of writing the store", async () => {
		renderSwitcher();
		openMenu();
		const item = await screen.findByRole("menuitemradio", { name: "Personal" });
		fireEvent.click(item);

		expect(navigate).toHaveBeenCalledWith("/personal");
		expect(setActiveVaultId).not.toHaveBeenCalled();
	});

	it("does not carry the previous vault's note id into the target URL", async () => {
		renderSwitcher();
		openMenu();
		const item = await screen.findByRole("menuitemradio", { name: "Personal" });
		fireEvent.click(item);

		const target = navigate.mock.calls[0]?.[0];
		expect(target).not.toContain("old-note-id");
	});

	// The lock icon read as "this vault is locked / you can't get in" when it
	// only ever meant "encrypted at rest". Encryption state belongs in settings,
	// not on every render of the switcher.
	it("renders no lock icon for an encrypted vault", async () => {
		const { container } = renderSwitcher();
		openMenu();
		await screen.findByRole("menuitemradio", { name: "Personal" });

		expect(container.querySelector(".lucide-lock")).toBeNull();
		expect(document.querySelector(".lucide-lock")).toBeNull();
	});

	// A single vault used to render as dead text, so there was no way to reach
	// the menu — and therefore no way to create a second vault from the sidebar.
	it("opens the menu when only one vault exists", async () => {
		vaults = [allVaults[0]!];
		renderSwitcher();
		openMenu();

		expect(await screen.findByRole("menuitemradio", { name: "Work" })).toBeTruthy();
		expect(await screen.findByRole("menuitem", { name: /new vault/i })).toBeTruthy();
	});

	it("creates a vault from the menu and navigates to it", async () => {
		renderSwitcher();
		openMenu();
		fireEvent.click(await screen.findByRole("menuitem", { name: /new vault/i }));

		const input = await screen.findByLabelText("Vault name");
		fireEvent.change(input, { target: { value: "Archive" } });
		fireEvent.submit(input.closest("form")!);

		expect(createMutate).toHaveBeenCalledWith(
			{ name: "Archive" },
			expect.objectContaining({ onSuccess: expect.any(Function) }),
		);
		// Land in the vault that was just created, by slug.
		createMutate.mock.calls[0]![1].onSuccess({
			vault: { id: "id-c", slug: "archive", name: "Archive" },
		});
		expect(navigate).toHaveBeenCalledWith("/archive");
	});
});
