// Smoke test for the dev-only QC gallery. It mounts three real pages against
// seeded caches, so it breaks loudly if any of them starts requiring a provider
// or query key the gallery doesn't supply, otherwise the page silently
// white-screens and QC is done against nothing.
import { render, screen } from "@testing-library/react";
import { MemoryRouter } from "react-router";
import { describe, expect, it } from "vitest";
import ConnectorQcPage from "./connector-qc-page";

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
