import { render, screen } from "@testing-library/react";
import { Suspense } from "react";
import { describe, expect, it, vi } from "vitest";
import { NotePage, preloadNoteChunks, VaultItemPage } from "./note-chunks";

// The module under test wires three real page chunks. Stub all three imports so
// this suite exercises `preloadable`'s caching behaviour, not the pages.
vi.mock("./vault-item-page", () => ({ default: () => <div>vault-item</div> }));
vi.mock("./note-page", () => ({ default: () => <div>note-page</div> }));
vi.mock("./note-editor", () => ({ default: () => <div>note-editor</div> }));

// These two tests are ORDER-DEPENDENT on purpose: the preloadable cache is
// module state, so the only way to observe the cold path is to use it before
// anything warms it. The cold test therefore runs first and must stay first.
describe("note-chunks", () => {
	it("suspends when cold, so the Suspense boundaries stay load-bearing", async () => {
		render(
			<Suspense fallback={<div>FALLBACK</div>}>
				<VaultItemPage />
			</Suspense>,
		);

		// Nothing has warmed this yet, so the boundary is doing real work.
		expect(screen.getByText("FALLBACK")).toBeInTheDocument();
		expect(await screen.findByText("vault-item")).toBeInTheDocument();
	});

	// The whole point of this module over `React.lazy`: once warm, the first
	// render must be synchronous. If a fallback can still appear, the preload
	// bought nothing the user can see — exactly the trap that made the naive
	// "call import() next to lazy()" version look like it worked (#1317).
	it("renders a warmed component with no Suspense fallback at all", async () => {
		preloadNoteChunks();
		// Let the stubbed dynamic imports resolve before the first render.
		await new Promise((r) => setTimeout(r, 0));

		render(
			<Suspense fallback={<div>FALLBACK</div>}>
				<NotePage />
			</Suspense>,
		);

		// Synchronously present: no findBy, no act tick, no fallback frame.
		expect(screen.getByText("note-page")).toBeInTheDocument();
		expect(screen.queryByText("FALLBACK")).not.toBeInTheDocument();
	});
});
