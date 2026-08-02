// Smoke test for the dev-only QC gallery. It mounts three real pages against
// seeded caches, so it breaks loudly if any of them starts requiring a provider
// or query key the gallery doesn't supply, otherwise the page silently
// white-screens and QC is done against nothing.
import { render, screen } from "@testing-library/react";
import { MemoryRouter } from "react-router";
import { describe, expect, it, vi } from "vitest";
import ConnectorQcPage from "./connector-qc-page";

// Mounting three full pages costs ~1.5s of real work in jsdom — 13 connection
// cards, the checklist and the FTUX picker, each injecting raw brand SVGs. That
// is only 3x under the 5s default, and full-suite contention on a shared runner
// eats the margin: measured 1.7s in isolation, >5s at 20-way parallelism.
// Nothing is hanging or looping here, the budget is just wrong for a smoke test
// that renders this much. Same treatment as markdown-reference-panel.test.tsx.
vi.setConfig({ testTimeout: 20_000 });

function renderGallery() {
	return render(
		<MemoryRouter>
			<ConnectorQcPage />
		</MemoryRouter>,
	);
}

describe("ConnectorQcPage", () => {
	it("mounts all three panels without throwing", () => {
		renderGallery();

		expect(screen.getByRole("heading", { name: /connector qc/iu })).toBeInTheDocument();
		expect(screen.getByRole("heading", { name: /^connections page$/iu })).toBeInTheDocument();
		expect(screen.getByRole("heading", { name: /finish-setup checklist/iu })).toBeInTheDocument();
		expect(screen.getByRole("heading", { name: /ftux tool picker/iu })).toBeInTheDocument();
	});

	it("renders the connector states the gallery exists to show", () => {
		renderGallery();

		// Verified vendor, recognized-local, and unrecognized all present. The
		// fixture registers as "Claude Code (engram)"; the card shows the catalog
		// spelling, so the user-chosen suffix must not survive to the UI.
		expect(screen.getAllByText(/^Claude Code$/u).length).toBeGreaterThan(0);
		expect(screen.queryByText(/\(engram\)/u)).toBeNull();
		expect(screen.getAllByText(/some-random-agent/iu).length).toBeGreaterThan(0);

		// Exactly one chip: the unrecognized client. Recognized ones are plain.
		expect(screen.getAllByText(/^unverified$/iu)).toHaveLength(1);

		// The greyed Gemini row from the FTUX picker, its explanation is behind
		// the HelpTip trigger, so assert the affordance, not the copy.
		expect(
			screen.getByRole("button", { name: /why gemini can't be connected/iu }),
		).toBeInTheDocument();
	});
});
