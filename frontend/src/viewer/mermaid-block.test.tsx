import { render, screen } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";
import { chromeText } from "@/i18n/ui-chrome.testing";
import MermaidBlock from "./mermaid-block";
import { rememberMermaidHeight } from "./mermaid-render";

vi.mock("mermaid", () => ({
	default: {
		initialize: () => undefined,
		render: () => Promise.reject(new Error("Parse error on line 2")),
	},
}));
vi.mock("../theme/theme-provider", () => ({ useTheme: () => ({ resolved: "light" }) }));

describe("MermaidBlock", () => {
	// Reserved up front, so the diagram drawing in late does not push the note
	// below it down.
	it("reserves the height the diagram last drew at", () => {
		rememberMermaidHeight("reading", "graph TD", 178);
		const { container } = render(<MermaidBlock code="graph TD" />);
		expect(container.querySelector<HTMLElement>(".mermaid")?.style.minHeight).toBe("178px");
	});

	// Mermaid's parse error is third-party English: keep it verbatim, but mark its language.
	it("renders the parse error verbatim inside a lang=en element", async () => {
		render(<MermaidBlock code="graph LR" />);
		const err = await screen.findByText("Parse error on line 2");
		expect(err.getAttribute("lang")).toBe("en");
		expect(err.closest("pre")?.textContent).toBe(
			"Mermaid error: Parse error on line 2\n\ngraph LR",
		);
	});

	// Inside a note body the leak scan reads only marked chrome: our prefix,
	// not Mermaid's message nor the user's diagram source.
	it("marks only the translated prefix as UI chrome", async () => {
		const { container } = render(<MermaidBlock code="graph LR" />);
		await screen.findByText("Parse error on line 2");
		expect(chromeText(container)).toBe("Mermaid error: ");
	});
});
