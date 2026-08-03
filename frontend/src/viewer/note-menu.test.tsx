import { fireEvent, render, screen } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";
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
		expect(screen.getByRole("menuitem", { name: "Rendered" })).not.toHaveAttribute("aria-current");
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
});
