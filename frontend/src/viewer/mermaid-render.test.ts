import { describe, expect, it, vi } from "vitest";

const initialize = vi.fn();
const render = vi.fn(async () => ({ svg: "<svg></svg>" }));
vi.mock("mermaid", () => ({ default: { initialize, render } }));

const { nextMermaidId, renderMermaid } = await import("./mermaid-render");

describe("renderMermaid", () => {
	// Mermaid 12 defaults `layout` to "elk", which downloads a 1.4 MB layout
	// engine for every diagram. Obsidian draws with dagre; so do we. A diagram
	// can still opt into ELK through its own config.
	it("lays diagrams out with dagre, never the ELK default", async () => {
		await renderMermaid(nextMermaidId(), "graph TD; A-->B", false);
		await renderMermaid(nextMermaidId(), "graph TD; A-->B", true);
		expect(initialize).toHaveBeenCalled();
		for (const [config] of initialize.mock.calls) {
			expect(config).toMatchObject({ layout: "dagre" });
		}
	});
});
