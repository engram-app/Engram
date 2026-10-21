import { render, screen } from "@testing-library/react";
import { MemoryRouter, Route, Routes } from "react-router";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { Backlink } from "../api/queries";
import BacklinksPanel from "./backlinks-panel";

let mockData: Backlink[] | undefined;
let mockIsLoading = false;

let mockAttachmentData: Backlink[] | undefined;
vi.mock("../api/queries", () => ({
	useBacklinks: () => ({ data: mockData, isLoading: mockIsLoading }),
	useAttachmentBacklinks: () => ({ data: mockAttachmentData, isLoading: false }),
}));

function renderPanel(noteId: string | null = "note-1") {
	return render(
		<MemoryRouter initialEntries={["/v/work/note-1"]}>
			<Routes>
				<Route path="/v/:slug/:itemId" element={<BacklinksPanel noteId={noteId} />} />
			</Routes>
		</MemoryRouter>,
	);
}

// Module-level mock state is shared across every test in the file (vitest
// isolates per FILE, not per test), and one test here sets mockIsLoading =
// true. Every current test happens to assign both vars itself, so this reset
// changes no result today -- it exists so the NEXT test appended to the file
// does not silently inherit a stale flag, render nothing, and fail pointing
// at the component rather than at test ordering.
beforeEach(() => {
	mockData = undefined;
	mockIsLoading = false;
	mockAttachmentData = undefined;
});

describe("BacklinksPanel for an attachment", () => {
	it("lists the notes linking to the attachment", () => {
		mockAttachmentData = [
			{
				source_note_id: "src-9",
				source_path: "Inbox/Plan.md",
				source_title: null,
				alias: null,
				anchor: null,
			},
		];
		render(
			<MemoryRouter initialEntries={["/v/work/att-1"]}>
				<Routes>
					<Route path="/v/:slug/:itemId" element={<BacklinksPanel attachmentId="att-1" />} />
				</Routes>
			</MemoryRouter>,
		);
		expect(screen.getByRole("link", { name: "Plan" })).toHaveAttribute("href", "/v/work/src-9");
	});
});

describe("BacklinksPanel", () => {
	it("renders one row per backlink, linking to the source note under the current vault slug", () => {
		mockData = [
			{
				source_note_id: "src-1",
				source_path: "Projects/Alpha.md",
				source_title: "Alpha",
				alias: null,
				anchor: null,
			},
			{
				source_note_id: "src-2",
				source_path: "Projects/Beta.md",
				source_title: "Beta",
				alias: null,
				anchor: null,
			},
		];
		mockIsLoading = false;
		renderPanel();

		const alpha = screen.getByRole("link", { name: "Alpha" });
		expect(alpha).toHaveAttribute("href", "/v/work/src-1");
		const beta = screen.getByRole("link", { name: "Beta" });
		expect(beta).toHaveAttribute("href", "/v/work/src-2");
	});

	it("falls back to the path basename when the source title is null", () => {
		mockData = [
			{
				source_note_id: "src-3",
				source_path: "Projects/Gamma.md",
				source_title: null,
				alias: null,
				anchor: null,
			},
		];
		mockIsLoading = false;
		renderPanel();

		expect(screen.getByRole("link", { name: "Gamma" })).toHaveAttribute("href", "/v/work/src-3");
	});

	it("shows an empty state when there are no backlinks", () => {
		mockData = [];
		mockIsLoading = false;
		renderPanel();

		expect(screen.getByText("No backlinks yet")).toBeInTheDocument();
		expect(screen.queryByRole("link")).toBeNull();
	});

	it("renders nothing while loading", () => {
		mockData = undefined;
		mockIsLoading = true;
		const { container } = renderPanel();

		expect(container).toBeEmptyDOMElement();
	});
});
