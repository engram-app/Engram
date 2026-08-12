import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { fireEvent, render, screen } from "@testing-library/react";
import { MemoryRouter, useLocation } from "react-router";
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
					{
						id: 8,
						path: "Archive/note.md",
						title: "Another",
						folder: "Archive",
						heading_path: "",
						snippet: "a second hello",
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

// ResultRow reads the active vault slug to build note hrefs. Default to null
// (the fallback/legacy shape) so existing behavior is unaffected; the one
// test below overrides it to check the vault-scoped shape.
const activeSlugMock = vi.fn<() => string | null>(() => null);
vi.mock("../api/vault-slug", () => ({ useActiveVaultSlug: () => activeSlugMock() }));

function PathProbe() {
	const loc = useLocation();
	return <span data-testid="path">{loc.pathname}</span>;
}

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
					<PathProbe />
				</RailViewProvider>
			</MemoryRouter>
		</QueryClientProvider>,
	);
}

describe("SearchPanel", () => {
	beforeEach(() => {
		window.localStorage.clear();
		useSearchSpy.mockClear();
		activeSlugMock.mockReturnValue(null);
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
		expect((await screen.findAllByText("note"))[0]).toBeInTheDocument();
		expect(screen.queryByText("Some H1 Heading")).not.toBeInTheDocument();
	});

	it("links a result to the legacy note route before the vault slug loads", async () => {
		renderPanel();
		const input = screen.getByPlaceholderText(/search your notes/iu) as HTMLInputElement;
		fireEvent.change(input, { target: { value: "hello" } });
		const [firstRow] = await screen.findAllByText("note");
		const link = firstRow?.closest("a") as HTMLAnchorElement;
		expect(link.getAttribute("href")).toBe("/note/7");
	});

	it("links a result to the vault-scoped route once the active vault slug loads", async () => {
		activeSlugMock.mockReturnValue("work");
		renderPanel();
		const input = screen.getByPlaceholderText(/search your notes/iu) as HTMLInputElement;
		fireEvent.change(input, { target: { value: "hello" } });
		const [firstRow] = await screen.findAllByText("note");
		const link = firstRow?.closest("a") as HTMLAnchorElement;
		expect(link.getAttribute("href")).toBe("/work/7");
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
		fireEvent.click(screen.getByRole("button", { name: /^filters/iu }));
		const typeInput = screen.getByLabelText(/type/iu);
		fireEvent.change(typeInput, { target: { value: "Playbook" } });

		expect(useSearchSpy).toHaveBeenLastCalledWith("", { type: "Playbook" });
	});

	it("picking an updated-after date re-fires the search with an ISO midnight-UTC filter", () => {
		renderPanel();
		fireEvent.click(screen.getByRole("button", { name: /^filters/iu }));
		const updatedAfterInput = screen.getByLabelText(/updated after/iu);
		fireEvent.change(updatedAfterInput, { target: { value: "2026-01-01" } });

		expect(useSearchSpy).toHaveBeenLastCalledWith("", { updatedAfter: "2026-01-01T00:00:00Z" });
	});

	// Five inputs — four of them identical unlabelled date boxes — sat permanently
	// above the results, and there was no way to tell "created after" from
	// "updated before" or to clear one once set.
	describe("filters", () => {
		function openFilters() {
			fireEvent.click(screen.getByRole("button", { name: /^filters/iu }));
		}

		it("sits inline with the search box rather than on its own row", () => {
			renderPanel();
			const input = screen.getByPlaceholderText(/search your notes/iu);
			const trigger = screen.getByRole("button", { name: /^filters/iu });
			expect(input.closest("label")?.parentElement).toBe(trigger.parentElement);
		});

		// Icon-only: aria-label OVERRIDES the badge for the accessible name, so
		// the count has to be spelled into the label or a screen reader loses it.
		it("is icon-only, and says so in its label", () => {
			renderPanel();
			const trigger = screen.getByRole("button", { name: /^filters/iu });
			expect(trigger.textContent).toBe("");
			expect(trigger).toHaveAttribute("aria-label", "Filters");
		});

		it("puts the active count in the label as well as the badge", () => {
			renderPanel();
			openFilters();
			fireEvent.change(screen.getByLabelText(/^type$/iu), { target: { value: "Playbook" } });
			expect(screen.getByRole("button", { name: /^filters/iu })).toHaveAttribute(
				"aria-label",
				"Filters, 1 active",
			);
		});

		it("keeps the filter fields out of the way until asked", () => {
			renderPanel();
			expect(screen.queryByLabelText(/created after/iu)).toBeNull();
		});

		it("reveals the fields when the disclosure is opened", () => {
			renderPanel();
			openFilters();
			for (const name of [
				/type/iu,
				/created after/iu,
				/created before/iu,
				/updated after/iu,
				/updated before/iu,
			]) {
				expect(screen.getByLabelText(name)).toBeInTheDocument();
			}
		});

		// aria-label alone left four visually identical date boxes on screen.
		it("gives every field a VISIBLE label, not just an accessible one", () => {
			const { container } = renderPanel();
			openFilters();
			const labels = [...container.querySelectorAll("label")]
				.map((l) => l.textContent?.trim())
				.filter(Boolean);
			expect(labels).toEqual(
				expect.arrayContaining([
					"Type",
					"Created after",
					"Created before",
					"Updated after",
					"Updated before",
				]),
			);
		});

		it("counts the active filters on the disclosure, so a collapsed panel is not silently filtered", () => {
			renderPanel();
			openFilters();
			fireEvent.change(screen.getByLabelText(/created after/iu), {
				target: { value: "2026-01-01" },
			});
			fireEvent.change(screen.getByLabelText(/^type$/iu), { target: { value: "Playbook" } });
			expect(screen.getByRole("button", { name: /^filters/iu })).toHaveTextContent("2");
		});

		it("shows no count when nothing is filtered", () => {
			renderPanel();
			expect(screen.getByRole("button", { name: /^filters/iu })).not.toHaveTextContent(/[0-9]/u);
		});

		it("clears every filter at once and re-fires the search", () => {
			renderPanel();
			openFilters();
			fireEvent.change(screen.getByLabelText(/^type$/iu), { target: { value: "Playbook" } });
			fireEvent.click(screen.getByRole("button", { name: /clear filters/iu }));
			expect(useSearchSpy).toHaveBeenLastCalledWith("", {});
		});

		it("offers nothing to clear when nothing is set", () => {
			renderPanel();
			openFilters();
			expect(screen.queryByRole("button", { name: /clear filters/iu })).toBeNull();
		});

		// Uncontrolled date inputs kept their text after a reset, so the panel
		// showed a filter that was no longer being applied.
		it("empties the date fields on clear, not just the query", () => {
			renderPanel();
			openFilters();
			const createdAfter = screen.getByLabelText(/created after/iu) as HTMLInputElement;
			fireEvent.change(createdAfter, { target: { value: "2026-01-01" } });
			fireEvent.click(screen.getByRole("button", { name: /clear filters/iu }));
			expect(createdAfter.value).toBe("");
		});
	});

	describe("results", () => {
		async function search() {
			renderPanel();
			fireEvent.change(screen.getByPlaceholderText(/search your notes/iu), {
				target: { value: "hello" },
			});
			await screen.findAllByText("note");
		}

		// The backend caps at 20, so "20" alone would read as the whole truth.
		it("says how many results came back", async () => {
			await search();
			expect(screen.getByText(/2 results/iu)).toBeInTheDocument();
		});

		// The API has always returned `folder` and the row never showed it, so two
		// notes with the same filename were indistinguishable.
		it("shows the folder so same-named notes can be told apart", async () => {
			await search();
			expect(screen.getByText("Archive")).toBeInTheDocument();
		});

		it("highlights the matched term inside the snippet", async () => {
			await search();
			const marks = document.querySelectorAll("mark");
			expect(marks.length).toBeGreaterThan(0);
			expect([...marks].every((m) => m.textContent?.toLowerCase() === "hello")).toBe(true);
		});
	});

	// Obsidian lets you drive the whole list from the input. Without this you have
	// to leave the field and tab through every result.
	describe("keyboard navigation", () => {
		async function searchAndGetInput() {
			renderPanel();
			const input = screen.getByPlaceholderText(/search your notes/iu);
			fireEvent.change(input, { target: { value: "hello" } });
			await screen.findAllByText("note");
			return input;
		}

		it("marks no result active until an arrow key is pressed", async () => {
			await searchAndGetInput();
			expect(document.querySelector("[data-active-result='true']")).toBeNull();
		});

		it("moves down the list with ArrowDown", async () => {
			const input = await searchAndGetInput();
			fireEvent.keyDown(input, { key: "ArrowDown" });
			const active = document.querySelector("[data-active-result='true']");
			expect(active).toHaveAttribute("href", "/note/7");
		});

		it("keeps going down to the next result", async () => {
			const input = await searchAndGetInput();
			fireEvent.keyDown(input, { key: "ArrowDown" });
			fireEvent.keyDown(input, { key: "ArrowDown" });
			expect(document.querySelector("[data-active-result='true']")).toHaveAttribute(
				"href",
				"/note/8",
			);
		});

		it("stops at the end rather than wrapping to the top", async () => {
			const input = await searchAndGetInput();
			for (let i = 0; i < 5; i++) {
				fireEvent.keyDown(input, { key: "ArrowDown" });
			}
			expect(document.querySelector("[data-active-result='true']")).toHaveAttribute(
				"href",
				"/note/8",
			);
		});

		it("comes back up with ArrowUp", async () => {
			const input = await searchAndGetInput();
			fireEvent.keyDown(input, { key: "ArrowDown" });
			fireEvent.keyDown(input, { key: "ArrowDown" });
			fireEvent.keyDown(input, { key: "ArrowUp" });
			expect(document.querySelector("[data-active-result='true']")).toHaveAttribute(
				"href",
				"/note/7",
			);
		});

		it("opens the active result on Enter", async () => {
			const input = await searchAndGetInput();
			fireEvent.keyDown(input, { key: "ArrowDown" });
			fireEvent.keyDown(input, { key: "Enter" });
			expect(screen.getByTestId("path").textContent).toBe("/note/7");
		});

		it("does nothing on Enter with no result selected", async () => {
			const input = await searchAndGetInput();
			fireEvent.keyDown(input, { key: "Enter" });
			expect(screen.getByTestId("path").textContent).toBe("/");
		});

		// Retyping has to drop the highlight, or Enter opens a result from the
		// PREVIOUS query that is no longer on screen.
		it("clears the selection when the query changes", async () => {
			const input = await searchAndGetInput();
			fireEvent.keyDown(input, { key: "ArrowDown" });
			fireEvent.change(input, { target: { value: "hello t" } });
			expect(document.querySelector("[data-active-result='true']")).toBeNull();
		});
	});
});
