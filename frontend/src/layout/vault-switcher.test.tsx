import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { fireEvent, render, screen } from "@testing-library/react";
import { MemoryRouter } from "react-router";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { LocaleProvider } from "@/i18n/locale-provider";
import { LIST_ROW_GAP, LIST_ROW_HEIGHT, listContainer, listRowClass } from "@/lib/ui-classes";
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
			<MemoryRouter initialEntries={["/v/work/old-note-id"]}>
				<VaultSwitcher />
			</MemoryRouter>
		</QueryClientProvider>,
	);
}

function openMenu() {
	const trigger = screen.getByRole("button", { name: /vault/i });
	fireEvent.click(trigger);
	return trigger;
}

const manyVaults = Array.from({ length: 40 }, (_, i) => ({
	id: `id-${i}`,
	slug: `vault-${i}`,
	is_default: i === 0,
	name: `Vault ${i}`,
	encrypted: false,
}));

beforeEach(() => {
	vaults = allVaults;
	navigate.mockClear();
	createMutate.mockClear();
});

describe("VaultSwitcher", () => {
	it("navigates to the target vault's root instead of writing the store", async () => {
		renderSwitcher();
		openMenu();
		fireEvent.click(await screen.findByRole("option", { name: "Personal" }));

		expect(navigate).toHaveBeenCalledWith("/v/personal");
		expect(setActiveVaultId).not.toHaveBeenCalled();
	});

	it("does not carry the previous vault's note id into the target URL", async () => {
		renderSwitcher();
		openMenu();
		fireEvent.click(await screen.findByRole("option", { name: "Personal" }));

		const target = navigate.mock.calls[0]?.[0];
		expect(target).not.toContain("old-note-id");
	});

	it("picking the vault you are already in just closes the picker", async () => {
		renderSwitcher();
		openMenu();
		fireEvent.click(await screen.findByRole("option", { name: "Work" }));

		expect(navigate).not.toHaveBeenCalled();
		expect(screen.queryByRole("option", { name: "Work" })).toBeNull();
	});

	it("marks the current vault as selected", async () => {
		renderSwitcher();
		openMenu();
		expect(await screen.findByRole("option", { name: "Work" })).toHaveAttribute(
			"aria-selected",
			"true",
		);
		expect(screen.getByRole("option", { name: "Personal" })).toHaveAttribute(
			"aria-selected",
			"false",
		);
	});

	// The file tree and this picker are the same kind of list: one shape, one set
	// of hover/selected colors, defined once in ui-classes so they cannot drift.
	it("styles its rows with the shared list-row classes, like the file tree", async () => {
		renderSwitcher();
		openMenu();
		const current = await screen.findByRole("option", { name: "Work" });
		const other = screen.getByRole("option", { name: "Personal" });
		// Hover and the keyboard highlight own `accent`; a selected row keeps its chip
		// (exclusive, same as the tree).
		for (const cls of listRowClass({ selected: true }).split(" ")) {
			expect(current).toHaveClass(cls);
		}
		for (const cls of listRowClass().split(" ")) {
			expect(other).toHaveClass(cls);
		}
	});

	// Same rhythm as the file tree: its row height, the gap between rows, and the
	// inset around the list (so the first and last row never touch the borders).
	it("lays its rows out with the file tree's geometry", async () => {
		renderSwitcher();
		openMenu();
		const option = await screen.findByRole("option", { name: "Work" });
		const list = screen.getByRole("listbox", { name: "Vaults" });
		expect(option.style.height).toBe(`${LIST_ROW_HEIGHT}px`);
		expect(list.style.gap).toBe(`${LIST_ROW_GAP}px`);
		for (const cls of listContainer.split(" ")) {
			expect(list).toHaveClass(cls);
		}
	});

	// The lock icon read as "this vault is locked / you can't get in" when it
	// only ever meant "encrypted at rest". Encryption state belongs in settings,
	// not on every render of the switcher.
	it("renders no lock icon for an encrypted vault", async () => {
		const { container } = renderSwitcher();
		openMenu();
		await screen.findByRole("option", { name: "Personal" });

		expect(container.querySelector(".lucide-lock")).toBeNull();
		expect(document.querySelector(".lucide-lock")).toBeNull();
	});

	// A single vault used to render as dead text, so there was no way to reach
	// the picker -- and therefore no way to create a second vault from the sidebar.
	it("opens the picker when only one vault exists", async () => {
		vaults = [allVaults[0]!];
		renderSwitcher();
		openMenu();

		expect(await screen.findByRole("option", { name: "Work" })).toBeTruthy();
		expect(await screen.findByRole("button", { name: /new vault/i })).toBeTruthy();
	});

	it("creates a vault from the picker and navigates to it", async () => {
		renderSwitcher();
		openMenu();
		fireEvent.click(await screen.findByRole("button", { name: /new vault/i }));

		const input = await screen.findByLabelText("Vault name");
		fireEvent.change(input, { target: { value: "Archive" } });
		fireEvent.submit(input.closest("form")!);

		expect(createMutate).toHaveBeenCalledWith(
			{ name: "Archive", client_id: expect.any(String) },
			expect.objectContaining({ onSuccess: expect.any(Function) }),
		);
		// Land in the vault that was just created, by slug. /vaults/register
		// answers with the vault flat, NOT wrapped in { vault }.
		createMutate.mock.calls[0]![1].onSuccess({ id: "id-c", slug: "archive", name: "Archive" });
		expect(navigate).toHaveBeenCalledWith("/v/archive");
	});
});

