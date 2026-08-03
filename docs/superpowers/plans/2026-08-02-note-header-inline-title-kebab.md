# Note Page Inline Title + Kebab Menu Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the web SPA note page read like Obsidian — a thin chrome bar, a large document title that scrolls with the content above the frontmatter, and a kebab menu that absorbs the view-mode toggle plus the file actions.

**Architecture:** CodeMirror currently owns its own scrollbar (`height: 100%` + `.cm-scroller { overflow: auto }`), which is why anything rendered above it stays pinned. We flip CodeMirror to grow with its content (`height: auto`, `overflow: visible`) and give `note-page.tsx` a single `ScrollArea` that wraps title, properties, and body for all three view modes. The kebab reuses the file tree's existing action vocabulary (`action-list.ts`) and its existing dialogs (`MoveDialog`, `DeleteConfirm`, `RenameInput`) rather than inventing new ones.

**Tech Stack:** React 19, TypeScript, Vite, Tailwind, shadcn/ui (Radix), CodeMirror 6, Yjs, TanStack Query, react-router 8, Vitest + Testing Library.

## Global Constraints

- Spec: Engram vault → `50 Engineering/_Superpowers Specs/2026-08-02-note-header-inline-title-kebab-design.md`.
- Repo: `engram` (Elixir app root; frontend lives at `frontend/`). Worktree: `.worktrees/feat-note-header-kebab`, branch `feat/note-header-inline-title-kebab`.
- All commands run from `frontend/`. Test runner is `bun run test` (`vitest run`). Lint is `./node_modules/.bin/biome ci .` — never `bunx biome` (wrong version).
- **NO version bumps.** release-please owns versioning.
- TDD is mandatory: write the failing test, watch it fail, then implement.
- Conventional commits, subject under 50 chars.
- Do not modify tests to make bad code pass. Fix the implementation.
- Baseline at branch point: 167 test files, 1166 tests, 0 failures. Any red at the end is in scope, not "pre-existing".
- Out of scope: hiding the formatting toolbar (Unit B), frontmatter-on-demand via `---` (Unit C). `EditorToolbar` stays exactly where it is.

---

### Task 1: Extend the action vocabulary

The kebab shows the file actions plus "Add property" plus the three view modes. On mobile it reuses `ActionDrawer`, which does `const Icon = ACTION_ICONS[a.id]` and then renders `<Icon />` — an id with no icon entry renders `undefined` and throws. So every id the kebab can show must exist in `ActionId` and `ACTION_ICONS`.

Adding ids to the union does **not** leak them into the tree's menus: `actionsFor()` is the gate that decides what each surface lists, and it is left untouched.

**Files:**
- Modify: `frontend/src/viewer/tree-actions/action-list.ts`
- Test: `frontend/src/viewer/tree-actions/action-list.test.ts`

**Interfaces:**
- Consumes: nothing.
- Produces: `ActionId` gains `"add-property" | "view-rendered" | "view-raw" | "view-reading"`; `ACTION_ICONS` gains entries for all four; new export `noteMenuActions(mode: "rendered" | "raw" | "reading"): readonly Action[]`.

- [ ] **Step 1: Write the failing test**

Append to `frontend/src/viewer/tree-actions/action-list.test.ts`:

```ts
import { ACTION_ICONS, actionsFor, noteMenuActions } from "./action-list";

describe("noteMenuActions", () => {
	it("lists the three view modes, the file actions, and add-property", () => {
		const ids = noteMenuActions("rendered").map((a) => a.id);
		expect(ids).toEqual([
			"view-rendered",
			"view-raw",
			"view-reading",
			"rename",
			"move",
			"duplicate",
			"copy-wikilink",
			"add-property",
			"delete",
		]);
	});

	it("marks the active mode so the menu can show a checkmark", () => {
		const raw = noteMenuActions("raw").find((a) => a.id === "view-raw");
		const rendered = noteMenuActions("raw").find((a) => a.id === "view-rendered");
		expect(raw?.active).toBe(true);
		expect(rendered?.active).toBe(false);
	});

	// ActionDrawer renders ACTION_ICONS[id] unconditionally — a missing entry
	// is a crash, not a degraded menu.
	it("has an icon for every action it can render", () => {
		for (const action of noteMenuActions("rendered")) {
			expect(ACTION_ICONS[action.id]).toBeDefined();
		}
	});

	// The tree's menus must not grow the new entries.
	it("leaves the tree's file menu unchanged", () => {
		const ids = actionsFor({ kind: "file" }).map((a) => a.id);
		expect(ids).toEqual(["rename", "move", "duplicate", "copy-wikilink", "delete"]);
	});
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bun run test -- action-list`
Expected: FAIL — `noteMenuActions is not a function`.

- [ ] **Step 3: Write minimal implementation**

In `frontend/src/viewer/tree-actions/action-list.ts`, extend the icon import, the union, the icon map, and add the builder.

Change the lucide import to add the four new icons:

```ts
import {
	Copy,
	Eye,
	FilePlus,
	FileText,
	FolderInput,
	FolderPlus,
	Link2,
	ListPlus,
	type LucideIcon,
	Pencil,
	SquareCode,
	Trash2,
} from "lucide-react";
```

