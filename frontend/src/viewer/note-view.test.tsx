import { fireEvent, render, screen } from "@testing-library/react";
import { MemoryRouter, Route, Routes, useLocation } from "react-router";
import { beforeEach, describe, expect, it, vi } from "vitest";

import NoteView from "./note-view";
import type { ManifestNote, NoteLinkEdge } from "./wiki-link";

let mockTier: "free" | "starter" | "pro" | "trial" | "none" = "free";
// SaaS by default; self-host flips false (no billing → attachments ungated).
let billingEnabled = true;
const showUpgradeMock = vi.fn();

vi.mock("../api/queries", async () => {
	const actual = await vi.importActual<typeof import("../api/queries")>("../api/queries");
	return {
		...actual,
		useBillingStatus: () => ({ data: { tier: mockTier } }),
	};
});

vi.mock("../config-context", async () => {
	const actual = await vi.importActual<typeof import("../config-context")>("../config-context");
	return {
		...actual,
		useConfig: () => ({ billingEnabled }) as ReturnType<typeof actual.useConfig>,
	};
});

beforeEach(() => {
	billingEnabled = true;
});

vi.mock("@/billing/upgrade-dialog-provider", () => ({
	useUpgradeDialog: () => ({ showUpgrade: showUpgradeMock }),
}));

// AttachmentImg fires a network request via api.getBlob; stub so the
// integration assertion only inspects which branch was taken.
vi.mock("./attachment-img", () => ({
	default: ({ path }: { path: string }) => <span data-testid="attachment-img">{path}</span>,
}));

vi.mock("./mermaid-block", () => ({
	default: () => null,
}));

function LocationProbe() {
	const loc = useLocation();
	return <output data-testid="loc">{`${loc.pathname}${loc.hash}`}</output>;
}

// NoteView reads the vault slug from the route to build wikilink hrefs.
function renderNote(content: string, links?: NoteLinkEdge[], manifestNotes?: ManifestNote[]) {
	return render(
		<MemoryRouter initialEntries={["/work/n-1"]}>
			<LocationProbe />
			<Routes>
				<Route
					path="/:slug/:itemId"
					element={
						<NoteView content={content} tags={[]} links={links} manifestNotes={manifestNotes} />
					}
				/>
			</Routes>
		</MemoryRouter>,
	);
}

describe("NoteView wikilinks", () => {
	it("links [[Page]] into the vault wiki resolver, name unmangled", () => {
		renderNote("See [[Folder/My Note]].");
		const link = screen.getByRole("link", { name: "Folder/My Note" });
		expect(link).toHaveAttribute("href", "/work/wiki/Folder/My%20Note");
	});

	it("renders the alias as the link text", () => {
		renderNote("See [[My Note|the note]].");
		const link = screen.getByRole("link", { name: "the note" });
		expect(link).toHaveAttribute("href", "/work/wiki/My%20Note");
	});

	it("carries a heading as a slugged hash", () => {
		renderNote("See [[My Note#Some Section]].");
		const link = screen.getByRole("link", { name: "My Note#Some Section" });
		expect(link).toHaveAttribute("href", "/work/wiki/My%20Note#some-section");
	});

	it("navigates in-app instead of a full page load", () => {
		renderNote("See [[My Note]].");
		fireEvent.click(screen.getByRole("link", { name: "My Note" }));
		expect(screen.getByTestId("loc")).toHaveTextContent("/work/wiki/My%20Note");
	});

	it("links straight to the note id when the links prop resolves the target", () => {
		renderNote("See [[My Note]].", [
			{
				target_text: "My Note",
				target_note_id: "n-1",
				target_attachment_id: null,
				target_path: "My Note.md",
				alias: null,
				anchor: null,
				link_type: "wikilink",
				dangling: false,
			},
		]);
		const link = screen.getByRole("link", { name: "My Note" });
		expect(link).toHaveAttribute("href", "/work/n-1");
	});

	it("resolves a manifest-only target to the direct id href", () => {
		renderNote("See [[Fresh Note]].", [], [{ id: "m-9", path: "Sub/Fresh Note.md" }]);
		const link = screen.getByRole("link", { name: "Fresh Note" });
		expect(link).toHaveAttribute("href", "/work/m-9");
	});
});