describe("VaultSwitcher -- finding a vault among many", () => {
	const search = () => screen.findByRole("combobox", { name: "Search vaults" });
	const optionNames = () => screen.getAllByRole("option").map((o) => o.textContent);

	it("moves focus to the search box when the picker opens", async () => {
		renderSwitcher();
		openMenu();
		expect(await search()).toHaveFocus();
	});

	it("filters the list as you type, by name, ignoring case", async () => {
		vaults = manyVaults;
		renderSwitcher();
		openMenu();
		fireEvent.change(await search(), { target: { value: "vAuLt 3" } });
		expect(optionNames()).toEqual(
			["Vault 3", ...Array.from({ length: 10 }, (_, i) => `Vault 3${i}`)].slice(0, 11),
		);
	});

	it("filters by slug too", async () => {
		renderSwitcher();
		openMenu();
		fireEvent.change(await search(), { target: { value: "personal" } });
		expect(optionNames()).toEqual(["Personal"]);
	});

	it("says so when nothing matches, and still offers New vault", async () => {
		renderSwitcher();
		openMenu();
		fireEvent.change(await search(), { target: { value: "zzz" } });
		expect(screen.queryAllByRole("option")).toHaveLength(0);
		expect(screen.getByText("No vaults match")).toBeInTheDocument();
		expect(screen.getByRole("button", { name: /new vault/i })).toBeInTheDocument();
	});

	it("Enter picks the only match", async () => {
		renderSwitcher();
		openMenu();
		const box = await search();
		fireEvent.change(box, { target: { value: "pers" } });
		fireEvent.keyDown(box, { key: "Enter" });
		expect(navigate).toHaveBeenCalledWith("/v/personal");
	});

	it("arrow keys move the highlight and Enter picks it", async () => {
		vaults = manyVaults;
		renderSwitcher();
		openMenu();
		const box = await search();
		// Opens on the current vault ("Vault 0"); two downs land on "Vault 2".
		fireEvent.keyDown(box, { key: "ArrowDown" });
		fireEvent.keyDown(box, { key: "ArrowDown" });
		expect(box.getAttribute("aria-activedescendant")).toBe(
			screen.getByRole("option", { name: "Vault 2" }).id,
		);
		fireEvent.keyDown(box, { key: "Enter" });
		expect(navigate).toHaveBeenCalledWith("/v/vault-2");
	});

	it("starts with an empty filter each time it opens", async () => {
		renderSwitcher();
		const trigger = openMenu();
		fireEvent.change(await search(), { target: { value: "pers" } });
		fireEvent.keyDown(await search(), { key: "Escape" });
		expect(screen.queryByRole("combobox", { name: "Search vaults" })).toBeNull();
		fireEvent.click(trigger);
		expect(await search()).toHaveValue("");
		expect(screen.getAllByRole("option")).toHaveLength(2);
	});

	// The panel opens upward from the trigger, so the search box goes at the very
	// bottom, next to where the pointer just was, with New vault right above it.
	it("orders the panel list, then New vault, then the search box", async () => {
		renderSwitcher();
		openMenu();
		const box = await search();
		const option = screen.getByRole("option", { name: "Work" });
		const create = screen.getByRole("button", { name: /new vault/i });
		// Three unrelated leaves, so "b comes after a" is exactly the FOLLOWING flag.
		const follows = (a: Node, b: Node) =>
			a.compareDocumentPosition(b) === Node.DOCUMENT_POSITION_FOLLOWING;
		expect(follows(option, create)).toBe(true);
		expect(follows(create, box)).toBe(true);
	});

	// An always-on scrollbar sat on top of the right end of the hover / selected
	// chips. It is an overlay, so rather than reserving a gutter that would look
	// lopsided when nothing is scrolling, it only shows while the list moves.
	it("shows the scrollbar only while the list is scrolling", async () => {
		vaults = manyVaults;
		renderSwitcher();
		openMenu();
		await screen.findByRole("option", { name: "Vault 5" });
		const bar = () => document.querySelector('[data-slot="scroll-area-scrollbar"]');
		expect(bar()).toBeNull();
		const viewport = document.querySelector('[data-slot="scroll-area-viewport"]');
		expect(viewport).not.toBeNull();
		// Radix reacts to the scroll POSITION changing, not just the event.
		(viewport as HTMLElement).scrollTop = 120;
		fireEvent.scroll(viewport as Element);
		await vi.waitFor(() => expect(bar()).not.toBeNull());
	});

	// The footer must stay put however long the list is, so it lives outside the
	// scrolling region, and the list scrolls in the shadcn ScrollArea.
	it("scrolls the list in a ScrollArea and keeps New vault outside it", async () => {
		vaults = manyVaults;
		renderSwitcher();
		openMenu();
		const option = await screen.findByRole("option", { name: "Vault 5" });
		expect(option.closest('[data-slot="scroll-area"]')).not.toBeNull();
		expect(
			screen.getByRole("button", { name: /new vault/i }).closest('[data-slot="scroll-area"]'),
		).toBeNull();
	});
});

describe("VaultSwitcher: default vault name", () => {
	it("shows the translated default for a vault stored as 'My Vault'", async () => {
		window.localStorage.setItem("engram:locale", "de");
		vaults = [{ id: "id-a", slug: "work", is_default: true, name: "My Vault", encrypted: true }];
		const qc = new QueryClient();
		render(
			<LocaleProvider loaders={{ de: async () => ({ default: { "My Vault": "Mein Tresor" } }) }}>
				<QueryClientProvider client={qc}>
					<MemoryRouter initialEntries={["/v/work"]}>
						<VaultSwitcher />
					</MemoryRouter>
				</QueryClientProvider>
			</LocaleProvider>,
		);
		expect(await screen.findByText("Mein Tresor")).toBeInTheDocument();
		vaults = allVaults;
		window.localStorage.clear();
	});
});
