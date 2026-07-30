import { fireEvent, render, screen } from "@testing-library/react";
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
	it("renders brand, Files, Search, Settings, Account", () => {
		render(
			<Wrap>
				<Rail />
			</Wrap>,
		);
		expect(screen.getByRole("link", { name: /home/iu })).toBeInTheDocument();
		expect(screen.getByRole("button", { name: "Files" })).toBeInTheDocument();
		expect(screen.getByRole("button", { name: "Search" })).toBeInTheDocument();
		expect(screen.getByRole("link", { name: "Settings" })).toHaveAttribute(
			"href",
			"/#settings/account",
		);
		expect(screen.getByRole("button", { name: "User menu" })).toBeInTheDocument();
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

	it('exposes data-tour="search" on the Search icon', () => {
		render(
			<Wrap>
				<Rail />
			</Wrap>,
		);
		expect(screen.getByRole("button", { name: "Search" })).toHaveAttribute("data-tour", "search");
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
			<Wrap initialEntries={["/work/note-1#settings/account"]}>
				<LocationProbe />
				<Rail />
			</Wrap>,
		);
		fireEvent.click(screen.getByRole("button", { name: /files/i }));
		expect(screen.getByTestId("loc")).toHaveTextContent("/work/note-1");
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
