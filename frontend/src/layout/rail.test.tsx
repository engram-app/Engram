import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { useEffect } from "react";
import { MemoryRouter, useLocation } from "react-router";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { ThemeProvider } from "../theme/theme-provider";
import Rail from "./rail";
import { RailViewProvider, useRailView } from "./rail-view-context";
import { RightToolsProvider, useRightTools } from "./right-tools-context";

function LocationProbe() {
	const loc = useLocation();
	return <output data-testid="loc">{`${loc.pathname}${loc.hash}`}</output>;
}

vi.mock("../auth/use-auth-adapter", () => ({
	useAuthAdapter: () => ({ user: { email: "todd@example.com" }, logout: vi.fn() }),
}));

// Both the rail view and the active right-hand tool persist to localStorage, so
// without this the tool one test opens is still open in the next one.
beforeEach(() => window.localStorage.clear());

function Wrap({
	children,
	initialEntries,
}: {
	children: React.ReactNode;
	initialEntries?: string[];
}) {
	return (
		<ThemeProvider>
			<MemoryRouter initialEntries={initialEntries ?? ["/"]}>
				<RailViewProvider>
					<RightToolsProvider>{children}</RightToolsProvider>
				</RailViewProvider>
			</MemoryRouter>
		</ThemeProvider>
	);
}

function ActiveProbe() {
	const { view } = useRailView();
	return <span data-testid="view">{view}</span>;
}

function PathProbe() {
	const { pathname } = useLocation();
	return <span data-testid="pathname">{pathname}</span>;
}

describe("Rail — right-sidebar tool group", () => {
	function ToolProbe() {
		const { resolvedId } = useRightTools();
		return <span data-testid="tool">{resolvedId ?? "none"}</span>;
	}

	// Publishes an outline slot, standing in for an open note.
	function OutlinePublisher() {
		const { setSlot } = useRightTools();
		useEffect(() => setSlot("outline", <p>toc</p>), [setSlot]);
		return null;
	}

	it("surfaces both tools alongside the view buttons", () => {
		render(
			<Wrap>
				<Rail />
			</Wrap>,
		);
		expect(screen.getByRole("button", { name: "Outline" })).toBeInTheDocument();
		expect(screen.getByRole("button", { name: "Reference" })).toBeInTheDocument();
	});

	it("keeps the always-on Reference tool usable with no note open", () => {
		render(
			<Wrap>
				<Rail />
			</Wrap>,
		);
		expect(screen.getByRole("button", { name: "Reference" })).toBeEnabled();
		// The outline has nothing to show until a page publishes one.
		expect(screen.getByRole("button", { name: "Outline" })).toBeDisabled();
	});

	it("enables the Outline tool once a page publishes one", () => {
		render(
			<Wrap>
				<OutlinePublisher />
				<Rail />
			</Wrap>,
		);
		expect(screen.getByRole("button", { name: "Outline" })).toBeEnabled();
	});

	it("opening a tool does NOT disturb the left sidebar view", () => {
		// The whole point of splitting the rail into two groups: reaching for the
		// markdown reference must not cost you the file tree.
		render(
			<Wrap>
				<Rail />
				<ActiveProbe />
				<ToolProbe />
			</Wrap>,
		);
		expect(screen.getByTestId("view").textContent).toBe("files");

		fireEvent.click(screen.getByRole("button", { name: "Reference" }));

		expect(screen.getByTestId("tool").textContent).toBe("reference");
		expect(screen.getByTestId("view").textContent).toBe("files");
		expect(screen.getByRole("button", { name: "Files" })).toHaveAttribute("aria-current", "page");
	});

	it("toggles a tool shut when its own button is clicked again", () => {
		render(
			<Wrap>
				<Rail />
				<ToolProbe />
			</Wrap>,
		);
		fireEvent.click(screen.getByRole("button", { name: "Reference" }));
		expect(screen.getByRole("button", { name: "Reference" })).toHaveAttribute(
			"aria-pressed",
			"true",
		);

		fireEvent.click(screen.getByRole("button", { name: "Reference" }));
		expect(screen.getByTestId("tool").textContent).toBe("none");
		expect(screen.getByRole("button", { name: "Reference" })).toHaveAttribute(
			"aria-pressed",
			"false",
		);
	});

	it("switches straight between tools without a collapse in between", () => {
		render(
			<Wrap>
				<OutlinePublisher />
				<Rail />
				<ToolProbe />
			</Wrap>,
		);
		fireEvent.click(screen.getByRole("button", { name: "Reference" }));
		fireEvent.click(screen.getByRole("button", { name: "Outline" }));
		expect(screen.getByTestId("tool").textContent).toBe("outline");
	});
});

