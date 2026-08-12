import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { fireEvent, render, screen } from "@testing-library/react";
import { MemoryRouter, useLocation } from "react-router";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
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
	// Folder.name is the FULL path, which is why the picker can use it directly.
	useFolders: () => ({ data: [{ id: "f1", parent_id: null, name: "Archive", count: 2 }] }),
	useTags: () => ({ data: ["project", "reading"] }),
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
		// Presets resolve against the current date, so pin it — but fake ONLY
		// Date. Faking setTimeout too would freeze the 300ms search debounce and
		// no query would ever fire.
		vi.useFakeTimers({ toFake: ["Date"] });
		vi.setSystemTime(new Date("2026-08-11T13:45:00Z"));
		window.localStorage.clear();
		useSearchSpy.mockClear();
		activeSlugMock.mockReturnValue(null);
	});

	afterEach(() => {
		vi.useRealTimers();
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
		const typeInput = screen.getByLabelText(/^type$/iu);
		fireEvent.change(typeInput, { target: { value: "Playbook" } });

		expect(useSearchSpy).toHaveBeenLastCalledWith("", { type: "Playbook" });
	});

	// Four identical unlabelled date boxes became one row of relative-time chips,
	// with the exact range kept behind "Custom…" for the rare case that needs it.
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

		it("keeps the filter fields out of the way until asked", () => {
			renderPanel();
			expect(screen.queryByRole("radio", { name: "7 days" })).toBeNull();
		});

		it("offers relative-time presets instead of date boxes", () => {
			renderPanel();
			openFilters();
			for (const name of ["Any time", "7 days", "30 days", "This year", "Custom…"]) {
				expect(screen.getByRole("radio", { name })).toBeInTheDocument();
			}
			// The whole point: no date input at all until Custom is chosen.
			expect(screen.queryByLabelText(/^from$/iu)).toBeNull();
		});

		it("starts on Any time and sends no date filter", () => {
			renderPanel();
			openFilters();
			expect(screen.getByRole("radio", { name: "Any time" })).toBeChecked();
			expect(useSearchSpy).toHaveBeenLastCalledWith("", {});
		});

		it("turns a preset into a midnight-UTC boundary on the updated field", () => {
			renderPanel();
			openFilters();
			fireEvent.click(screen.getByRole("radio", { name: "7 days" }));
			expect(useSearchSpy).toHaveBeenLastCalledWith("", {
				updatedAfter: "2026-08-04T00:00:00.000Z",
			});
		});

		it("anchors This year to January 1st", () => {
			renderPanel();
			openFilters();
			fireEvent.click(screen.getByRole("radio", { name: "This year" }));
			expect(useSearchSpy).toHaveBeenLastCalledWith("", {
				updatedAfter: "2026-01-01T00:00:00.000Z",
			});
		});

		it("reveals the exact range only once Custom is picked", () => {
			renderPanel();
			openFilters();
			fireEvent.click(screen.getByRole("radio", { name: "Custom…" }));
			expect(screen.getByLabelText(/^from$/iu)).toBeInTheDocument();
			expect(screen.getByLabelText(/^to$/iu)).toBeInTheDocument();
		});

		it("sends a custom range as after/before", () => {
			renderPanel();
			openFilters();
			fireEvent.click(screen.getByRole("radio", { name: "Custom…" }));
			fireEvent.change(screen.getByLabelText(/^from$/iu), { target: { value: "2026-01-01" } });
			fireEvent.change(screen.getByLabelText(/^to$/iu), { target: { value: "2026-02-01" } });
			expect(useSearchSpy).toHaveBeenLastCalledWith("", {
				updatedAfter: "2026-01-01T00:00:00Z",
				updatedBefore: "2026-02-01T00:00:00Z",
			});
		});

		// The created/updated choice is the other half of the old cross-product;
		// it now appears only where it is actually useful.
		it("switches the range onto the created field", () => {
			renderPanel();
			openFilters();
			fireEvent.click(screen.getByRole("radio", { name: "Custom…" }));
			fireEvent.change(screen.getByLabelText(/^from$/iu), { target: { value: "2026-01-01" } });
			fireEvent.click(screen.getByRole("radio", { name: "Created" }));
			expect(useSearchSpy).toHaveBeenLastCalledWith("", { createdAfter: "2026-01-01T00:00:00Z" });
		});

		it("drops the custom dates when a preset is picked again", () => {
			renderPanel();
			openFilters();
			fireEvent.click(screen.getByRole("radio", { name: "Custom…" }));
			fireEvent.change(screen.getByLabelText(/^from$/iu), { target: { value: "2026-01-01" } });
			fireEvent.click(screen.getByRole("radio", { name: "Any time" }));
			expect(useSearchSpy).toHaveBeenLastCalledWith("", {});
		});

		// One user-facing filter, even though it becomes two payload keys.
		it("counts a custom range as ONE filter, not two", () => {
			renderPanel();
			openFilters();
			fireEvent.click(screen.getByRole("radio", { name: "Custom…" }));
			fireEvent.change(screen.getByLabelText(/^from$/iu), { target: { value: "2026-01-01" } });
			fireEvent.change(screen.getByLabelText(/^to$/iu), { target: { value: "2026-02-01" } });
			expect(screen.getByRole("button", { name: /^filters/iu })).toHaveTextContent("1");
		});

		it("counts the type and the date group together", () => {
			renderPanel();
			openFilters();
			fireEvent.change(screen.getByLabelText(/^type$/iu), { target: { value: "Playbook" } });
			fireEvent.click(screen.getByRole("radio", { name: "7 days" }));
			expect(screen.getByRole("button", { name: /^filters/iu })).toHaveTextContent("2");
		});

		// Custom with no dates yet constrains nothing, so it must not read as on.
		it("does not count Custom until a date is actually entered", () => {
			renderPanel();
			openFilters();
			fireEvent.click(screen.getByRole("radio", { name: "Custom…" }));
			expect(screen.getByRole("button", { name: /^filters/iu })).not.toHaveTextContent(/[0-9]/u);
		});

		it("shows no count when nothing is filtered", () => {
			renderPanel();
			expect(screen.getByRole("button", { name: /^filters/iu })).not.toHaveTextContent(/[0-9]/u);
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

		it("clears everything at once and re-fires the search", () => {
			renderPanel();
			openFilters();
			fireEvent.change(screen.getByLabelText(/^type$/iu), { target: { value: "Playbook" } });
			fireEvent.click(screen.getByRole("radio", { name: "7 days" }));
			fireEvent.click(screen.getByRole("button", { name: /clear filters/iu }));
			expect(useSearchSpy).toHaveBeenLastCalledWith("", {});
			expect(screen.getByRole("radio", { name: "Any time" })).toBeChecked();
		});

		// Both fields read frontmatter, not anything the user can see in the note
		// body or the file system — which is surprising enough to explain in place.
		describe("help", () => {
			it("hides the explanations until asked", () => {
				renderPanel();
				openFilters();
				expect(screen.queryByText(/frontmatter/iu)).toBeNull();
			});

			it("explains where the type value comes from", () => {
				renderPanel();
				openFilters();
				fireEvent.click(screen.getByRole("button", { name: /what is type/iu }));
				expect(screen.getByText(/frontmatter/iu)).toBeInTheDocument();
			});

			it("warns that the date is the frontmatter one, not the file's", () => {
				renderPanel();
				openFilters();
				fireEvent.click(screen.getByRole("button", { name: /what does modified mean/iu }));
				expect(screen.getByText(/frontmatter/iu)).toBeInTheDocument();
			});

			it("closes again on a second press", () => {
				renderPanel();
				openFilters();
				const help = screen.getByRole("button", { name: /what is type/iu });
				fireEvent.click(help);
				fireEvent.click(help);
				expect(screen.queryByText(/frontmatter/iu)).toBeNull();
			});

			it("marks the toggle as expanded so it is not a mystery button", () => {
				renderPanel();
				openFilters();
				const help = screen.getByRole("button", { name: /what is type/iu });
				expect(help).toHaveAttribute("aria-expanded", "false");
				fireEvent.click(help);
				expect(help).toHaveAttribute("aria-expanded", "true");
			});
		});

		// type is a blind text field because nothing enumerates the types in a
		// vault; folders and tags DO have an inventory, so they get real pickers.
		describe("folder and tags", () => {
			it("offers the vault's folders rather than a text box", () => {
				renderPanel();
				openFilters();
				const folder = screen.getByLabelText(/^folder$/iu) as HTMLSelectElement;
				expect([...folder.options].map((o) => o.textContent)).toEqual(["Any folder", "Archive"]);
			});

			it("narrows to the chosen folder", () => {
				renderPanel();
				openFilters();
				fireEvent.change(screen.getByLabelText(/^folder$/iu), { target: { value: "Archive" } });
				expect(useSearchSpy).toHaveBeenLastCalledWith("", { folder: "Archive" });
			});

			it("sends no folder for Any folder", () => {
				renderPanel();
				openFilters();
				fireEvent.change(screen.getByLabelText(/^folder$/iu), { target: { value: "Archive" } });
				fireEvent.change(screen.getByLabelText(/^folder$/iu), { target: { value: "" } });
				expect(useSearchSpy).toHaveBeenLastCalledWith("", {});
			});

			it("adds a tag as a removable chip", () => {
				renderPanel();
				openFilters();
				fireEvent.change(screen.getByLabelText(/add tag/iu), { target: { value: "project" } });
				expect(useSearchSpy).toHaveBeenLastCalledWith("", { tags: ["project"] });
				expect(screen.getByRole("button", { name: /remove project/iu })).toBeInTheDocument();
			});

			it("accumulates tags instead of replacing them", () => {
				renderPanel();
				openFilters();
				fireEvent.change(screen.getByLabelText(/add tag/iu), { target: { value: "project" } });
				fireEvent.change(screen.getByLabelText(/add tag/iu), { target: { value: "reading" } });
				expect(useSearchSpy).toHaveBeenLastCalledWith("", { tags: ["project", "reading"] });
			});

			it("drops a tag when its chip is removed", () => {
				renderPanel();
				openFilters();
				fireEvent.change(screen.getByLabelText(/add tag/iu), { target: { value: "project" } });
				fireEvent.click(screen.getByRole("button", { name: /remove project/iu }));
				expect(useSearchSpy).toHaveBeenLastCalledWith("", {});
			});

			// Picking the same tag twice would otherwise send it twice.
			it("does not add the same tag twice", () => {
				renderPanel();
				openFilters();
				fireEvent.change(screen.getByLabelText(/add tag/iu), { target: { value: "project" } });
				fireEvent.change(screen.getByLabelText(/add tag/iu), { target: { value: "project" } });
				expect(useSearchSpy).toHaveBeenLastCalledWith("", { tags: ["project"] });
			});

			// However many tags are chosen, it is one filter to the user.
			it("counts all the tags as a single filter", () => {
				renderPanel();
				openFilters();
				fireEvent.change(screen.getByLabelText(/add tag/iu), { target: { value: "project" } });
				fireEvent.change(screen.getByLabelText(/add tag/iu), { target: { value: "reading" } });
				expect(screen.getByRole("button", { name: /^filters/iu })).toHaveTextContent("1");
			});

			it("clears folder and tags along with the rest", () => {
				renderPanel();
				openFilters();
				fireEvent.change(screen.getByLabelText(/^folder$/iu), { target: { value: "Archive" } });
				fireEvent.change(screen.getByLabelText(/add tag/iu), { target: { value: "project" } });
				fireEvent.click(screen.getByRole("button", { name: /clear filters/iu }));
				expect(useSearchSpy).toHaveBeenLastCalledWith("", {});
			});
		});

		it("offers nothing to clear when nothing is set", () => {
			renderPanel();
			openFilters();
			expect(screen.queryByRole("button", { name: /clear filters/iu })).toBeNull();
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
