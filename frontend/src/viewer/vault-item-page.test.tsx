import { render, screen } from "@testing-library/react";
import { MemoryRouter, Route, Routes } from "react-router";
import { beforeEach, expect, it, vi } from "vitest";
import type { AttachmentSummary } from "../api/queries";
import VaultItemPage from "./vault-item-page";

// Stub both heavy viewers — this suite only verifies the note-vs-attachment
// routing decision, not their rendering.
//
// NotePage comes through ./note-chunks (the preloadable wrapper), so stub it
// there: mocking ./note-page alone leaves the wrapper resolving a real dynamic
// import, which is neither what this suite is testing nor reliable under
// happy-dom.
vi.mock("./note-chunks", () => ({
	NotePage: () => <div data-testid="note-page" />,
	VaultItemPage: () => null,
	NoteEditor: () => null,
	preloadNoteChunks: () => {},
}));
vi.mock("./attachment-page", () => ({ default: () => <div data-testid="attachment-page" /> }));

let mockAttachments: AttachmentSummary[] | undefined = [];
let mockLoading = false;
vi.mock("../api/queries", () => ({
	useAttachments: () => ({ data: mockAttachments, isLoading: mockLoading }),
}));

const att = (id: string): AttachmentSummary => ({
	id,
	path: `${id}.png`,
	mime_type: "image/png",
	size_bytes: 1,
	mtime: 0,
	updated_at: "",
});

beforeEach(() => {
	mockAttachments = [];
	mockLoading = false;
});

function renderAt(id: string) {
	return render(
		<MemoryRouter initialEntries={[`/v/work/${id}`]}>
			<Routes>
				<Route path="/v/:slug/:itemId" element={<VaultItemPage />} />
			</Routes>
		</MemoryRouter>,
	);
}

async function renderAndAwaitChild(id: string) {
	renderAt(id);
	// Let the lazy child resolve.
	await screen.findByTestId(/page$/u);
}

it("renders the attachment viewer when the id is in the attachments list", async () => {
	mockAttachments = [att("file-1")];
	await renderAndAwaitChild("file-1");
	expect(screen.getByTestId("attachment-page")).toBeInTheDocument();
	expect(screen.queryByTestId("note-page")).not.toBeInTheDocument();
});

it("renders the note viewer when the id is not an attachment", async () => {
	mockAttachments = [att("file-1")];
	await renderAndAwaitChild("note-99");
	expect(screen.getByTestId("note-page")).toBeInTheDocument();
	expect(screen.queryByTestId("attachment-page")).not.toBeInTheDocument();
});

it("waits (no NotePage) while the attachments list is still loading on a cold deep-link", () => {
	// The race the resolver exists to handle: list not yet loaded. Must NOT mount
	// NotePage (which would fire a doomed note fetch for an attachment id).
	mockAttachments = undefined;
	mockLoading = true;
	renderAt("unknown-id");
	expect(screen.getByRole("status")).toBeInTheDocument();
	expect(screen.queryByTestId("note-page")).not.toBeInTheDocument();
	expect(screen.queryByTestId("attachment-page")).not.toBeInTheDocument();
});