describe("Rail", () => {
	it("renders brand, Files, Search and the user menu", () => {
		render(
			<Wrap>
				<Rail />
			</Wrap>,
		);
		expect(screen.getByRole("link", { name: /home/iu })).toBeInTheDocument();
		expect(screen.getByRole("button", { name: "Files" })).toBeInTheDocument();
		expect(screen.getByRole("button", { name: "Search" })).toBeInTheDocument();
		expect(screen.getByRole("button", { name: "User menu" })).toBeInTheDocument();
	});

	// Settings lives in the user menu only, as in most products. A second entry
	// point on the rail (a cog) was redundant.
	it("has no Settings cog on the rail", () => {
		render(
			<Wrap>
				<Rail />
			</Wrap>,
		);
		expect(screen.queryByRole("link", { name: "Settings" })).toBeNull();
		expect(screen.queryByRole("button", { name: "Settings" })).toBeNull();
	});

	it("Settings is reachable from the user menu", async () => {
		render(
			<Wrap>
				<Rail />
			</Wrap>,
		);
		fireEvent.keyDown(screen.getByRole("button", { name: "User menu" }), { key: "Enter" });
		const item = await screen.findByRole("menuitem", { name: "Settings" });
		expect(item).toHaveAttribute("href", "/#settings/account");
	});

	it("clicking Files / Search swaps the active view", () => {
		render(
			<Wrap>
				<Rail />
				<ActiveProbe />
			</Wrap>,
		);
		expect(screen.getByTestId("view").textContent).toBe("files");
		fireEvent.click(screen.getByRole("button", { name: "Search" }));
		expect(screen.getByTestId("view").textContent).toBe("search");
		fireEvent.click(screen.getByRole("button", { name: "Files" }));
		expect(screen.getByTestId("view").textContent).toBe("files");
	});

	it("marks the active view icon with aria-current=page", () => {
		render(
			<Wrap>
				<Rail />
			</Wrap>,
		);
		expect(screen.getByRole("button", { name: "Files" })).toHaveAttribute("aria-current", "page");
		fireEvent.click(screen.getByRole("button", { name: "Search" }));
		expect(screen.getByRole("button", { name: "Search" })).toHaveAttribute("aria-current", "page");
		expect(screen.getByRole("button", { name: "Files" })).not.toHaveAttribute("aria-current");
	});

	it("clicking Files from the settings hash strips the hash and stays on /", () => {
		render(
			<Wrap initialEntries={["/#settings/account"]}>
				<Rail />
				<LocationProbe />
			</Wrap>,
		);
		expect(screen.getByTestId("loc")).toHaveTextContent("/#settings/account");
		fireEvent.click(screen.getByRole("button", { name: "Files" }));
		expect(screen.getByTestId("loc")).toHaveTextContent("/");
		expect(screen.getByTestId("loc")).not.toHaveTextContent("#settings");
	});

	it("clicking Search from the settings hash strips the hash and sets view to search", () => {
		render(
			<Wrap initialEntries={["/#settings/account"]}>
				<Rail />
				<LocationProbe />
				<ActiveProbe />
			</Wrap>,
		);
		fireEvent.click(screen.getByRole("button", { name: "Search" }));
		expect(screen.getByTestId("loc")).toHaveTextContent("/");
		expect(screen.getByTestId("loc")).not.toHaveTextContent("#settings");
		expect(screen.getByTestId("view").textContent).toBe("search");
	});

	it("closes settings without leaving the current note", () => {
		render(
			<Wrap initialEntries={["/v/work/note-1#settings/account"]}>
				<LocationProbe />
				<Rail />
			</Wrap>,
		);
		fireEvent.click(screen.getByRole("button", { name: /files/i }));
		expect(screen.getByTestId("loc")).toHaveTextContent("/v/work/note-1");
		expect(screen.getByTestId("loc")).not.toHaveTextContent("#settings");
	});

	it("clicking Files from / does NOT change the pathname", () => {
		render(
			<Wrap initialEntries={["/"]}>
				<Rail />
				<PathProbe />
			</Wrap>,
		);
		fireEvent.click(screen.getByRole("button", { name: "Files" }));
		expect(screen.getByTestId("pathname").textContent).toBe("/");
	});
});

