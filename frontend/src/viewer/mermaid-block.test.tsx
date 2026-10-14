import { render, screen } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";
import MermaidBlock from "./mermaid-block";

vi.mock("./mermaid-render", () => ({
	nextMermaidId: () => "m1",
	renderMermaid: () => Promise.reject(new Error("Parse error on line 2")),
}));
vi.mock("../theme/theme-provider", () => ({ useTheme: () => ({ resolved: "light" }) }));

describe("MermaidBlock", () => {
	// Mermaid's parse error is third-party English: keep it verbatim, but mark its language.
	it("renders the parse error verbatim inside a lang=en element", async () => {
		render(<MermaidBlock code="graph LR" />);
		const err = await screen.findByText("Parse error on line 2");
		expect(err.getAttribute("lang")).toBe("en");
		expect(err.closest("pre")?.textContent).toBe(
			"Mermaid error: Parse error on line 2\n\ngraph LR",
		);
	});
});
