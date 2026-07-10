import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { fireEvent, render, screen } from "@testing-library/react";
import { MemoryRouter } from "react-router";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { RailViewProvider, useRailView } from "./rail-view-context";
import SearchPanel from "./search-panel";

const useSearchSpy = vi.fn((q: string, _filters?: unknown) => ({
	data:
		q === "hello"
			? [
					{
						id: 7,
						path: "note.md",
						title: "Some H1 Heading",
						folder: "",
						heading_path: "",
						snippet: "hello world",
						match_count: 1,
					},
				]
			: [],
	isLoading: false,
	error: null,
}));

vi.mock("../api/queries", () => ({
	useSearch: (q: string, filters: unknown) => useSearchSpy(q, filters),
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
		useSearchSpy.mockClear();
	});

	it('renders header "Search" and an [x] return-to-files control', () => {
		renderPanel();
		expect(screen.getByRole("heading", { name: "Search", level: 2 })).toBeInTheDocument();
		expect(screen.getByRole("button", { name: /close search/iu })).toBeInTheDocument();
	});

	it('shows "Recent" empty-state when query is blank and recents exist', () => {
		window.localStorage.setItem("engram:recent-searches", JSON.stringify(["alpha", "beta"]));
		renderPanel();
		expect(screen.getByText("Recent")).toBeInTheDocument();
		expect(screen.getByText("alpha")).toBeInTheDocument();
	});

	it("renders a result row labeled by filename, never the derived title", async () => {
		renderPanel();
		const input = screen.getByPlaceholderText(/search your notes/iu) as HTMLInputElement;
		fireEvent.change(input, { target: { value: "hello" } });
		expect(await screen.findByText("note")).toBeInTheDocument();
		expect(screen.queryByText("Some H1 Heading")).not.toBeInTheDocument();
	});

	it("[x] returns to Files view", () => {
		renderPanel();
		fireEvent.click(screen.getByRole("button", { name: /close search/iu }));
		expect(screen.getByTestId("view").textContent).toBe("files");
	});

	it("Esc in the input returns to Files view", () => {
		renderPanel();
		const input = screen.getByPlaceholderText(/search your notes/iu);
		fireEvent.keyDown(input, { key: "Escape" });
		expect(screen.getByTestId("view").textContent).toBe("files");
	});

	it("typing a type filter re-fires the search with that filter", () => {
		renderPanel();
		const typeInput = screen.getByLabelText(/filter by type/iu);
		fireEvent.change(typeInput, { target: { value: "Playbook" } });

		expect(useSearchSpy).toHaveBeenLastCalledWith("", { type: "Playbook" });
	});

	it("picking an updated-after date re-fires the search with an ISO midnight-UTC filter", () => {
		renderPanel();
		const updatedAfterInput = screen.getByLabelText(/updated after/iu);
		fireEvent.change(updatedAfterInput, { target: { value: "2026-01-01" } });

		expect(useSearchSpy).toHaveBeenLastCalledWith("", { updatedAfter: "2026-01-01T00:00:00Z" });
	});
});