// The active view button doubles as the left sidebar's open/close toggle: the
// same gesture the right-hand tool buttons already offer.
describe("Rail — collapsing the left sidebar", () => {
	function OpenProbe() {
		const { view, sidebarOpen } = useRailView();
		return <output data-testid="state">{`${view}:${sidebarOpen ? "open" : "closed"}`}</output>;
	}
	const state = () => screen.getByTestId("state").textContent;
	const renderRail = (initialEntries?: string[]) =>
		render(
			<Wrap initialEntries={initialEntries}>
				<Rail />
				<OpenProbe />
				<LocationProbe />
			</Wrap>,
		);

	it("clicking the active view collapses the sidebar, clicking it again reopens it", () => {
		renderRail();
		expect(state()).toBe("files:open");
		fireEvent.click(screen.getByRole("button", { name: "Files" }));
		expect(state()).toBe("files:closed");
		fireEvent.click(screen.getByRole("button", { name: "Files" }));
		expect(state()).toBe("files:open");
	});

	it("a collapsed sidebar shows no active view", () => {
		renderRail();
		fireEvent.click(screen.getByRole("button", { name: "Files" }));
		expect(screen.getByRole("button", { name: "Files" })).not.toHaveAttribute("aria-current");
	});

	it("clicking the other view switches to it and keeps the sidebar open", () => {
		renderRail();
		fireEvent.click(screen.getByRole("button", { name: "Search" }));
		expect(state()).toBe("search:open");
	});

	it("clicking any view while collapsed opens the sidebar on that view", () => {
		renderRail();
		fireEvent.click(screen.getByRole("button", { name: "Files" }));
		expect(state()).toBe("files:closed");
		fireEvent.click(screen.getByRole("button", { name: "Search" }));
		expect(state()).toBe("search:open");
	});

	it("leaving settings by clicking Files opens the sidebar instead of collapsing it", () => {
		renderRail(["/v/health#settings/account"]);
		fireEvent.click(screen.getByRole("button", { name: "Files" }));
		expect(state()).toBe("files:open");
		expect(screen.getByTestId("loc").textContent).not.toContain("settings");
	});
});

// The rail's icon buttons used the browser's native `title` tooltip, which
// ignores the app theme and looks nothing like the rest of the UI. They use the
// shared Tooltip component instead.
describe("Rail — tooltips", () => {
	const tooltip = () => document.querySelector('[data-slot="tooltip-content"]');
	const renderRail = () =>
		render(
			<Wrap>
				<Rail />
			</Wrap>,
		);

	it("no rail control carries a native title attribute", () => {
		renderRail();
		for (const name of ["Files", "Search", "Outline", "Backlinks", "Reference"]) {
			expect(screen.getByRole("button", { name }), name).not.toHaveAttribute("title");
		}
	});

	it("focusing a view button shows the themed tooltip with its label", async () => {
		renderRail();
		expect(tooltip()).toBeNull();
		fireEvent.focus(screen.getByRole("button", { name: "Files" }));
		await waitFor(() => expect(tooltip()).not.toBeNull());
		expect(tooltip()).toHaveTextContent("Files");
	});

	it("the tooltip appears beside the rail (to the right), not over the content below", async () => {
		renderRail();
		fireEvent.focus(screen.getByRole("button", { name: "Search" }));
		await waitFor(() => expect(tooltip()).not.toBeNull());
		expect(tooltip()).toHaveAttribute("data-side", "right");
	});

	it("an available right-hand tool shows its label", async () => {
		renderRail();
		fireEvent.focus(screen.getByRole("button", { name: "Reference" }));
		await waitFor(() => expect(tooltip()).toHaveTextContent("Reference"));
	});

	it("a disabled tool still explains itself: its tooltip says to open a note first", async () => {
		renderRail();
		const outline = screen.getByRole("button", { name: "Outline" });
		expect(outline).toBeDisabled();
		// A disabled button receives no pointer events, so the tooltip hangs off its wrapper.
		const trigger = outline.closest('[data-slot="tooltip-trigger"]');
		expect(trigger).not.toBeNull();
		fireEvent.focus(trigger as Element);
		await waitFor(() => expect(tooltip()).toHaveTextContent("Outline (open a note first)"));
	});
});
