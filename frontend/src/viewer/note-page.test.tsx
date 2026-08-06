import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { Awareness } from "y-protocols/awareness";
import * as Y from "yjs";
import { readRows } from "../crdt/frontmatter-doc";
import { RightToolsProvider } from "../layout/right-tools-context";
import { ActiveEditorProvider, useActiveEditor } from "./editor/active-editor-context";
import NotePage from "./note-page";

// Real provider, not a stub: the page publishing its editor here is the seam the
// right-sidebar reference panel inserts through, so it's worth exercising.
function EditorProbe() {
	const { hasEditor } = useActiveEditor();
	return <span data-testid="has-editor">{String(hasEditor)}</span>;
}

const renderPage = () =>
	render(
		<RightToolsProvider>
			<ActiveEditorProvider>
				<NotePage />
				<EditorProbe />
			</ActiveEditorProvider>
		</RightToolsProvider>,
	);

// NoteView relies on ConfigProvider / billing context not available in this
// test harness. Mock it so we can assert on the `content` prop directly.
vi.mock("./note-view", () => ({
	default: ({ content }: { content: string }) => <div data-testid="note-view">{content}</div>,
}));

// NoteEditor is lazy-loaded and requires ThemeProvider context. Stub it so the
// live-mode editor path doesn't crash the test environment. The button stands
// in for typing `---` on the first line, and records what the page answered —
// the real gesture is covered in editor/frontmatter-shortcut.test.ts.
const { shortcutAnswer } = vi.hoisted(() => ({ shortcutAnswer: vi.fn() }));
vi.mock("./note-editor", () => ({
	default: ({ onFrontmatterShortcut }: { onFrontmatterShortcut?: () => boolean }) => (
		<div data-testid="note-editor">
			<button
				type="button"
				data-testid="type-frontmatter-fence"
				onClick={() => shortcutAnswer(onFrontmatterShortcut?.())}
			>
				---
			</button>
		</div>
	),
}));

const { openDoc, closeDoc, enroll } = vi.hoisted(() => ({
	openDoc: vi.fn(),
	closeDoc: vi.fn(),
	enroll: vi.fn(),
}));

vi.mock("../crdt/session", () => ({
	openDoc,
	closeDoc,
	enroll,
	getCrdtSyncStatus: () => "connecting",
	subscribeToCrdtSyncStatus: () => () => {},
}));

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
	useDuplicateNote: () => ({ mutate: duplicateNoteMutate, isPending: false }),
	useBatchMoveNotes: () => ({ mutate: batchMoveMutate, isPending: false }),
	useFolders: () => ({ data: [{ name: "folder" }, { name: "other" }], isLoading: false }),
	useSyncManifest: () => ({ data: undefined }),
}));

// Both must go through vi.hoisted — vi.mock factories are hoisted above plain
// `const` declarations, so a non-hoisted locationMock throws "Cannot access
// before initialization" at import time.
const { navigateMock, locationMock } = vi.hoisted(() => ({
	navigateMock: vi.fn(),
	locationMock: vi.fn<() => { pathname: string; state: { justCreated?: boolean } | null }>(() => ({
		pathname: "/my-vault/note-1",
		state: null,
	})),
}));
vi.mock("react-router", () => ({
	useParams: () => ({ itemId: "note-1", slug: "my-vault" }),
	useNavigate: () => navigateMock,
	useLocation: () => locationMock(),
}));

vi.mock("sonner", () => ({ toast: { success: vi.fn(), error: vi.fn() } }));

const NOTE = {
	id: "note-1",
	path: "folder/note.md",
	title: "note",
	folder: "folder",
	content: "# hi",
	tags: [],
	version: 1,
};

