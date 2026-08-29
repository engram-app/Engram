import { render, screen } from "@testing-library/react";
import { MemoryRouter, Route, Routes } from "react-router";
import { describe, expect, it, vi } from "vitest";
import type { Backlink } from "../api/queries";
import BacklinksPanel from "./backlinks-panel";

let mockData: Backlink[] | undefined;
let mockIsLoading = false;

vi.mock("../api/queries", () => ({
	useBacklinks: () => ({ data: mockData, isLoading: mockIsLoading }),
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
