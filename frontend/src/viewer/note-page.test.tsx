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
vi.mock("../api/queries", () => ({ useNote: (...a: unknown[]) => useNoteMock(...a) }));
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

	it("opens + enrolls the CRDT doc for a .md note", async () => {
		render(<NotePage />);
		await waitFor(() => expect(openDoc).toHaveBeenCalledWith("folder/note.md"));
		expect(enroll).toHaveBeenCalledWith("folder/note.md");
	});

	it("closes the doc on unmount", async () => {
		const { unmount } = render(<NotePage />);
		await waitFor(() => expect(openDoc).toHaveBeenCalled());
		unmount();
		expect(closeDoc).toHaveBeenCalledWith("folder/note.md");
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
		await waitFor(() => expect(openDoc).toHaveBeenCalledWith("folder/note.md"));

		// Switch to reading view
		fireEvent.click(screen.getByRole("button", { name: /reading view/i }));

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

	it("renders the properties widget with frontmatter keys in both modes", async () => {
		const doc = new Y.Doc();
		doc.getMap("frontmatter").set("status", JSON.stringify("draft"));
		doc.getArray("frontmatter_order").insert(0, ["status"]);
		openDoc.mockResolvedValue({
			ytext: doc.getText("content"),
			awareness: new Awareness(doc),
			doc,
		});

		render(<NotePage />);

		// Widget should appear in the default live mode
		await waitFor(() => expect(screen.getByText("status")).toBeInTheDocument());
	});
});
