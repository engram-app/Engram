import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { Awareness } from "y-protocols/awareness";
import * as Y from "yjs";
import NotePage from "./note-page";

// NoteView relies on ConfigProvider / billing context not available in this
// test harness. Mock it so we can assert on the `content` prop directly.
vi.mock("./note-view", () => ({
	default: ({ content }: { content: string }) => <div data-testid="note-view">{content}</div>,
}));

// NoteEditor is lazy-loaded and requires ThemeProvider context. Stub it so the
// live-mode editor path doesn't crash the test environment.
vi.mock("./note-editor", () => ({
	default: () => <div data-testid="note-editor" />,
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
const { renameNoteMutate } = vi.hoisted(() => ({ renameNoteMutate: vi.fn() }));
vi.mock("../api/queries", () => ({
	useNote: (...a: unknown[]) => useNoteMock(...a),
	useRenameNote: () => ({ mutate: renameNoteMutate, isPending: false }),
}));
vi.mock("react-router", () => ({ useParams: () => ({ id: "note-1" }) }));
// Minimal stubs for the right-sidebar + lazy editor context used by the page.
vi.mock("../layout/right-sidebar-context", () => ({
	useRightSidebar: () => ({ setContent: () => {} }),
}));

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
	beforeEach(() => {
		vi.clearAllMocks();
		const doc = new Y.Doc();
		openDoc.mockResolvedValue({
			ytext: doc.getText("content"),
			awareness: new Awareness(doc),
			doc,
		});
		useNoteMock.mockReturnValue({ data: NOTE, isLoading: false, error: null });
	});

	it("opens + enrolls the CRDT doc for a .md note, keyed by note_id (not path)", async () => {
		render(<NotePage />);
		await waitFor(() => expect(openDoc).toHaveBeenCalledWith("note-1"));
		expect(enroll).toHaveBeenCalledWith("note-1");
	});

	it("closes the doc on unmount, keyed by note_id", async () => {
		const { unmount } = render(<NotePage />);
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
		render(<NotePage />);
		await waitFor(() => expect(screen.getByText("note")).toBeInTheDocument());
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

		render(<NotePage />);

		// Wait for openDoc to resolve and handle to be set
		await waitFor(() => expect(openDoc).toHaveBeenCalledWith("note-1"));

		// Switch to reading mode
		fireEvent.click(screen.getByRole("button", { name: "Reading" }));

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

	it("renders the properties widget with frontmatter keys in the default rendered mode", async () => {
		const doc = new Y.Doc();
		doc.getMap("frontmatter").set("status", JSON.stringify("draft"));
		doc.getArray("frontmatter_order").insert(0, ["status"]);
		openDoc.mockResolvedValue({
			ytext: doc.getText("content"),
			awareness: new Awareness(doc),
			doc,
		});

		render(<NotePage />);

		// Widget should appear in the default rendered mode
		await waitFor(() => expect(screen.getByText("status")).toBeInTheDocument());
	});

	// Inline rename from the header — same semantics as the tree's rename
	// (leaf-name edit, folder untouched, extension preserved), so the two
	// entry points can't drift apart.
	describe("inline rename", () => {
		const openRename = async () => {
			render(<NotePage />);
			fireEvent.click(await screen.findByRole("button", { name: "note" }));
			return screen.getByRole("textbox", { name: "Rename file" });
		};

		it("turns the file name into an input seeded with the full leaf name", async () => {
			const input = await openRename();
			expect(input).toHaveValue("note.md");
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

		render(<NotePage />);

		// Default "rendered" mode: pills visible, editor visible, no raw YAML region.
		await waitFor(() => expect(screen.getByText("status")).toBeInTheDocument());
		expect(screen.getByTestId("note-editor")).toBeInTheDocument();
		expect(screen.queryByLabelText(/Frontmatter \(raw YAML\)/i)).not.toBeInTheDocument();
		expect(screen.getByRole("button", { name: "Rendered" })).toHaveAttribute(
			"aria-pressed",
			"true",
		);

		// Switch to "raw": raw YAML region visible, pills hidden.
		fireEvent.click(screen.getByRole("button", { name: "Raw" }));
		await waitFor(() =>
			expect(screen.getByLabelText(/Frontmatter \(raw YAML\)/i)).toBeInTheDocument(),
		);
		expect(screen.queryByText("status")).not.toBeInTheDocument();
		expect(screen.getByTestId("note-editor")).toBeInTheDocument();

		// Switch to "reading": NoteView visible, neither frontmatter surface shown.
		fireEvent.click(screen.getByRole("button", { name: "Reading" }));
		await waitFor(() => expect(screen.getByTestId("note-view")).toBeInTheDocument());
		expect(screen.queryByLabelText(/Frontmatter \(raw YAML\)/i)).not.toBeInTheDocument();
		expect(screen.queryByText("status")).not.toBeInTheDocument();
		expect(screen.queryByTestId("note-editor")).not.toBeInTheDocument();
	});
});