describe("NotePage (CRDT)", () => {
	// Radix DropdownMenu opens on pointerdown in happy-dom; the mobile drawer is
	// a plain button, so sending both covers whichever branch the viewport picks.
	const openMenu = async () => {
		const trigger = await screen.findByRole("button", { name: "Note options" });
		fireEvent.pointerDown(trigger, { button: 0, ctrlKey: false });
		fireEvent.click(trigger);
		await screen.findByRole("menuitem", { name: "Rendered" });
	};

	beforeEach(() => {
		vi.clearAllMocks();
		locationMock.mockReturnValue({ pathname: "/my-vault/note-1", state: null });
		const doc = new Y.Doc();
		openDoc.mockResolvedValue({
			ytext: doc.getText("content"),
			awareness: new Awareness(doc),
			doc,
		});
		useNoteMock.mockReturnValue({ data: NOTE, isLoading: false, error: null });
	});

	it("opens + enrolls the CRDT doc for a .md note, keyed by note_id (not path)", async () => {
		renderPage();
		await waitFor(() => expect(openDoc).toHaveBeenCalledWith("note-1"));
		expect(enroll).toHaveBeenCalledWith("note-1");
	});

	it("closes the doc on unmount, keyed by note_id", async () => {
		const { unmount } = renderPage();
		await waitFor(() => expect(openDoc).toHaveBeenCalled());
		unmount();
		expect(closeDoc).toHaveBeenCalledWith("note-1");
	});

	// The CRDT gate is markdown-only (mirrors the server's crdt_deliver.ex
	// gate). note_id carries no extension, so note-page.tsx checks the current
	// path before ever calling openDoc/enroll.
	it("does not open the CRDT doc for a non-markdown note (e.g. canvas)", async () => {
		useNoteMock.mockReturnValue({
			data: { ...NOTE, path: "folder/note.canvas" },
			isLoading: false,
			error: null,
		});
		renderPage();
		await waitFor(() => expect(screen.getByTestId("header-note-name")).toBeInTheDocument());
		expect(openDoc).not.toHaveBeenCalled();
		expect(enroll).not.toHaveBeenCalled();
	});

	it("reading view renders live Y.Text content, not stale REST content", async () => {
		const doc = new Y.Doc();
		const ytext = doc.getText("content");
		ytext.insert(0, "# Live Heading\nbody");
		openDoc.mockResolvedValue({
			ytext,
			awareness: new Awareness(doc),
			doc,
		});
		// REST content is stale / different from the live CRDT text
		useNoteMock.mockReturnValue({
			data: { ...NOTE, content: "# hi" },
			isLoading: false,
			error: null,
		});

		renderPage();

		// Wait for openDoc to resolve and handle to be set
		await waitFor(() => expect(openDoc).toHaveBeenCalledWith("note-1"));

		// Switch to reading mode
		await openMenu();
		fireEvent.click(screen.getByRole("menuitem", { name: "Reading" }));

		// NoteView is mocked — assert on the content prop it receives.
		// The live Y.Text content should be passed, not the stale REST "# hi".
		// toHaveTextContent normalises whitespace, so match on a distinctive
		// substring from the live text rather than checking the exact newline.
		await waitFor(() =>
			expect(screen.getByTestId("note-view")).toHaveTextContent("# Live Heading"),
		);
		expect(screen.getByTestId("note-view")).toHaveTextContent("body");
		expect(screen.getByTestId("note-view")).not.toHaveTextContent("# hi");
	});

	it("publishes the editor while it is mounted and withdraws it in reading mode", async () => {
		renderPage();
		// Editor only exists once the CRDT handle resolves.
		await waitFor(() => expect(screen.getByTestId("has-editor")).toHaveTextContent("true"));

		// Reading mode swaps the editor out for NoteView — nothing to insert into,
		// so the reference panel's Insert action must go disabled rather than
		// silently no-op against a torn-down view.
		await openMenu();
		fireEvent.click(screen.getByRole("menuitem", { name: "Reading" }));
		await waitFor(() => expect(screen.getByTestId("has-editor")).toHaveTextContent("false"));

		await openMenu();
		fireEvent.click(screen.getByRole("menuitem", { name: "Rendered" }));
		await waitFor(() => expect(screen.getByTestId("has-editor")).toHaveTextContent("true"));
	});

	it("renders the properties widget with frontmatter keys in the default rendered mode", async () => {
		const doc = new Y.Doc();
		doc.getMap("frontmatter").set("status", JSON.stringify("draft"));
		doc.getArray("frontmatter_order").insert(0, ["status"]);
		openDoc.mockResolvedValue({
			ytext: doc.getText("content"),
			awareness: new Awareness(doc),
			doc,
		});

		renderPage();

		// Widget should appear in the default rendered mode
		await waitFor(() => expect(screen.getByDisplayValue("status")).toBeInTheDocument());
	});

	// Inline rename from the header — same semantics as the tree's rename
	// (leaf-name edit, folder untouched, extension preserved), so the two
	// entry points can't drift apart.
	// The header keeps its own rename affordance: the full path is always
	// visible even when the document is scrolled past the inline title, so it
	// stays the reachable place to retitle a note.
	describe("header path", () => {
		it("shows the folder crumb and the file name", async () => {
			renderPage();
			await screen.findByTestId("note-editor");
			expect(screen.getByTestId("header-note-name")).toHaveTextContent("note");
			expect(screen.getByText("folder/")).toBeInTheDocument();
		});

		it("renames from the header without also opening the inline title's box", async () => {
			renderPage();
			fireEvent.click(await screen.findByTestId("header-note-name"));
			// Two boxes would mean two focus targets fighting over the same commit.
			expect(screen.getAllByRole("textbox", { name: "Rename file" })).toHaveLength(1);
			expect(screen.getByRole("heading", { level: 1 })).toHaveTextContent("note");
		});

		it("opens the inline title's box for a kebab rename, not the header's", async () => {
			renderPage();
			await screen.findByTestId("note-editor");
			await openMenu();
			fireEvent.click(screen.getByRole("menuitem", { name: "Rename" }));
			expect(screen.getAllByRole("textbox", { name: "Rename file" })).toHaveLength(1);
			// The header still shows its button; the h1 is the one that swapped.
			expect(screen.getByTestId("header-note-name")).toBeInTheDocument();
		});
	});

	describe("inline rename", () => {
		const openRename = async () => {
			renderPage();
			fireEvent.click(await screen.findByTestId("header-note-name"));
			return screen.getByRole("textbox", { name: "Rename file" });
		};

		it("seeds the input with the display name — no extension to edit", async () => {
			const input = await openRename();
			expect(input).toHaveValue("note");
			// The folder crumb stays put — only the name is editable.
			expect(screen.getByText("folder/")).toBeInTheDocument();
		});

		it("commits on Enter, keeping the folder and the extension", async () => {
			const input = await openRename();
			fireEvent.change(input, { target: { value: "renamed" } });
			fireEvent.keyDown(input, { key: "Enter" });
			expect(renameNoteMutate).toHaveBeenCalledWith({
				id: "note-1",
				old_path: "folder/note.md",
				new_path: "folder/renamed.md",
			});
			await waitFor(() =>
				expect(screen.queryByRole("textbox", { name: "Rename file" })).not.toBeInTheDocument(),
			);
		});

		it("cancels on Escape without renaming", async () => {
			const input = await openRename();
			fireEvent.change(input, { target: { value: "renamed" } });
			fireEvent.keyDown(input, { key: "Escape" });
			expect(renameNoteMutate).not.toHaveBeenCalled();
			await waitFor(() =>
				expect(screen.queryByRole("textbox", { name: "Rename file" })).not.toBeInTheDocument(),
			);
		});

		it("does not fire a rename when the name is unchanged", async () => {
			const input = await openRename();
			fireEvent.keyDown(input, { key: "Enter" });
			expect(renameNoteMutate).not.toHaveBeenCalled();
		});

		// The header edits the display name only — a typed extension is title
		// text, never a file-type change. Changing .md -> .canvas would strand
		// the note outside the CRDT markdown gate.
		it("treats a typed extension as part of the title, not a type change", async () => {
			const input = await openRename();
			fireEvent.change(input, { target: { value: "board.canvas" } });
			fireEvent.keyDown(input, { key: "Enter" });
			expect(renameNoteMutate).toHaveBeenCalledWith(
				expect.objectContaining({ new_path: "folder/board.canvas.md" }),
			);
		});

		it("keeps a dotted title intact", async () => {
			const input = await openRename();
			fireEvent.change(input, { target: { value: "Node.js guide" } });
			fireEvent.keyDown(input, { key: "Enter" });
			expect(renameNoteMutate).toHaveBeenCalledWith(
				expect.objectContaining({ new_path: "folder/Node.js guide.md" }),
			);
		});
	});

	it("swaps the frontmatter surface across rendered/raw/reading modes", async () => {
		const doc = new Y.Doc();
		doc.getMap("frontmatter").set("status", JSON.stringify("draft"));
		doc.getArray("frontmatter_order").insert(0, ["status"]);
		openDoc.mockResolvedValue({
			ytext: doc.getText("content"),
			awareness: new Awareness(doc),
			doc,
		});

		renderPage();

		// Default "rendered" mode: pills visible, editor visible, no raw YAML region.
		await waitFor(() => expect(screen.getByDisplayValue("status")).toBeInTheDocument());
		expect(screen.getByTestId("note-editor")).toBeInTheDocument();
		expect(screen.queryByLabelText(/Frontmatter \(raw YAML\)/i)).not.toBeInTheDocument();
		await openMenu();
		expect(screen.getByRole("menuitem", { name: "Rendered" })).toHaveAttribute(
			"aria-current",
			"true",
		);

		// Switch to "raw": raw YAML region visible, pills hidden.
		fireEvent.click(screen.getByRole("menuitem", { name: "Raw" }));
		await waitFor(() =>
			expect(screen.getByLabelText(/Frontmatter \(raw YAML\)/i)).toBeInTheDocument(),
		);
		expect(screen.queryByDisplayValue("status")).not.toBeInTheDocument();
		expect(screen.getByTestId("note-editor")).toBeInTheDocument();

		// Switch to "reading": NoteView visible, neither frontmatter surface shown.
		await openMenu();
		fireEvent.click(screen.getByRole("menuitem", { name: "Reading" }));
		await waitFor(() => expect(screen.getByTestId("note-view")).toBeInTheDocument());
		expect(screen.queryByLabelText(/Frontmatter \(raw YAML\)/i)).not.toBeInTheDocument();
		expect(screen.queryByDisplayValue("status")).not.toBeInTheDocument();
		expect(screen.queryByTestId("note-editor")).not.toBeInTheDocument();
	});

	describe("layout", () => {
		it("renders the note name as an inline h1, not just chrome text", async () => {
			renderPage();
			await waitFor(() =>
				expect(screen.getByRole("heading", { level: 1 })).toHaveTextContent("note"),
			);
		});

		it("puts the title above the properties widget in document order", async () => {
			// Seeded: the widget hides itself on a note with no frontmatter, so
			// there has to be a property for it to be ordered against.
			const doc = new Y.Doc();
			doc.getMap("frontmatter").set("status", JSON.stringify("draft"));
			doc.getArray("frontmatter_order").insert(0, ["status"]);
			openDoc.mockResolvedValue({
				ytext: doc.getText("content"),
				awareness: new Awareness(doc),
				doc,
			});

			renderPage();
			const title = await screen.findByRole("heading", { level: 1 });
			const properties = await screen.findByTestId("note-properties");
			// Node.compareDocumentPosition: 4 = "properties FOLLOWS title".
			expect(title.compareDocumentPosition(properties)).toBe(Node.DOCUMENT_POSITION_FOLLOWING);
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
			await openMenu();
			fireEvent.click(screen.getByRole("menuitem", { name: "Reading" }));
			expect(screen.getByRole("heading", { level: 1 })).toHaveTextContent("note");
		});
	});

	describe("frontmatter shortcut", () => {
		const withFrontmatter = () => {
			const doc = new Y.Doc();
			doc.getMap("frontmatter").set("status", JSON.stringify("draft"));
			doc.getArray("frontmatter_order").insert(0, ["status"]);
			openDoc.mockResolvedValue({
				ytext: doc.getText("content"),
				awareness: new Awareness(doc),
				doc,
			});
		};

		it("opens an empty properties editor on a note with no frontmatter", async () => {
			renderPage();
			await screen.findByTestId("note-editor");
			expect(screen.queryByTestId("note-properties")).not.toBeInTheDocument();

			fireEvent.click(screen.getByTestId("type-frontmatter-fence"));

			expect(await screen.findByTestId("note-properties")).toBeInTheDocument();
			expect(shortcutAnswer).toHaveBeenCalledWith(true);
		});

		it("closes it again when focus leaves with nothing added", async () => {
			renderPage();
			await screen.findByTestId("note-editor");
			fireEvent.click(screen.getByTestId("type-frontmatter-fence"));
			await screen.findByTestId("note-properties");

			fireEvent.pointerDown(document.body);

			await waitFor(() => expect(screen.queryByTestId("note-properties")).not.toBeInTheDocument());
		});

		// The gesture deletes the user's typed characters, so it must never
		// report success without actually opening something — otherwise the
		// three dashes vanish and nothing happens.
		it("still works after the first attempt was abandoned", async () => {
			renderPage();
			await screen.findByTestId("note-editor");

			fireEvent.click(screen.getByTestId("type-frontmatter-fence"));
			fireEvent.keyDown(await screen.findByPlaceholderText("Property name"), { key: "Escape" });

			fireEvent.click(screen.getByTestId("type-frontmatter-fence"));

			expect(await screen.findByPlaceholderText("Property name")).toBeInTheDocument();
		});

		it("leaves nothing behind when the row is abandoned with Escape", async () => {
			renderPage();
			await screen.findByTestId("note-editor");
			fireEvent.click(screen.getByTestId("type-frontmatter-fence"));

			fireEvent.keyDown(await screen.findByPlaceholderText("Property name"), { key: "Escape" });

			await waitFor(() => expect(screen.queryByTestId("note-properties")).not.toBeInTheDocument());
		});

		// Declining is what leaves the typed `---` in the body as a real
		// horizontal rule instead of silently eating it.
		it("declines when the note already has frontmatter", async () => {
			withFrontmatter();
			renderPage();
			await screen.findByTestId("note-properties");

			fireEvent.click(screen.getByTestId("type-frontmatter-fence"));

			expect(shortcutAnswer).toHaveBeenCalledWith(false);
		});
	});

	describe("reading toggle", () => {
		// One stable name with aria-pressed, not a name that flips between
		// "Edit"/"Reading view": the icon shows the CURRENT mode, so a label
		// naming the next action would contradict it.
		const toggle = () => screen.getByRole("button", { name: "Reading view" });

		it("switches to reading view and back, reporting its state", async () => {
			renderPage();
			await screen.findByTestId("note-editor");
			expect(toggle()).toHaveAttribute("aria-pressed", "false");

			fireEvent.click(toggle());
			expect(screen.getByTestId("note-view")).toBeInTheDocument();
			expect(toggle()).toHaveAttribute("aria-pressed", "true");

			fireEvent.click(toggle());
			expect(screen.getByTestId("note-editor")).toBeInTheDocument();
			expect(toggle()).toHaveAttribute("aria-pressed", "false");
		});

		// Raw is an edit mode, so a round trip through reading must not silently
		// demote it to rendered.
		it("returns to raw when that was the editor in use", async () => {
			renderPage();
			await screen.findByTestId("note-editor");
			await openMenu();
			fireEvent.click(screen.getByRole("menuitem", { name: "Raw" }));
			await screen.findByLabelText(/Frontmatter \(raw YAML\)/i);

			fireEvent.click(toggle());
			expect(screen.getByTestId("note-view")).toBeInTheDocument();
			fireEvent.click(toggle());
			expect(await screen.findByLabelText(/Frontmatter \(raw YAML\)/i)).toBeInTheDocument();
		});

		it("stays in step with the kebab's active-mode marker", async () => {
			renderPage();
			await screen.findByTestId("note-editor");
			fireEvent.click(toggle());
			await openMenu();
			expect(screen.getByRole("menuitem", { name: "Reading" })).toHaveAttribute(
				"aria-current",
				"true",
			);
		});
	});

	describe("kebab", () => {
		it("switches view mode from the menu", async () => {
			renderPage();
			await screen.findByTestId("note-editor");
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
			await screen.findByTestId("note-editor");
			await openMenu();
			fireEvent.click(screen.getByRole("menuitem", { name: "Rename" }));
			expect(screen.getByRole("textbox", { name: "Rename file" })).toHaveValue("note");
		});

		it("duplicates with a collision-safe name, leaving errors to the mutation", async () => {
			renderPage();
			await screen.findByTestId("note-editor");
			await openMenu();
			fireEvent.click(screen.getByRole("menuitem", { name: "Duplicate" }));
			expect(duplicateNoteMutate).toHaveBeenCalledWith(
				expect.objectContaining({ src_path: "folder/note.md" }),
				expect.objectContaining({ onSuccess: expect.any(Function) }),
			);
			// useDuplicateNote's onError already toasts, and it tells a name
			// collision apart from a general failure. Reporting here as well
			// stacked a second, vaguer toast on top of the useful one.
			expect(duplicateNoteMutate.mock.calls[0]?.[1]).not.toHaveProperty("onError");
		});

		it("moves the note to the folder picked in the dialog", async () => {
			renderPage();
			await screen.findByTestId("note-editor");
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
			await screen.findByTestId("note-editor");
			await openMenu();
			fireEvent.click(screen.getByRole("menuitem", { name: "Delete" }));
			expect(deleteNoteMutate).not.toHaveBeenCalled();
			fireEvent.click(await screen.findByRole("button", { name: "Delete" }));
			expect(deleteNoteMutate).toHaveBeenCalledWith(
				expect.objectContaining({ id: "note-1", path: "folder/note.md" }),
			);
			expect(navigateMock).toHaveBeenCalledWith("/my-vault");
		});

		// The reported symptom was "I can set keys but not values". Proves the
		// write path end to end from the real note page, so a fix for it can't be
		// mistaken for a styling change.
		it("writes a value typed into a property row", async () => {
			const doc = new Y.Doc();
			openDoc.mockResolvedValue({
				ytext: doc.getText("content"),
				awareness: new Awareness(doc),
				doc,
			});
			renderPage();
			await screen.findByTestId("note-editor");
			await openMenu();
			fireEvent.click(screen.getByRole("menuitem", { name: "Add property" }));

			fireEvent.change(await screen.findByPlaceholderText("Property name"), {
				target: { value: "status" },
			});
			const value = screen.getByPlaceholderText("Value");
			fireEvent.change(value, { target: { value: "hello" } });
			fireEvent.keyDown(value, { key: "Enter" });

			await waitFor(() =>
				expect(readRows(doc).find((r) => r.key === "status")?.value).toBe("hello"),
			);
		});

		it("opens the property adder from the note menu", async () => {
			renderPage();
			await screen.findByTestId("note-editor");
			await openMenu();
			fireEvent.click(screen.getByRole("menuitem", { name: "Add property" }));
			expect(await screen.findByPlaceholderText("Property name")).toBeInTheDocument();
		});

		// The menu used to write a key called "new-property" straight into the doc.
		// A second use collided with the first, addKey refused it, and the menu item
		// did nothing at all — no row, no error.
		it("reopens the adder after a property has already been added", async () => {
			const doc = new Y.Doc();
			openDoc.mockResolvedValue({
				ytext: doc.getText("content"),
				awareness: new Awareness(doc),
				doc,
			});
			renderPage();
			await screen.findByTestId("note-editor");

			await openMenu();
			fireEvent.click(screen.getByRole("menuitem", { name: "Add property" }));
			fireEvent.change(await screen.findByPlaceholderText("Property name"), {
				target: { value: "status" },
			});
			fireEvent.keyDown(screen.getByPlaceholderText("Value"), { key: "Enter" });
			await screen.findByTestId("property-row-status");

			await openMenu();
			fireEvent.click(screen.getByRole("menuitem", { name: "Add property" }));
			expect(await screen.findByPlaceholderText("Property name")).toBeInTheDocument();
		});

		// The properties widget only renders in rendered mode, so from reading mode
		// the old handler wrote a property the user could not see locally while it
		// synced out to every other device.
		it("switches to rendered mode so the adder it opens is on screen", async () => {
			renderPage();
			await screen.findByTestId("note-editor");
			fireEvent.click(screen.getByRole("button", { name: "Reading view" }));
			await openMenu();
			fireEvent.click(screen.getByRole("menuitem", { name: "Add property" }));
			expect(await screen.findByPlaceholderText("Property name")).toBeInTheDocument();
		});
	});

	describe("new-note rename", () => {
		it("opens the title in rename mode when navigated to as just-created", async () => {
			locationMock.mockReturnValue({
				pathname: "/my-vault/note-1",
				state: { justCreated: true },
			});
			renderPage();
			const input = (await screen.findByRole("textbox", {
				name: "Rename file",
			})) as HTMLInputElement;
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
			await screen.findByRole("textbox", { name: "Rename file" });
			expect(navigateMock).toHaveBeenCalledWith("/my-vault/note-1", {
				replace: true,
				state: {},
			});
		});

		it("does not start renaming on an ordinary navigation", async () => {
			locationMock.mockReturnValue({ pathname: "/my-vault/note-1", state: null });
			renderPage();
			await screen.findByTestId("note-editor");
			expect(screen.queryByRole("textbox", { name: "Rename file" })).not.toBeInTheDocument();
		});
	});
});
