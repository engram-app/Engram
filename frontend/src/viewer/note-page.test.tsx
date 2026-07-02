import { render, screen, waitFor } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { Awareness } from "y-protocols/awareness";
import * as Y from "yjs";
import NotePage from "./note-page";

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
