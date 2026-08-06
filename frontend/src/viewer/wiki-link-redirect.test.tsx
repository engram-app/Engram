import { fireEvent, render, screen } from "@testing-library/react";
import { MemoryRouter, Route, Routes, useLocation } from "react-router";
import { beforeEach, describe, expect, it, vi } from "vitest";
import WikiLinkRedirect from "./wiki-link-redirect";

let mockManifest: { notes: { id: string; path: string }[] } | undefined;
let mockPending = false;
const createNoteMutate = vi.fn();

vi.mock("../api/queries", () => ({
	useSyncManifest: () => ({ data: mockManifest, isPending: mockPending }),
	useCreateNote: () => ({ mutate: createNoteMutate, isPending: false }),
}));

// NotFoundPage pulls in ThemeToggle, which needs a ThemeProvider we are not
// wiring up here. Same mock as vault-route.test.tsx.
vi.mock("../theme/theme-toggle", () => ({
	default: () => <button type="button">theme</button>,
}));

function LocationProbe() {
	const loc = useLocation();
	return <output data-testid="loc">{`${loc.pathname}${loc.hash}`}</output>;
}

function renderAt(entry: string) {
	return render(
		<MemoryRouter initialEntries={[entry]}>
			<LocationProbe />
			<Routes>
				<Route path="/:slug/wiki/*" element={<WikiLinkRedirect />} />
				<Route path="/:slug/:itemId" element={<p>note page</p>} />
			</Routes>
		</MemoryRouter>,
	);
}

beforeEach(() => {
	mockManifest = {
		notes: [
			{ id: "n-1", path: "Folder/My Note.md" },
			{ id: "n-2", path: "Elsewhere/Unique.md" },
		],
	};
	mockPending = false;
	createNoteMutate.mockClear();
});

describe("WikiLinkRedirect", () => {
	it("redirects an exact path target to the note id route", async () => {
		renderAt("/work/wiki/Folder/My%20Note");
		expect(await screen.findByTestId("loc")).toHaveTextContent("/work/n-1");
	});

	it("resolves a basename-only target vault-wide", async () => {
		renderAt("/work/wiki/Unique");
		expect(await screen.findByTestId("loc")).toHaveTextContent("/work/n-2");
	});

	it("preserves the heading hash across the redirect", async () => {
		renderAt("/work/wiki/Unique#some-heading");
		expect(await screen.findByTestId("loc")).toHaveTextContent("/work/n-2#some-heading");
	});

	it("waits rather than 404ing while the manifest loads", () => {
		mockManifest = undefined;
		mockPending = true;
		renderAt("/work/wiki/Unique");
		expect(screen.queryByText(/not found/i)).toBeNull();
	});

	describe("unresolved target — create affordance", () => {
		it("shows the create-note offer instead of a dead-end 404", () => {
			renderAt("/work/wiki/Ghost");
			expect(screen.getByText(/"Ghost" doesn't exist yet/i)).toBeInTheDocument();
			expect(screen.getByRole("button", { name: 'Create "Ghost"' })).toBeInTheDocument();
			expect(screen.getByRole("button", { name: "Back" })).toBeInTheDocument();
		});

		it("creates a bare target at the vault root", () => {
			renderAt("/work/wiki/songebobsss");

			fireEvent.click(screen.getByRole("button", { name: 'Create "songebobsss"' }));

			expect(createNoteMutate).toHaveBeenCalledWith(
				expect.objectContaining({ folder: "", name: "songebobsss.md" }),
			);
		});

		it("creates a path-qualified target at that path", () => {
			renderAt("/work/wiki/folder/sub/Name");

			fireEvent.click(screen.getByRole("button", { name: 'Create "Name"' }));

			expect(createNoteMutate).toHaveBeenCalledWith(
				expect.objectContaining({ folder: "folder/sub", name: "Name.md" }),
			);
		});

		it("strips a #heading segment before deriving the create path", () => {
			renderAt("/work/wiki/Ghost#Some%20Heading");

			fireEvent.click(screen.getByRole("button", { name: 'Create "Ghost"' }));

			expect(createNoteMutate).toHaveBeenCalledWith(
				expect.objectContaining({ folder: "", name: "Ghost.md" }),
			);
		});
	});
});
