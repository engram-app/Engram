import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { fireEvent, render, screen, within } from "@testing-library/react";
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
	useIndexStatus: () => ({ data: indexStatusMock() }),
	// Folder.name is the FULL path, which is why the picker can use it directly.
	useFolders: () => ({ data: [{ id: "f1", parent_id: null, name: "Archive", count: 2 }] }),
	useTags: () => ({ data: ["project", "reading"] }),
	useTypes: () => ({ data: ["meeting", "playbook"] }),
}));

// ResultRow reads the active vault slug to build note hrefs. Default to null
// (the fallback/legacy shape) so existing behavior is unaffected; the one
// test below overrides it to check the vault-scoped shape.
// Cache-only in real use. `undefined` = bootstrap has not seeded yet, which is
// the state where the index-cap hint must NOT render.
const indexStatusMock = vi.hoisted(() =>
	vi.fn<() => { indexed: number; total: number } | undefined>(() => undefined),
);

const activeSlugMock = vi.fn<() => string | null>(() => null);
vi.mock("../api/vault-slug", () => ({ useActiveVaultSlug: () => activeSlugMock() }));

function PathProbe() {
	const loc = useLocation();
	return <span data-testid="path">{loc.pathname}</span>;
}

/**
 * Open a filter combobox and pick a value.
 *
 * The input IS the trigger here — that is the whole point of the shadcn
 * Combobox over the popover-plus-separate-field shape this replaced — so
 * there is no button to click first.
 */
function chooseIn(fieldLabel: string, value: string) {
	const input = openField(fieldLabel);
	fireEvent.change(input, { target: { value } });
	const option = screen.getAllByRole("option").find((o) => o.textContent === value);
	if (!option) {
		throw new Error(`no option for "${value}" in ${fieldLabel}`);
	}
	fireEvent.click(option);
}

/**
 * Open a combobox's list and hand back its input.
 *
 * pointerDown, NOT click: fireEvent.click dispatches only a click event, while
 * the combobox opens on pointerdown (so it can track a press-drag-release
 * selection). A click-only test sees a permanently closed list.
 */