Extend the union:

```ts
export type ActionId =
	| "new-note"
	| "new-folder"
	| "rename"
	| "move"
	| "duplicate"
	| "copy-wikilink"
	| "delete"
	| "add-property"
	| "view-rendered"
	| "view-raw"
	| "view-reading";
```

Add an `active` flag to `Action` (used only by the note menu; the tree never sets it):

```ts
export interface Action {
	id: ActionId;
	label: string;
	destructive?: boolean;
	/** Set by `noteMenuActions` for the current view mode. The tree omits it. */
	active?: boolean;
}
```

Extend the icon map:

```ts
const ACTION_ICONS: Record<ActionId, LucideIcon> = {
	"new-note": FilePlus,
	"new-folder": FolderPlus,
	rename: Pencil,
	move: FolderInput,
	duplicate: Copy,
	"copy-wikilink": Link2,
	delete: Trash2,
	"add-property": ListPlus,
	"view-rendered": FileText,
	"view-raw": SquareCode,
	"view-reading": Eye,
};
```

Append the builder at the end of the file, before the `export { ACTION_ICONS }` line:

```ts
export type ViewMode = "rendered" | "raw" | "reading";

// The note page's kebab. Deliberately NOT part of `actionsFor` — that function
// answers "what can you do to a tree node", and the view modes are a property
// of the open editor, not of the file.
export function noteMenuActions(mode: ViewMode): readonly Action[] {
	return [
		{ id: "view-rendered", label: "Rendered", active: mode === "rendered" },
		{ id: "view-raw", label: "Raw", active: mode === "raw" },
		{ id: "view-reading", label: "Reading", active: mode === "reading" },
		{ id: "rename", label: "Rename" },
		{ id: "move", label: "Move to…" },
		{ id: "duplicate", label: "Duplicate" },
		{ id: "copy-wikilink", label: "Copy wikilink" },
		{ id: "add-property", label: "Add property" },
		{ id: "delete", label: "Delete", destructive: true },
	];
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bun run test -- action-list`
Expected: PASS, including the pre-existing `actionsFor` tests.

- [ ] **Step 5: Commit**

```bash
git add frontend/src/viewer/tree-actions/action-list.ts frontend/src/viewer/tree-actions/action-list.test.ts
git commit -m "feat(editor): add note-menu action vocabulary"
```

---

### Task 2: InlineTitle component

A presentational title that swaps to the existing `RenameInput` when renaming. `RenameInput` already calls `el.focus()` and `el.setSelectionRange(0, initial.length)` on mount, so selection-on-open needs no work here.

**Files:**
- Create: `frontend/src/viewer/inline-title.tsx`
- Test: `frontend/src/viewer/inline-title.test.tsx`

**Interfaces:**
- Consumes: `RenameInput` from `./tree-actions/rename-input`.
- Produces: `InlineTitle({ name, renaming, onStartRename, onCommitRename, onCancelRename })`.

- [ ] **Step 1: Write the failing test**

Create `frontend/src/viewer/inline-title.test.tsx`:

```tsx
import { fireEvent, render, screen } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";
import { InlineTitle } from "./inline-title";

const props = {
	name: "My Note",
	renaming: false,
	onStartRename: vi.fn(),
	onCommitRename: vi.fn(),
	onCancelRename: vi.fn(),
};

describe("InlineTitle", () => {
	it("renders the name as a level-1 heading", () => {
		render(<InlineTitle {...props} />);
		expect(screen.getByRole("heading", { level: 1 })).toHaveTextContent("My Note");
	});

	it("starts a rename when clicked", () => {
		const onStartRename = vi.fn();
		render(<InlineTitle {...props} onStartRename={onStartRename} />);
		fireEvent.click(screen.getByRole("button", { name: "My Note" }));
		expect(onStartRename).toHaveBeenCalled();
	});

	it("shows an input seeded with the name, fully selected, while renaming", () => {
		render(<InlineTitle {...props} renaming />);
		const input = screen.getByRole("textbox") as HTMLInputElement;
		expect(input.value).toBe("My Note");
		// Typing must replace the name, which is what the selection buys.
		expect(input.selectionStart).toBe(0);
		expect(input.selectionEnd).toBe("My Note".length);
	});

	it("commits the typed name on Enter", () => {
		const onCommitRename = vi.fn();
		render(<InlineTitle {...props} renaming onCommitRename={onCommitRename} />);
		const input = screen.getByRole("textbox");
		fireEvent.change(input, { target: { value: "Renamed" } });
		fireEvent.keyDown(input, { key: "Enter" });
		expect(onCommitRename).toHaveBeenCalledWith("Renamed");
	});
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bun run test -- inline-title`
Expected: FAIL — cannot resolve `./inline-title`.

- [ ] **Step 3: Write minimal implementation**

Create `frontend/src/viewer/inline-title.tsx`:

