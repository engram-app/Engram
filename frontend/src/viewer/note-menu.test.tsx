import { fireEvent, render, screen } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { MobileHeaderSlot } from "@/layout/mobile-header-slot";
import { NoteMenu } from "./note-menu";

const matches = vi.fn();
vi.mock("@/hooks/use-media-query", () => ({
	useMediaQuery: () => matches(),
}));

// Radix DropdownMenu opens on pointerdown in happy-dom; the mobile drawer is a
// plain button, so it needs the click only.
const openMenu = () => {
	const trigger = screen.getByRole("button", { name: "Note options" });
	fireEvent.pointerDown(trigger, { button: 0, ctrlKey: false });
	fireEvent.click(trigger);
};

describe("NoteMenu", () => {
	beforeEach(() => {
		vi.clearAllMocks();
		matches.mockReturnValue(true); // desktop by default
	});

	it("opens a dropdown on desktop and reports the picked action", async () => {
		const onPick = vi.fn();
		render(<NoteMenu mode="rendered" title="note" onPick={onPick} />);
		openMenu();
		fireEvent.click(await screen.findByRole("menuitem", { name: "Duplicate" }));
		expect(onPick).toHaveBeenCalledWith("duplicate");
	});

	// The menu hangs off a 32px icon button. Sizing to the trigger pinned it to
	// the min-width floor and wrapped "Copy wikilink" onto two lines.
	it("sizes to its content rather than to the icon trigger", async () => {
		render(<NoteMenu mode="rendered" title="note" onPick={vi.fn()} />);
		openMenu();
		const menu = await screen.findByRole("menu");
		expect(menu.className).not.toMatch(/radix-dropdown-menu-trigger-width/);
		expect(menu).toHaveClass("whitespace-nowrap");
	});

	it("marks the active view mode", async () => {
		render(<NoteMenu mode="raw" title="note" onPick={vi.fn()} />);
		openMenu();
		expect(await screen.findByRole("menuitem", { name: "Raw" })).toHaveAttribute(
			"aria-current",
			"true",
		);
		expect(screen.getByRole("menuitem", { name: "Edit" })).not.toHaveAttribute("aria-current");
	});

	it("uses the bottom-sheet drawer on mobile", () => {
		matches.mockReturnValue(false);
		const onPick = vi.fn();
		render(<NoteMenu mode="rendered" title="note" onPick={onPick} />);
		openMenu();
		// The drawer renders its own backdrop; the dropdown does not.
		expect(screen.getByTestId("action-drawer-backdrop")).toBeInTheDocument();
		fireEvent.click(screen.getByRole("menuitem", { name: "Delete" }));
		expect(onPick).toHaveBeenCalledWith("delete");
	});

	it("closes the drawer after a pick", () => {
		matches.mockReturnValue(false);
		render(<NoteMenu mode="rendered" title="note" onPick={vi.fn()} />);
		openMenu();
		fireEvent.click(screen.getByRole("menuitem", { name: "Rename" }));
		expect(screen.queryByTestId("action-drawer-backdrop")).not.toBeInTheDocument();
	});

	// The mobile header has no tools button; the drawer opens from the kebab.
	it("puts Open tools just above Delete when the layout provides it", () => {
		matches.mockReturnValue(false);
		const openTools = vi.fn();
		const onPick = vi.fn();
		render(
			<MobileHeaderSlot.Provider value={{ slot: null, openTools }}>
				<NoteMenu mode="rendered" title="note" onPick={onPick} />
			</MobileHeaderSlot.Provider>,
		);
		openMenu();
		const names = screen.getAllByRole("menuitem").map((el) => el.textContent);
		// Above Delete, which stays last.
		expect(names.slice(-2)).toEqual(["Open tools", "Delete"]);
		fireEvent.click(screen.getByRole("menuitem", { name: "Open tools" }));
		expect(openTools).toHaveBeenCalledOnce();
		expect(onPick).not.toHaveBeenCalled();
		expect(screen.queryByTestId("action-drawer-backdrop")).not.toBeInTheDocument();
	});

	it("has no Open tools outside the mobile layout", async () => {
		render(<NoteMenu mode="rendered" title="note" onPick={vi.fn()} />);
		openMenu();
		await screen.findByRole("menuitem", { name: "Duplicate" });
		expect(screen.queryByRole("menuitem", { name: "Open tools" })).not.toBeInTheDocument();
	});

	// Same groups as the desktop dropdown: view modes | file actions | Delete.
	it("divides the mobile drawer's groups", () => {
		matches.mockReturnValue(false);
		render(<NoteMenu mode="rendered" title="note" onPick={vi.fn()} />);
		openMenu();
		const divided = screen
			.getAllByRole("menuitem")
			.filter((el) => el.previousElementSibling?.getAttribute("role") === "separator")
			.map((el) => el.textContent);
		expect(divided).toEqual(["Rename", "Delete"]);
	});
});
