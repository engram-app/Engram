import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { MemoryRouter, Route, Routes } from "react-router";
import { beforeAll, beforeEach, expect, it, vi } from "vitest";
import { ApiError, api } from "../api/client";
import type { AttachmentSummary } from "../api/queries";
import AttachmentPage from "./attachment-page";

// Stub the heavy pdf.js viewer — this suite only verifies routing-by-mime, not
// pdf.js rendering (covered in pdf-view.test.tsx).
vi.mock("./pdf-view", () => ({
	default: ({ filename }: { filename: string }) => <div data-testid="pdf-view">pdf {filename}</div>,
}));

// AttachmentPage resolves the route :id against the attachments list. Drive that
// list from the test (must be `mock*`-prefixed for vitest's vi.mock hoist guard).
let mockAttachments: AttachmentSummary[] = [];
let mockLoading = false;
let mockBacklinks: { source_note_id: string; source_path: string; source_title: string | null }[] =
	[];
vi.mock("../api/queries", () => ({
	useAttachments: () => ({ data: mockAttachments, isLoading: mockLoading }),
	useAttachmentBacklinks: () => ({ data: mockBacklinks }),
	useFolders: () => ({ data: [] }),
	useRenameAttachment: () => ({ mutate: vi.fn() }),
	useBatchMoveAttachments: () => ({ mutate: vi.fn() }),
	useBatchDeleteAttachments: () => ({ mutate: vi.fn() }),
}));

const att = (over: Partial<AttachmentSummary> & { id: string }): AttachmentSummary => ({
	path: "doc.pdf",
	mime_type: "application/pdf",
	size_bytes: 1,
	mtime: 0,
	updated_at: "2026-10-20T12:00:00Z",
	...over,
});

beforeAll(() => {
	URL.createObjectURL = vi.fn(() => "blob:fake");
	URL.revokeObjectURL = vi.fn();
});

beforeEach(() => {
	mockAttachments = [];
	mockLoading = false;
	mockBacklinks = [];
	vi.restoreAllMocks();
});

function renderAt(id: string) {
	return render(
		<MemoryRouter initialEntries={[`/v/work/${id}`]}>
			<Routes>
				<Route path="/v/:slug/:itemId" element={<AttachmentPage />} />
			</Routes>
		</MemoryRouter>,
	);
}

it("renders an <img> for an image attachment, fetching bytes by path", async () => {
	mockAttachments = [att({ id: "img-1", path: "img/a.png", mime_type: "image/png" })];
	vi.spyOn(api, "getBlob").mockResolvedValueOnce(new Blob(["x"], { type: "image/png" }));
	renderAt("img-1");
	await waitFor(() => expect(screen.getByRole("img")).toBeInTheDocument());
	expect(api.getBlob).toHaveBeenCalledWith("/attachments/img/a.png?raw=1");
});

it("renders the pdf.js viewer for a pdf attachment", async () => {
	mockAttachments = [att({ id: "pdf-1", path: "reports/q3.pdf" })];
	vi.spyOn(api, "getBlob").mockResolvedValueOnce(new Blob(["x"], { type: "application/pdf" }));
	renderAt("pdf-1");
	await waitFor(() => expect(screen.getByTestId("pdf-view")).toBeInTheDocument());
	expect(screen.getByTestId("pdf-view")).toHaveTextContent("q3.pdf");
});

it("shows the file card for a type with no preview, without fetching its bytes", () => {
	mockAttachments = [
		att({ id: "zip-1", path: "stuff/a.zip", mime_type: "application/zip", size_bytes: 1536 }),
	];
	mockBacklinks = [{ source_note_id: "n-1", source_path: "Inbox/Plan.md", source_title: null }];
	const getBlob = vi.spyOn(api, "getBlob");
	renderAt("zip-1");
	expect(screen.getByRole("heading", { name: "a.zip" })).toBeInTheDocument();
	expect(screen.getByText("1.5 kB")).toBeInTheDocument();
	expect(screen.getByText("application/zip")).toBeInTheDocument();
	expect(screen.getByRole("link", { name: "Plan" })).toHaveAttribute("href", "/v/work/n-1");
	expect(screen.queryByRole("link", { name: /open in new tab/iu })).not.toBeInTheDocument();
	expect(getBlob).not.toHaveBeenCalled();
});

it("fetches the bytes when Download is clicked on a card-only file", async () => {
	mockAttachments = [att({ id: "zip-1", path: "a.zip", mime_type: "application/zip" })];
	const getBlob = vi.spyOn(api, "getBlob").mockResolvedValueOnce(new Blob(["x"]));
	renderAt("zip-1");
	fireEvent.click(screen.getByRole("button", { name: "Download" }));
	await waitFor(() => expect(getBlob).toHaveBeenCalledWith("/attachments/a.zip?raw=1"));
});

it("says no notes link to the file when nothing does", () => {
	mockAttachments = [att({ id: "zip-1", path: "a.zip", mime_type: "application/zip" })];
	renderAt("zip-1");
	expect(screen.getByText(/no notes link to this file yet/iu)).toBeInTheDocument();
});