```tsx
import { RenameInput } from "./tree-actions/rename-input";

interface Props {
	/** Base name, no extension — the caller strips it. */
	name: string;
	renaming: boolean;
	onStartRename: () => void;
	onCommitRename: (next: string) => void;
	onCancelRename: () => void;
}

/**
 * Obsidian-style inline title: part of the document flow, not the chrome, so
 * it scrolls away with the content. Click to rename — `commitOnBlur` because
 * this reads as a title field you retype and then click into the body from,
 * where losing the edit would be a surprise.
 */
export function InlineTitle({
	name,
	renaming,
	onStartRename,
	onCommitRename,
	onCancelRename,
}: Props) {
	return (
		<h1 className="px-5 pt-6 pb-1 font-semibold text-3xl tracking-tight">
			{renaming ? (
				<RenameInput
					initial={name}
					kind="file"
					commitOnBlur
					onCommit={onCommitRename}
					onCancel={onCancelRename}
				/>
			) : (
				<button
					type="button"
					// -mx-1 cancels the padding so the hover target is roomier than the
					// text without shifting the title off the left margin.
					className="-mx-1 block w-full truncate rounded px-1 text-left hover:bg-accent"
					title="Click to rename"
					onClick={onStartRename}
				>
					{name}
				</button>
			)}
		</h1>
	);
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bun run test -- inline-title`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add frontend/src/viewer/inline-title.tsx frontend/src/viewer/inline-title.test.tsx
git commit -m "feat(editor): add InlineTitle component"
```

---

### Task 3: NoteMenu component

Desktop renders a Radix dropdown; mobile renders the existing `ActionDrawer` bottom sheet, matching the file tree's long-press behaviour.

**Files:**
- Create: `frontend/src/viewer/note-menu.tsx`
- Test: `frontend/src/viewer/note-menu.test.tsx`

**Interfaces:**
- Consumes: `noteMenuActions`, `ACTION_ICONS`, `ActionId`, `ViewMode` from Task 1; `ActionDrawer`; `useMediaQuery` from `@/hooks/use-media-query`.
- Produces: `NoteMenu({ mode, title, onPick })` where `onPick: (id: ActionId) => void`.

- [ ] **Step 1: Write the failing test**

Create `frontend/src/viewer/note-menu.test.tsx`:

```tsx
import { fireEvent, render, screen } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { NoteMenu } from "./note-menu";

const matches = vi.fn();
vi.mock("@/hooks/use-media-query", () => ({
	useMediaQuery: () => matches(),
}));