function openField(fieldLabel: string): HTMLElement {
	const input = screen.getByRole("combobox", { name: fieldLabel });
	fireEvent.pointerDown(input);
	fireEvent.mouseDown(input);
	fireEvent.click(input);
	return input;
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
		expect(link.getAttribute("href")).toBe("/v/work/7");
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
		chooseIn("Type", "playbook");

		expect(useSearchSpy).toHaveBeenLastCalledWith("", { type: "playbook" });
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
			chooseIn("Type", "playbook");
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
			chooseIn("Type", "playbook");
			expect(screen.getByRole("button", { name: /^filters/iu })).toHaveAttribute(
				"aria-label",
				"Filters, 1 active",
			);
		});

		it("clears everything at once and re-fires the search", () => {
			renderPanel();
			openFilters();
			chooseIn("Type", "playbook");
			fireEvent.click(screen.getByRole("radio", { name: "7 days" }));
			fireEvent.click(screen.getByRole("button", { name: /clear filters/iu }));
			expect(useSearchSpy).toHaveBeenLastCalledWith("", {});
			expect(screen.getByRole("radio", { name: "Any time" })).toBeChecked();
		});

		// Both fields read frontmatter, not anything the user can see in the note
		// body or the file system — which is surprising enough to explain in place.
		describe("help", () => {
			it("hides the explanation until the ? is pressed", () => {
				renderPanel();
				openFilters();
				expect(screen.queryByText(/index/iu)).toBeNull();
			});

			// A popover, so the panel does not reflow and shove the fields down
			// every time someone checks what a filter means.
			it("opens the type explanation in a popover", async () => {
				renderPanel();
				openFilters();
				fireEvent.click(screen.getByRole("button", { name: /what is type/iu }));
				expect(await screen.findByRole("dialog")).toHaveTextContent(/index/iu);
			});

			it("explains type by what it does for search, not by teaching YAML", async () => {
				renderPanel();
				openFilters();
				fireEvent.click(screen.getByRole("button", { name: /what is type/iu }));
				const help = await screen.findByRole("dialog");
				expect(help).toHaveTextContent(/improve/iu);
				expect(help.textContent).not.toMatch(/yaml/iu);
			});

			// `type` is the ONE field OKF requires, which is the real reason it is
			// worth filling in — say so, and link the spec.
			it("ties type to the Open Knowledge Format and links the spec", async () => {
				renderPanel();
				openFilters();
				fireEvent.click(screen.getByRole("button", { name: /what is type/iu }));
				const help = await screen.findByRole("dialog");
				expect(help).toHaveTextContent(/open knowledge format/iu);
				const link = within(help).getByRole("link");
				expect(link).toHaveAttribute(
					"href",
					"https://github.com/GoogleCloudPlatform/knowledge-catalog/tree/main/okf",
				);
				// An external tab, and no window.opener handed to it.
				expect(link).toHaveAttribute("target", "_blank");
				expect(link.getAttribute("rel")).toMatch(/noreferrer/u);
			});

			it("explains the date filter the same way", async () => {
				renderPanel();
				openFilters();
				fireEvent.click(screen.getByRole("button", { name: /what does modified mean/iu }));
				expect(await screen.findByRole("dialog")).toBeInTheDocument();
			});
		});

		// Typed, not picked: folders and tags are long lists, and a user may be
		// narrowing to something the cached inventory has not caught up with.
		// The known values are offered as suggestions rather than as the only
		// options.
		// All three filter fields share one combobox: it opens showing everything
		// the vault already contains and narrows as you type, while still
		// accepting a value the cached inventory has never seen.
		// All three fields dropped their free-text "Use …" escape hatch when they
		// moved to the real Combobox. Not an oversight: every inventory here is
		// COMPLETE — /folders, /tags and /types each enumerate the whole vault —
		// so a value absent from the list is a value no note carries, and
		// filtering on it could only ever return zero results. The empty state
		// says so instead of pretending the search is worth running.
		describe("folder and tags", () => {
			it("shows the vault's folders as soon as the field is opened", () => {
				renderPanel();
				openFilters();
				openField("Folder");
				expect(screen.getAllByRole("option").map((o) => o.textContent)).toEqual(["Archive"]);
			});

			it("narrows the list as you type", () => {
				renderPanel();
				openFilters();
				const input = openField("Folder");
				fireEvent.change(input, { target: { value: "zzz" } });
				expect(screen.queryAllByRole("option")).toEqual([]);
				expect(screen.getByText("No matching folder")).toBeInTheDocument();
			});

			it("narrows to the chosen folder", () => {
				renderPanel();
				openFilters();
				chooseIn("Folder", "Archive");
				expect(useSearchSpy).toHaveBeenLastCalledWith("", { folder: "Archive" });
			});

			it("adds a chosen tag as a removable chip", () => {
				renderPanel();
				openFilters();
				chooseIn("Tags", "project");
				expect(useSearchSpy).toHaveBeenLastCalledWith("", { tags: ["project"] });
				expect(screen.getByRole("button", { name: /remove project/iu })).toBeInTheDocument();
			});

			it("accumulates tags instead of replacing them", () => {
				renderPanel();
				openFilters();
				chooseIn("Tags", "project");
				chooseIn("Tags", "reading");
				expect(useSearchSpy).toHaveBeenLastCalledWith("", { tags: ["project", "reading"] });
			});

			// Chosen tags STAY in the list, marked selected, so picking one again
			// turns it off — the chips below the field are not the only way out.
			it("toggles a chosen tag back off from the list", () => {
				renderPanel();
				openFilters();
				chooseIn("Tags", "project");
				chooseIn("Tags", "project");
				expect(useSearchSpy).toHaveBeenLastCalledWith("", {});
			});

			it("drops a tag when its chip is removed", () => {
				renderPanel();
				openFilters();
				chooseIn("Tags", "project");
				fireEvent.click(screen.getByRole("button", { name: /remove project/iu }));
				expect(useSearchSpy).toHaveBeenLastCalledWith("", {});
			});

			it("counts all the tags as a single filter", () => {
				renderPanel();
				openFilters();
				chooseIn("Tags", "project");
				chooseIn("Tags", "reading");
				expect(screen.getByRole("button", { name: /^filters/iu })).toHaveTextContent("1");
			});

			it("clears folder and tags along with the rest", () => {
				renderPanel();
				openFilters();
				chooseIn("Folder", "Archive");
				chooseIn("Tags", "project");
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

	// Guards the coupling behind a bug that was invisible on desktop and total
	// on mobile.
	//
	// Base UI portals the combobox popup to <body> and does NOT join Radix's
	// dismissable-layer stack. On mobile this panel lives inside a modal Radix
	// Sheet, which sets `body { pointer-events: none }`, so every option
	// inherited none: the list opened, a tap hit-tested straight through to
	// whatever was underneath, and Base UI read it as an outside press. All
	// three filters were unusable by touch.
	//
	// main.css re-enables hit-testing via `[data-slot="combobox-content"]`.
	// happy-dom has no layout engine and does not cascade pointer-events, so the
	// inheritance itself cannot be reproduced here — what IS worth pinning is
	// the selector's anchor: if the vendored component renames or drops that
	// data-slot, the fence silently stops matching and mobile breaks again with
	// no other signal.
	describe("mobile pointer-events fence", () => {
		it("keeps the data-slot main.css hangs the fence on", () => {
			renderPanel();
			fireEvent.click(screen.getByRole("button", { name: /^filters/iu }));
			openField("Folder");
			expect(document.querySelector('[data-slot="combobox-content"]')).not.toBeNull();
		});
	});

	describe("indexed-note cap hint", () => {
		afterEach(() => indexStatusMock.mockReturnValue(undefined));

		it("tells the user how many notes are searchable when they are capped", async () => {
			indexStatusMock.mockReturnValue({ indexed: 2000, total: 4312 });
			useSearchSpy.mockReturnValue({ data: [], isLoading: false, error: null });
			renderPanel();

			fireEvent.change(screen.getByPlaceholderText(/search your notes/iu), {
				target: { value: "hi" },
			});

			// Without this the only signal is an empty result list, which reads as
			// "search is broken" rather than "this note is not indexed".
			expect(await screen.findByText(/Searching 2,000 of 4,312 notes/u)).toBeInTheDocument();
			expect(
				screen.getByRole("link", { name: /upgrade to search everything/iu }),
			).toBeInTheDocument();
		});

		it("stays silent when every note is indexed", async () => {
			indexStatusMock.mockReturnValue({ indexed: 812, total: 812 });
			useSearchSpy.mockReturnValue({ data: [], isLoading: false, error: null });
			renderPanel();

			fireEvent.change(screen.getByPlaceholderText(/search your notes/iu), {
				target: { value: "hi" },
			});

			expect(await screen.findByText(/No results for/u)).toBeInTheDocument();
			expect(screen.queryByText(/of 812 notes/u)).not.toBeInTheDocument();
		});
	});
});