// #1302 — a vault written with "Use [[Wikilinks]]" off gets markdown-syntax
// links. The backend indexes them as note_links edges; these prove the viewer
// routes them in-app instead of full-page-navigating to a non-route.
describe("NoteView markdown-syntax links", () => {
	const edge: NoteLinkEdge = {
		target_text: "My Note.md",
		target_note_id: "n-1",
		target_attachment_id: null,
		target_path: "My Note.md",
		alias: "label",
		anchor: null,
		link_type: "wikilink",
		dangling: false,
	};

	it("routes a resolved markdown link to the note id", () => {
		renderNote("See [label](My%20Note.md).", [edge]);
		expect(screen.getByRole("link", { name: "label" })).toHaveAttribute("href", "/work/n-1");
	});

	it("navigates in-app rather than reloading", () => {
		renderNote("See [label](My%20Note.md).", [edge]);
		fireEvent.click(screen.getByRole("link", { name: "label" }));
		expect(screen.getByTestId("loc")).toHaveTextContent("/work/n-1");
	});

	it("resolves through the manifest when no edge is indexed yet", () => {
		renderNote("See [x](Sub/Fresh%20Note.md).", [], [{ id: "m-9", path: "Sub/Fresh Note.md" }]);
		expect(screen.getByRole("link", { name: "x" })).toHaveAttribute("href", "/work/m-9");
	});

	it("leaves an external link untouched", () => {
		renderNote("See [ext](https://example.com).");
		expect(screen.getByRole("link", { name: "ext" })).toHaveAttribute(
			"href",
			"https://example.com",
		);
	});

	it("leaves an unresolved target as a plain anchor", () => {
		renderNote("See [x](Nope.md).");
		expect(screen.getByRole("link", { name: "x" })).toHaveAttribute("href", "Nope.md");
	});
});

describe("NoteView frontmatter table removal", () => {
	it("does not render the frontmatter dl table even when content has frontmatter", () => {
		renderNote("---\nstatus: draft\nauthor: alice\n---\n\nBody paragraph here.");
		expect(document.querySelector("dl")).toBeNull();
	});

	it("still renders the markdown body after removing the frontmatter table", () => {
		renderNote("---\nstatus: draft\n---\n\nBody paragraph here.");
		expect(screen.getByText("Body paragraph here.")).toBeInTheDocument();
	});
});

describe("NoteView attachment gating", () => {
	it("renders fallback lock for Free user on non-text embeds", () => {
		mockTier = "free";
		renderNote("Here is an embed:\n\n![[image.png]]\n");
		expect(screen.getByTestId("attachment-fallback-lock")).toBeInTheDocument();
		expect(screen.queryByTestId("attachment-img")).toBeNull();
	});

	it("renders AttachmentImg for paid tier on the same embed", () => {
		mockTier = "pro";
		renderNote("Here is an embed:\n\n![[image.png]]\n");
		expect(screen.getByTestId("attachment-img")).toHaveTextContent("image.png");
		expect(screen.queryByTestId("attachment-fallback-lock")).toBeNull();
	});

	it('renders AttachmentImg on self-host (billing disabled) even though tier is "free"', () => {
		billingEnabled = false;
		mockTier = "free";
		renderNote("Here is an embed:\n\n![[image.png]]\n");
		expect(screen.getByTestId("attachment-img")).toHaveTextContent("image.png");
		expect(screen.queryByTestId("attachment-fallback-lock")).toBeNull();
	});

	it("renders AttachmentImg even on Free for .md embeds (text)", () => {
		mockTier = "free";
		renderNote("Linked note:\n\n![[other.md]]\n");
		expect(screen.getByTestId("attachment-img")).toHaveTextContent("other.md");
		expect(screen.queryByTestId("attachment-fallback-lock")).toBeNull();
	});

	it("renders AttachmentImg on Free for .canvas embeds (text)", () => {
		mockTier = "free";
		renderNote("Embedded canvas:\n\n![[board.canvas]]\n");
		expect(screen.getByTestId("attachment-img")).toHaveTextContent("board.canvas");
		expect(screen.queryByTestId("attachment-fallback-lock")).toBeNull();
	});
});

describe("NoteView callout colour republish", () => {
	// The editor side of this contract is pinned in callout-decoration.test.ts;
	// the reading side was pinned by nothing. Both panes have to hand CSS the
	// same custom property or the callout TITLE loses its per-type colour in one
	// of them, which is precisely the drift the shared map exists to prevent.
	it("republishes the library's inline border colour as --callout-color", () => {
		renderNote("> [!tip] Better way\n> body\n");
		const quote = document.querySelector("blockquote");
		expect(quote).not.toBeNull();
		// The library inlines border-left-color per type. Whatever it picked, the
		// custom property has to carry the SAME value — asserting a specific hex
		// here would just re-encode the library's palette in a second place.
		const border = quote?.style.borderLeftColor;
		expect(border).toBeTruthy();
		expect(quote?.style.getPropertyValue("--callout-color")).toBe(border);
	});

	it("leaves a plain blockquote alone rather than inventing a colour", () => {
		// Only callouts get a border colour from the library. A plain quote has
		// none, and publishing an empty custom property would make the title rule
		// resolve to nothing instead of falling back to `inherit`.
		renderNote("> just a quotation\n");
		const quote = document.querySelector("blockquote");
		expect(quote?.style.getPropertyValue("--callout-color")).toBe("");
	});
});
