import { fireEvent, render, screen } from "@testing-library/react";
import { beforeEach, describe, expect, it } from "vitest";
import { RailViewProvider, useRailView } from "./rail-view-context";
import SidebarViewToggle from "./sidebar-view-toggle";

// The view persists to localStorage, so without this the view one test picks is
// still selected in the next.
beforeEach(() => window.localStorage.clear());

function ViewProbe() {
	const { view } = useRailView();
	return <output data-testid="view">{view}</output>;
}

function mount() {
	return render(
		<RailViewProvider>
			<SidebarViewToggle />
			<ViewProbe />
		</RailViewProvider>,
	);
}

describe("SidebarViewToggle", () => {
	it("offers both sidebar views", () => {
		mount();
		expect(screen.getByRole("button", { name: "Files" })).toBeInTheDocument();
		expect(screen.getByRole("button", { name: "Search" })).toBeInTheDocument();
	});

	it("starts on files", () => {
		mount();
		expect(screen.getByTestId("view")).toHaveTextContent("files");
		expect(screen.getByRole("button", { name: "Files" })).toHaveAttribute("aria-current", "page");
	});

	it("switches the view when the other tab is picked", () => {
		mount();
		fireEvent.click(screen.getByRole("button", { name: "Search" }));
		expect(screen.getByTestId("view")).toHaveTextContent("search");
	});

	// aria-current marks which panel is showing; a screen reader user tabbing the
	// row has no other way to tell, since both tabs stay clickable.
	it("moves aria-current onto the selected view", () => {
		mount();
		fireEvent.click(screen.getByRole("button", { name: "Search" }));
		expect(screen.getByRole("button", { name: "Search" })).toHaveAttribute("aria-current", "page");
		expect(screen.getByRole("button", { name: "Files" })).not.toHaveAttribute("aria-current");
	});

	it("switches back", () => {
		mount();
		fireEvent.click(screen.getByRole("button", { name: "Search" }));
		fireEvent.click(screen.getByRole("button", { name: "Files" }));
		expect(screen.getByTestId("view")).toHaveTextContent("files");
	});
});
