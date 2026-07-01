import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { fireEvent, render, screen } from "@testing-library/react";
import { MemoryRouter } from "react-router";
import { beforeEach, describe, expect, it, vi } from "vitest";
import SearchPanel from "./search-panel";
import { RailViewProvider, useRailView } from "./rail-view-context";

vi.mock("../api/queries", () => ({
	useSearch: (q: string) => ({
		data:
			q === "hello"
				? [
						{
							id: 7,
							path: "note.md",
							title: "Note",
							folder: "",
							heading_path: "",
							snippet: "hello world",
							match_count: 1,
						},
					]
				: [],
		isLoading: false,
		error: null,
	}),
}));

function ViewProbe() {
	const { view } = useRailView();
	return <span data-testid="view">{view}</span>;
}

function renderPanel() {
	const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } });
	return render(
		<QueryClientProvider client={qc}>
			<MemoryRouter>
				<RailViewProvider>
					<SearchPanel />
					<ViewProbe />
				</RailViewProvider>
			</MemoryRouter>
		</QueryClientProvider>,
	);
}

describe("SearchPanel", () => {
	beforeEach(() => {
		window.localStorage.clear();
	});

	it('renders header "Search" and an [x] return-to-files control', () => {
		renderPanel();
		expect(screen.getByRole("heading", { name: "Search", level: 2 })).toBeInTheDocument();
		expect(screen.getByRole("button", { name: /close search/i })).toBeInTheDocument();
	});

	it('shows "Recent" empty-state when query is blank and recents exist', () => {
		window.localStorage.setItem("engram:recent-searches", JSON.stringify(["alpha", "beta"]));
		renderPanel();
		expect(screen.getByText("Recent")).toBeInTheDocument();
		expect(screen.getByText("alpha")).toBeInTheDocument();
	});

	it("types into the input and renders a result row", async () => {
		renderPanel();
		const input = screen.getByPlaceholderText(/search your notes/i) as HTMLInputElement;
		fireEvent.change(input, { target: { value: "hello" } });
		expect(await screen.findByText("Note")).toBeInTheDocument();
	});

	it("[x] returns to Files view", () => {
		renderPanel();
		fireEvent.click(screen.getByRole("button", { name: /close search/i }));
		expect(screen.getByTestId("view").textContent).toBe("files");
	});

	it("Esc in the input returns to Files view", () => {
		renderPanel();
		const input = screen.getByPlaceholderText(/search your notes/i);
		fireEvent.keyDown(input, { key: "Escape" });
		expect(screen.getByTestId("view").textContent).toBe("files");
	});
});