describe("NoteMenu", () => {
	beforeEach(() => {
		vi.clearAllMocks();
		matches.mockReturnValue(true); // desktop by default
	});

	it("opens a dropdown on desktop and reports the picked action", () => {
		const onPick = vi.fn();
		render(<NoteMenu mode="rendered" title="note" onPick={onPick} />);
		fireEvent.click(screen.getByRole("button", { name: "Note options" }));
		fireEvent.click(screen.getByRole("menuitem", { name: "Duplicate" }));
		expect(onPick).toHaveBeenCalledWith("duplicate");
	});

	it("marks the active view mode", () => {
		render(<NoteMenu mode="raw" title="note" onPick={vi.fn()} />);
		fireEvent.click(screen.getByRole("button", { name: "Note options" }));
		expect(screen.getByRole("menuitem", { name: "Raw" })).toHaveAttribute(
			"aria-current",
			"true",
		);
	});

	it("uses the bottom-sheet drawer on mobile", () => {
		matches.mockReturnValue(false);
		const onPick = vi.fn();
		render(<NoteMenu mode="rendered" title="note" onPick={onPick} />);
		fireEvent.click(screen.getByRole("button", { name: "Note options" }));
		// The drawer renders its own backdrop; the dropdown does not.
		expect(screen.getByTestId("action-drawer-backdrop")).toBeInTheDocument();
		fireEvent.click(screen.getByRole("menuitem", { name: "Delete" }));
		expect(onPick).toHaveBeenCalledWith("delete");
	});

	it("closes the drawer after a pick", () => {
		matches.mockReturnValue(false);
		render(<NoteMenu mode="rendered" title="note" onPick={vi.fn()} />);
		fireEvent.click(screen.getByRole("button", { name: "Note options" }));
		fireEvent.click(screen.getByRole("menuitem", { name: "Rename" }));
		expect(screen.queryByTestId("action-drawer-backdrop")).not.toBeInTheDocument();
	});
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bun run test -- note-menu`
Expected: FAIL — cannot resolve `./note-menu`.

- [ ] **Step 3: Write minimal implementation**

Create `frontend/src/viewer/note-menu.tsx`:

```tsx
import { MoreVertical } from "lucide-react";
import { useState } from "react";
import { Button } from "@/components/ui/button";
import {
	DropdownMenu,
	DropdownMenuContent,
	DropdownMenuItem,
	DropdownMenuSeparator,
	DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu";
import { useMediaQuery } from "@/hooks/use-media-query";
import { ActionDrawer } from "./tree-actions/action-drawer";
import { ACTION_ICONS, type ActionId, noteMenuActions, type ViewMode } from "./tree-actions/action-list";

interface Props {
	mode: ViewMode;
	/** Shown as the drawer's heading on mobile. */
	title: string;
	onPick: (id: ActionId) => void;
}

/**
 * The note page's kebab. Desktop gets a dropdown; mobile gets the same
 * bottom-sheet the file tree already uses on long-press, so the two menu
 * surfaces in the app behave identically on touch.
 */
export function NoteMenu({ mode, title, onPick }: Props) {
	const isDesktop = useMediaQuery("(min-width: 768px)");
	const [drawerOpen, setDrawerOpen] = useState(false);
	const actions = noteMenuActions(mode);

	if (!isDesktop) {
		return (
			<>
				<Button
					variant="ghost"
					size="icon"
					aria-label="Note options"
					onClick={() => setDrawerOpen(true)}
				>
					<MoreVertical className="size-4" />
				</Button>
				{drawerOpen ? (
					<ActionDrawer
						title={title}
						actions={actions}
						onPick={onPick}
						onClose={() => setDrawerOpen(false)}
					/>
				) : null}
			</>
		);
	}

	return (
		<DropdownMenu>
			<DropdownMenuTrigger asChild>
				<Button variant="ghost" size="icon" aria-label="Note options">
					<MoreVertical className="size-4" />
				</Button>
			</DropdownMenuTrigger>
			<DropdownMenuContent align="end">
				{actions.map((action, i) => {
					const Icon = ACTION_ICONS[action.id];
					// Separate the view-mode group from the file actions, and the
					// destructive one from everything above it.
					const separatorBefore = action.id === "rename" || action.destructive;
					return (
						<div key={action.id} className="contents">
							{separatorBefore && i > 0 ? <DropdownMenuSeparator /> : null}
							<DropdownMenuItem
								// aria-current rather than a checkbox item: the modes are a
								// single-select group, and this keeps one code path for
								// every row in the menu.
								aria-current={action.active ? "true" : undefined}
								variant={action.destructive ? "destructive" : "default"}
								onSelect={() => onPick(action.id)}
							>
								<Icon aria-hidden="true" className="size-4" />
								{action.label}
							</DropdownMenuItem>
						</div>
					);
				})}
			</DropdownMenuContent>
		</DropdownMenu>
	);
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bun run test -- note-menu`
Expected: PASS (4 tests).

If `DropdownMenuItem` rejects `variant="default"`, drop the prop entirely and keep only `variant="destructive"` when `action.destructive` is set — check the component's own prop types in `components/ui/dropdown-menu.tsx` rather than guessing.

- [ ] **Step 5: Commit**

```bash
git add frontend/src/viewer/note-menu.tsx frontend/src/viewer/note-menu.test.tsx
git commit -m "feat(editor): add NoteMenu kebab component"
```

---

### Task 4: Hand the scrollbar to the page

The substance of the unit. CodeMirror stops scrolling itself; one `ScrollArea` in `note-page.tsx` scrolls title + properties + body together, for all three modes.

**Files:**
- Modify: `frontend/src/viewer/note-editor.tsx` (editor theme; the `h-full` host div)
- Modify: `frontend/src/viewer/note-page.tsx:166-251` (the returned JSX)
- Test: `frontend/src/viewer/note-page.test.tsx`

**Interfaces:**
- Consumes: `InlineTitle` from Task 2.
- Produces: the note page renders `<InlineTitle>` above the properties widget inside a single scroll container. `data-tour="note-editor"` still exists on a rendered node.

- [ ] **Step 1: Write the failing test**

Append to `frontend/src/viewer/note-page.test.tsx`:

```tsx
describe("NotePage layout", () => {
	it("renders the note name as an inline h1, not just chrome text", async () => {
		renderPage();
		await waitFor(() =>
			expect(screen.getByRole("heading", { level: 1 })).toHaveTextContent("note"),
		);
	});

	it("puts the title above the properties widget in document order", async () => {
		renderPage();
		const title = await screen.findByRole("heading", { level: 1 });
		const properties = await screen.findByTestId("note-properties");
		// Node.compareDocumentPosition: 4 = "properties FOLLOWS title".
		expect(title.compareDocumentPosition(properties)).toBe(
			Node.DOCUMENT_POSITION_FOLLOWING,
		);
	});

	it("keeps the onboarding tour anchor present", async () => {
		renderPage();
		await waitFor(() =>
			expect(document.querySelector('[data-tour="note-editor"]')).toBeInTheDocument(),
		);
	});

	it("shows the title in reading mode too", async () => {
		renderPage();
		await screen.findByTestId("note-editor");
		fireEvent.click(screen.getByRole("button", { name: "Note options" }));
		fireEvent.click(screen.getByRole("menuitem", { name: "Reading" }));
		expect(screen.getByRole("heading", { level: 1 })).toHaveTextContent("note");
	});
});
```

Note: the last test depends on Task 5's menu wiring. Write it now and expect it to stay red until Task 5 — or move it to Task 5 if executing strictly task-by-task. The first three must pass at the end of this task.

Add `data-testid="note-properties"` to the `PropertiesWidget` root in `frontend/src/viewer/properties-widget.tsx` so the ordering assertion has a stable handle:

```tsx
<div className="border-border border-b px-5 py-3" data-testid="note-properties">
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bun run test -- note-page`
Expected: FAIL — no `heading` role (the title is currently an `h2` in chrome with the name inside a button).

- [ ] **Step 3: Change the editor theme so CodeMirror grows**

In `frontend/src/viewer/note-editor.tsx`, in the `editorTheme` object:

```ts
	// height:auto + overflow:visible hand scrolling to the page's ScrollArea, so
	// the inline title and properties scroll with the text instead of staying
	// pinned above it. CodeMirror still viewport-renders against the scrolling
	// ancestor.
	"&": { height: "auto", backgroundColor: "transparent" },
	".cm-scroller": {
		overflow: "visible",
		...
```

Leave the scrollbar-styling rules in place — they become inert but cost nothing and matter again if we ever revert.

Change the host div at the bottom of the file so it no longer forces full height:

```tsx
	return <div ref={hostRef} />;
```

- [ ] **Step 4: Restructure the note page JSX**

In `frontend/src/viewer/note-page.tsx`, import the title component:

```tsx
import { InlineTitle } from "./inline-title";
```

Replace the entire returned JSX (currently lines 166-251) with:

```tsx
	return (
		<section className="mx-auto flex h-full min-h-0 w-full min-w-0 max-w-[840px] flex-col overflow-hidden border-border border-x bg-card text-card-foreground md:-my-6 md:h-[calc(100%+3rem)]">
			{syncStatus === "error" && (
				<p role="status" className="shrink-0 bg-destructive/10 px-4 py-1 text-destructive text-xs">
					Not syncing - reconnecting...
				</p>
			)}

			{/* Chrome is now just the breadcrumb and the kebab — the title moved
			    into the document so it scrolls. */}
			<div className="flex shrink-0 items-center gap-2 border-border border-b px-4 py-2">
				<p className="min-w-0 flex-1 truncate text-muted-foreground text-sm" title={titlePath}>
					{note.folder ? `${note.folder}/` : ""}
				</p>
			</div>

			{mode !== "reading" && handle ? (
				<EditorToolbar getView={() => editorViewRef.current} />
			) : null}

			<ScrollArea className="min-h-0 flex-1">
				<div className="w-full pb-5" data-tour="note-editor">
					<InlineTitle
						name={name}
						renaming={renamingFor === note.id}
						onStartRename={() => setRenamingFor(note.id)}
						onCommitRename={commitRename}
						onCancelRename={() => setRenamingFor(null)}
					/>

					{handle && mode === "rendered" ? <PropertiesWidget doc={handle.doc} /> : null}
					{handle && mode === "raw" ? <RawFrontmatterEditor doc={handle.doc} /> : null}

					{mode === "reading" ? (
						<div className="px-5 pt-2">
							<NoteView content={liveContent} tags={note.tags} />
						</div>
					) : (
						<Suspense fallback={<p className="px-5 py-5 text-muted-foreground">Loading editor…</p>}>
							{handle ? (
								<NoteEditor
									ytext={handle.ytext}
									awareness={handle.awareness}
									mode={mode === "raw" ? "raw" : "rendered"}
									resolveWikiLink={resolveWikiLink}
									onView={(v) => {
										editorViewRef.current = v;
									}}
								/>
							) : (
								<p className="px-5 py-5 text-muted-foreground">Connecting…</p>
							)}
						</Suspense>
					)}
				</div>
			</ScrollArea>
		</section>
	);
```

The kebab is not wired yet — Task 5 adds it to the chrome bar. `MODES`, the `fieldset` of mode buttons, and the `Button` import all disappear in Task 5, not here; leaving them briefly unused is fine mid-task but must be gone before Task 5's commit.

- [ ] **Step 5: Run the full frontend suite**

Run: `bun run test`
Expected: the three layout tests pass. `note-editor.test.tsx` must stay green. Investigate any other failure rather than adjusting the assertion — a test that broke here is telling you the restructure changed real behaviour.

- [ ] **Step 6: Verify scrolling by hand**

The two risks in the spec are not test-detectable in jsdom. With the dev stack running (`make dev-selfhost` from the workspace root, browse `http://127.0.0.1:5173`):

1. Open a long note (paste ~500 lines). Confirm the title scrolls out of view, scrolling is smooth, and there is exactly one scrollbar on the note column.
2. Click into the editor, hold the down arrow past the bottom edge. Confirm the container follows the caret. If it does not, CodeMirror is not finding the Radix viewport as its scroll parent — record the finding and stop; the fallback is the block-widget approach in the spec.

- [ ] **Step 7: Commit**

```bash
git add frontend/src/viewer/note-page.tsx frontend/src/viewer/note-editor.tsx frontend/src/viewer/properties-widget.tsx frontend/src/viewer/note-page.test.tsx
git commit -m "feat(editor): scroll title and properties with content"
```

---

### Task 5: Wire the kebab into the note page

**Files:**
- Modify: `frontend/src/viewer/note-page.tsx`
- Test: `frontend/src/viewer/note-page.test.tsx`

**Interfaces:**
- Consumes: `NoteMenu` (Task 3); `MoveDialog`, `DeleteConfirm`, `nextCopyName` from `./tree-actions/*`; `addKey` from `../crdt/frontmatter-doc`; `useBatchMoveNotes`, `useDeleteNote`, `useDuplicateNote`, `useFolders` from `../api/queries`.
- Produces: the three mode buttons are gone from the chrome; every kebab action is handled.

- [ ] **Step 1: Extend the test mocks, then write the failing tests**

The existing `../api/queries` mock exports only `useNote` and `useRenameNote`; adding hooks to the component without adding them here throws. Replace that mock block in `frontend/src/viewer/note-page.test.tsx`:

```tsx
const useNoteMock = vi.fn();
const { renameNoteMutate, deleteNoteMutate, duplicateNoteMutate, batchMoveMutate } = vi.hoisted(
	() => ({
		renameNoteMutate: vi.fn(),
		deleteNoteMutate: vi.fn(),
		duplicateNoteMutate: vi.fn(),
		batchMoveMutate: vi.fn(),
	}),
);
vi.mock("../api/queries", () => ({
	useNote: (...a: unknown[]) => useNoteMock(...a),
	useRenameNote: () => ({ mutate: renameNoteMutate, isPending: false }),
	useDeleteNote: () => ({ mutate: deleteNoteMutate, isPending: false }),
	useDuplicateNote: () => ({ mutateAsync: duplicateNoteMutate, isPending: false }),
	useBatchMoveNotes: () => ({ mutate: batchMoveMutate, isPending: false }),
	useFolders: () => ({ data: [{ name: "folder" }, { name: "other" }], isLoading: false }),
}));
vi.mock("react-router", () => ({
	useParams: () => ({ itemId: "note-1", slug: "my-vault" }),
	useNavigate: () => navigateMock,
	useLocation: () => locationMock(),
}));
```

Add the two new mocks alongside the others. **Both must go through `vi.hoisted`** — `vi.mock` factories are hoisted above plain `const` declarations, so a non-hoisted `locationMock` throws "Cannot access before initialization" at import time:

```tsx
const { navigateMock, locationMock } = vi.hoisted(() => ({
	navigateMock: vi.fn(),
	locationMock: vi.fn(() => ({ pathname: "/my-vault/note-1", state: null })),
}));
```

Then append the behaviour tests:

```tsx
describe("NotePage kebab", () => {
	const openMenu = async () => {
		await screen.findByTestId("note-editor");
		fireEvent.click(screen.getByRole("button", { name: "Note options" }));
	};

	it("switches view mode from the menu", async () => {
		renderPage();
		await openMenu();
		fireEvent.click(screen.getByRole("menuitem", { name: "Reading" }));
		expect(screen.getByTestId("note-view")).toBeInTheDocument();
	});

	it("no longer shows the old mode buttons in the header", async () => {
		renderPage();
		await screen.findByTestId("note-editor");
		expect(screen.queryByRole("button", { name: "Rendered" })).not.toBeInTheDocument();
	});

	it("starts a rename from the menu", async () => {
		renderPage();
		await openMenu();
		fireEvent.click(screen.getByRole("menuitem", { name: "Rename" }));
		expect(screen.getByRole("textbox")).toHaveValue("note");
	});

	it("duplicates with a collision-safe name", async () => {
		duplicateNoteMutate.mockResolvedValue({ id: "n2", path: "folder/note 1.md" });
		renderPage();
		await openMenu();
		fireEvent.click(screen.getByRole("menuitem", { name: "Duplicate" }));
		expect(duplicateNoteMutate).toHaveBeenCalledWith(
			expect.objectContaining({ src_path: "folder/note.md" }),
		);
	});

	it("moves the note to the folder picked in the dialog", async () => {
		renderPage();
		await openMenu();
		fireEvent.click(screen.getByRole("menuitem", { name: "Move to…" }));
		fireEvent.click(await screen.findByRole("option", { name: "other" }));
		expect(batchMoveMutate).toHaveBeenCalledWith({
			ids: ["note-1"],
			target_folder: "other",
			paths: { "note-1": "folder/note.md" },
		});
	});

	it("deletes only after confirmation, then leaves the dead route", async () => {
		renderPage();
		await openMenu();
		fireEvent.click(screen.getByRole("menuitem", { name: "Delete" }));
		expect(deleteNoteMutate).not.toHaveBeenCalled();
		fireEvent.click(await screen.findByRole("button", { name: "Delete" }));
		expect(deleteNoteMutate).toHaveBeenCalledWith(
			expect.objectContaining({ id: "note-1", path: "folder/note.md" }),
		);
		expect(navigateMock).toHaveBeenCalledWith("/my-vault");
	});

	it("adds a property to the frontmatter doc", async () => {
		renderPage();
		await openMenu();
		fireEvent.click(screen.getByRole("menuitem", { name: "Add property" }));
		expect(await screen.findByTestId("note-properties")).toHaveTextContent("new-property");
	});
});
```

Check `MoveDialog`'s rendered roles before finalising the move test — if its folder rows are not `option`, match what the component actually renders rather than changing the component.

- [ ] **Step 2: Run tests to verify they fail**

Run: `bun run test -- note-page`
Expected: FAIL — no "Note options" button.

- [ ] **Step 3: Implement**

Add imports to `frontend/src/viewer/note-page.tsx`:

```tsx
import { useLocation, useNavigate, useParams } from "react-router";
import { toast } from "sonner";
import {
	useBatchMoveNotes,
	useDeleteNote,
	useDuplicateNote,
	useFolders,
	useNote,
	useRenameNote,
} from "../api/queries";
import { addKey } from "../crdt/frontmatter-doc";
import { NoteMenu } from "./note-menu";
import type { ActionId } from "./tree-actions/action-list";
import { DeleteConfirm } from "./tree-actions/delete-confirm";
import { nextCopyName } from "./tree-actions/duplicate";
import { MoveDialog } from "./tree-actions/move-dialog";
```

Add state and hooks next to the existing ones:

```tsx
	const navigate = useNavigate();
	const slug = params.slug;
	const { data: folders } = useFolders();
	const deleteNote = useDeleteNote();
	const duplicateNote = useDuplicateNote();
	const batchMoveNotes = useBatchMoveNotes();
	const [dialog, setDialog] = useState<"move" | "delete" | null>(null);
```

Add the handler below `commitRename`:

```tsx
	// Deliberately NOT shared with folder-tree.tsx's handleActionPick: that one
	// is welded to tree state (getItemInstance().startRenaming(), rowsFor, its
	// own dialog reducer). The portable parts — the action list and the dialog
	// components — are already reused. See the design spec.
	const handleAction = (action: ActionId) => {
		switch (action) {
			case "view-rendered":
				setMode("rendered");
				break;
			case "view-raw":
				setMode("raw");
				break;
			case "view-reading":
				setMode("reading");
				break;
			case "rename":
				setRenamingFor(note.id);
				break;
			case "move":
				setDialog("move");
				break;
			case "delete":
				setDialog("delete");
				break;
			case "duplicate": {
				// No reliable sibling-name set on hand — pass an empty Set and let the
				// backend reject a collision; the toast surfaces it. Mirrors the tree.
				const new_path = nextCopyName(note.path, new Set<string>());
				duplicateNote
					.mutateAsync({ src_path: note.path, new_path })
					.then(() => toast.success("Duplicated"))
					.catch(() => toast.error("Duplicate failed"));
				break;
			}
			case "copy-wikilink":
				// Wikilinks resolve by filename in Obsidian, never by H1 title.
				navigator.clipboard
					.writeText(`[[${name || note.path}]]`)
					.then(() => toast.success("Copied wikilink"))
					.catch(() => toast.error("Copy failed"));
				break;
			case "add-property":
				if (handle) {
					addKey(handle.doc, "new-property", "text");
				}
				break;
			default:
				break;
		}
	};
```

Put the kebab in the chrome bar, after the breadcrumb paragraph:

```tsx
				<NoteMenu mode={mode} title={name} onPick={handleAction} />
```

Render the dialogs just before the closing `</section>`:

```tsx
			{dialog === "move" ? (
				<MoveDialog
					folders={folders ?? []}
					nodes={[{ kind: "file", path: note.path }]}
					onPick={(folder) => {
						setDialog(null);
						batchMoveNotes.mutate({
							ids: [note.id],
							target_folder: folder,
							paths: { [note.id]: note.path },
						});
					}}
					onCancel={() => setDialog(null)}
				/>
			) : null}

			{dialog === "delete" ? (
				<DeleteConfirm
					nodes={[{ kind: "file", path: note.path }]}
					onConfirm={() => {
						setDialog(null);
						deleteNote.mutate({ id: note.id, path: note.path });
						// useDeleteNote does not navigate — from the tree the deleted note
						// usually isn't open, but here it is, so staying would strand the
						// user on a dead route.
						navigate(slug ? `/${slug}` : "/");
					}}
					onCancel={() => setDialog(null)}
				/>
			) : null}
```

Delete the now-dead `MODES` constant, the `fieldset` of mode buttons, and the `Button` import if nothing else uses it.

Also replace the file-local `type Mode = "rendered" | "raw" | "reading"` with the shared `ViewMode` from `./tree-actions/action-list`, and use it for the `useState<ViewMode>` declaration. The two are structurally identical so TypeScript accepts either, which is exactly why they will drift if both survive:

```tsx
import { type ActionId, type ViewMode } from "./tree-actions/action-list";
// ...
const [mode, setMode] = useState<ViewMode>("rendered");
```

Confirm `MoveDialog`'s `nodes` prop accepts `{ kind: "file", path }` — check `MoveNode` in `move-path.ts` and match its actual shape.

- [ ] **Step 4: Run the full suite**

Run: `bun run test`
Expected: PASS. Also run `bun run test -- folder-tree` explicitly — Task 1 touched shared types.

- [ ] **Step 5: Lint**

Run: `./node_modules/.bin/biome ci .`
Expected: clean. Do not use `bunx biome`.

- [ ] **Step 6: Commit**

```bash
git add frontend/src/viewer/note-page.tsx frontend/src/viewer/note-page.test.tsx
git commit -m "feat(editor): move view modes and file actions into kebab"
```

---

### Task 6: New note opens with its title selected

**Files:**
- Modify: `frontend/src/api/queries.ts:682`
- Modify: `frontend/src/viewer/note-page.tsx`
- Test: `frontend/src/viewer/note-page.test.tsx`

**Interfaces:**
- Consumes: `InlineTitle`'s `renaming` prop (Task 2); `useLocation` (mocked in Task 5).
- Produces: navigation state `{ justCreated: true }` set by `useCreateNote`, consumed once by the note page.

- [ ] **Step 1: Write the failing tests**

Append to `frontend/src/viewer/note-page.test.tsx`:

```tsx
describe("NotePage new-note rename", () => {
	it("opens the title in rename mode when navigated to as just-created", async () => {
		locationMock.mockReturnValue({
			pathname: "/my-vault/note-1",
			state: { justCreated: true },
		});
		renderPage();
		const input = (await screen.findByRole("textbox")) as HTMLInputElement;
		expect(input.value).toBe("note");
		expect(input.selectionStart).toBe(0);
		expect(input.selectionEnd).toBe("note".length);
	});

	it("clears the flag so a back-navigation does not reopen the rename box", async () => {
		locationMock.mockReturnValue({
			pathname: "/my-vault/note-1",
			state: { justCreated: true },
		});
		renderPage();
		await screen.findByRole("textbox");
		expect(navigateMock).toHaveBeenCalledWith("/my-vault/note-1", {
			replace: true,
			state: {},
		});
	});

	it("does not start renaming on an ordinary navigation", async () => {
		locationMock.mockReturnValue({ pathname: "/my-vault/note-1", state: null });
		renderPage();
		await screen.findByTestId("note-editor");
		expect(screen.queryByRole("textbox")).not.toBeInTheDocument();
	});
});
```

Add a `locationMock.mockReturnValue({ pathname: "/my-vault/note-1", state: null })` reset to the top-level `beforeEach` so these cases don't leak into earlier tests.

- [ ] **Step 2: Run tests to verify they fail**

Run: `bun run test -- note-page`
Expected: FAIL — no textbox; the title renders as a button.

- [ ] **Step 3: Set the flag at the single creation seam**

In `frontend/src/api/queries.ts`, in `useCreateNote`'s `onSuccess` (line ~682):

```ts
			// `justCreated` puts the note page's inline title straight into rename
			// mode with "Untitled" selected. Carried as navigation state rather than
			// a context because it must fire exactly once, and router state is
			// already scoped to a single navigation. Both creation entry points (the
			// tree's context menu and the sidebar button) route through here.
			navigate(slug ? `/${slug}/${id}` : `/note/${id}`, { state: { justCreated: true } });
```

- [ ] **Step 4: Consume it once in the note page**

In `frontend/src/viewer/note-page.tsx`, add below the other effects:

```tsx
	// Consume the just-created flag exactly once: start renaming, then strip the
	// state so a later back-navigation to this history entry doesn't reopen the
	// rename box on a note the user already named.
	const location = useLocation();
	const justCreated = Boolean((location.state as { justCreated?: boolean } | null)?.justCreated);
	useEffect(() => {
		if (!(justCreated && noteId)) {
			return;
		}
		setRenamingFor(noteId);
		navigate(location.pathname, { replace: true, state: {} });
	}, [justCreated, noteId, navigate, location.pathname]);
```

- [ ] **Step 5: Run the full suite**

Run: `bun run test`
Expected: PASS, all 1166+ tests.

- [ ] **Step 6: Verify by hand**

With the dev stack running, click "New note" in the sidebar and again from the tree's right-click. In both cases the note opens with the title in an input, "Untitled" selected, and typing replaces it.

- [ ] **Step 7: Lint, then commit**

```bash
./node_modules/.bin/biome ci .
git add frontend/src/api/queries.ts frontend/src/viewer/note-page.tsx frontend/src/viewer/note-page.test.tsx
git commit -m "feat(editor): open new notes with the title selected"
```

---

### Task 7: Final verification and PR

- [ ] **Step 1: Full suite from a clean state**

```bash
cd frontend && bun run test 2>&1 | tail -5
```

Expected: 0 failures. The baseline was 167 files / 1166 tests; the count should have grown, never shrunk.

- [ ] **Step 2: Lint and typecheck**

```bash
./node_modules/.bin/biome ci .
bun run build   # tsc runs as part of the production build
```

- [ ] **Step 3: Manual pass against the spec's risk list**

1. Long note scrolls smoothly, one scrollbar, title scrolls away.
2. Caret arrow-key past the bottom edge scrolls the container.
3. Onboarding tour still anchors (`[data-tour="note-editor"]` present and visible).
4. Mobile viewport (DevTools device emulation, <768px): kebab opens the bottom sheet, every action works.

- [ ] **Step 4: Open the PR**

```bash
git push -u origin feat/note-header-inline-title-kebab
gh pr create --title "feat(editor): Obsidian-style inline title and kebab menu" --body "..."
```

Body should link the spec, list what shipped, and state explicitly that Unit B (toolbar) and Unit C (frontmatter on demand) are deliberately not in this PR.

---

## Notes for the implementer

- **Do not** try to unify `handleAction` with `folder-tree.tsx`'s `handleActionPick`. The duplication is deliberate and documented in the spec.
- If CodeMirror's `height: auto` causes visible stutter on a long note, stop and report. The fallback (rendering title and properties as CodeMirror block widgets at position 0) is a different task, not an in-place patch.
- The `../api/queries` and `react-router` mocks in `note-page.test.tsx` are module-level. Any hook you add to the component must be added to the mock in the same commit, or every test in the file fails at import time with a confusing error.
