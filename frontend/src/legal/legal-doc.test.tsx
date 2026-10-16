import { render, screen } from "@testing-library/react";
import { describe, expect, it } from "vitest";
import { LegalDoc } from "./legal-doc";
import { loadVersion, renderableVersion } from "./load";

// The one test that renders the real vendored texts; the page tests use short
// stand-ins. A full document through react-markdown takes ~1s on an idle box,
// so this test gets a budget sized for a loaded CI runner.
describe("LegalDoc with the bundled texts", () => {
	it.each([
		["terms", /Terms of Service/iu],
		["privacy", /Privacy Policy/iu],
	] as const)(
		"renders the current %s document",
		async (doc, title) => {
			const version = renderableVersion(doc, "9999-12-31");
			expect(version).toBeDefined();
			render(<LegalDoc source={await loadVersion(doc, version as string)} />);
			expect(screen.getAllByRole("heading", { name: title }).length).toBeGreaterThan(0);
		},
		20_000,
	);
});