it("previews a text file as read-only text", async () => {
	mockAttachments = [
		att({ id: "t-1", path: "logs/app.log", mime_type: "application/octet-stream" }),
	];
	vi.spyOn(api, "getBlob").mockResolvedValueOnce(new Blob(["line one\nline two"]));
	renderAt("t-1");
	expect(await screen.findByText(/line one/u)).toBeInTheDocument();
});

it("previews a CSV as a table", async () => {
	mockAttachments = [att({ id: "c-1", path: "t.csv", mime_type: "text/csv" })];
	vi.spyOn(api, "getBlob").mockResolvedValueOnce(new Blob(["name,qty\napple,3"]));
	renderAt("c-1");
	expect(await screen.findByRole("columnheader", { name: "name" })).toBeInTheDocument();
	expect(screen.getByRole("cell", { name: "apple" })).toBeInTheDocument();
});

it("plays audio natively", async () => {
	mockAttachments = [att({ id: "a-1", path: "s.mp3", mime_type: "audio/mpeg" })];
	vi.spyOn(api, "getBlob").mockResolvedValueOnce(new Blob(["x"], { type: "audio/mpeg" }));
	const { container } = renderAt("a-1");
	await waitFor(() => expect(container.querySelector("audio")).toHaveAttribute("src", "blob:fake"));
});

it("never opens an SVG blob in a new tab", async () => {
	mockAttachments = [att({ id: "s-1", path: "x.svg", mime_type: "image/svg+xml" })];
	vi.spyOn(api, "getBlob").mockResolvedValueOnce(new Blob(["<svg/>"], { type: "image/svg+xml" }));
	renderAt("s-1");
	await screen.findByRole("img");
	expect(screen.queryByRole("link", { name: /open in new tab/iu })).not.toBeInTheDocument();
});

it("opens a PNG in a new tab once loaded", async () => {
	mockAttachments = [att({ id: "i-1", path: "a.png", mime_type: "image/png" })];
	vi.spyOn(api, "getBlob").mockResolvedValueOnce(new Blob(["x"], { type: "image/png" }));
	renderAt("i-1");
	expect(await screen.findByRole("link", { name: /open in new tab/iu })).toHaveAttribute(
		"target",
		"_blank",
	);
});

it('shows a transient error (not "missing") when the byte fetch fails with a 5xx', async () => {
	mockAttachments = [att({ id: "img-1", path: "x.png", mime_type: "image/png" })];
	vi.spyOn(api, "getBlob").mockRejectedValueOnce(new ApiError(502, "storage down"));
	renderAt("img-1");
	await waitFor(() => expect(screen.getByText(/temporarily unavailable/iu)).toBeInTheDocument());
	expect(screen.queryByText(/no longer exists/iu)).not.toBeInTheDocument();
});

it('shows "no longer exists" when the byte fetch 404s', async () => {
	mockAttachments = [att({ id: "img-1", path: "gone.png", mime_type: "image/png" })];
	vi.spyOn(api, "getBlob").mockRejectedValueOnce(new ApiError(404, "not found"));
	renderAt("img-1");
	await waitFor(() => expect(screen.getByText(/no longer exists/iu)).toBeInTheDocument());
});

it("shows a centered loading spinner before the bytes resolve", () => {
	mockAttachments = [att({ id: "img-1", path: "slow.png", mime_type: "image/png" })];
	vi.spyOn(api, "getBlob").mockReturnValueOnce(new Promise<Blob>(() => {}));
	renderAt("img-1");
	expect(screen.getByRole("status")).toBeInTheDocument();
});

it('shows "not found" when no attachment matches the id', () => {
	mockAttachments = [att({ id: "other" })];
	renderAt("missing-id");
	expect(screen.getByText(/not found/iu)).toBeInTheDocument();
});

// An attachment is a page in the vault like a note: same surface and header,
// not a bare preview that replaces the document view.
it("shows the document header with folder and filename while the bytes load", () => {
	mockAttachments = [att({ id: "p-1", path: "Medical/lab.pdf" })];
	vi.spyOn(api, "getBlob").mockReturnValue(new Promise(() => undefined));
	renderAt("p-1");
	expect(screen.getByTestId("document-surface")).toBeInTheDocument();
	expect(screen.getByText("Medical/")).toBeInTheDocument();
	expect(screen.getByText("lab.pdf")).toBeInTheDocument();
	expect(screen.getByRole("button", { name: "Download lab.pdf" })).toBeEnabled();
});

it("downloads from the loaded bytes without fetching again", async () => {
	mockAttachments = [att({ id: "i-1", path: "a.png", mime_type: "image/png" })];
	const getBlob = vi
		.spyOn(api, "getBlob")
		.mockResolvedValueOnce(new Blob(["x"], { type: "image/png" }));
	renderAt("i-1");
	await screen.findByRole("img");
	fireEvent.click(screen.getByRole("button", { name: "Download a.png" }));
	expect(getBlob).toHaveBeenCalledTimes(1);
});

it("skips the preview past the size cap", () => {
	mockAttachments = [
		att({ id: "v-1", path: "big.mp4", mime_type: "video/mp4", size_bytes: 200 * 1024 * 1024 }),
	];
	const getBlob = vi.spyOn(api, "getBlob");
	renderAt("v-1");
	expect(screen.getByRole("heading", { name: "big.mp4" })).toBeInTheDocument();
	expect(getBlob).not.toHaveBeenCalled();
});
