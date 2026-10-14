import { describe, expect, it, vi } from "vitest";

const initialize = vi.fn();
const render = vi.fn(async () => ({ svg: "<svg></svg>" }));
vi.mock("mermaid", () => ({ default: { initialize, render } }));

const { nextMermaidId, renderMermaid, rememberMermaidHeight, rememberedMermaidHeight } =
	await import("./mermaid-render");

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

// A diagram draws late (lazy chunk, drawn when scrolled near), so its box grew
// from empty to full height after the note was already on screen, shoving every
// line below it down. Its last drawn height survives a reload so the box can be
// reserved before the SVG arrives.
describe("mermaid height memory", () => {
	it("recalls the height last drawn for the same source, per surface", () => {
		rememberMermaidHeight("editor", "graph TD; A-->B", 178);
		expect(rememberedMermaidHeight("editor", "graph TD; A-->B")).toBe(178);
		expect(rememberedMermaidHeight("reading", "graph TD; A-->B")).toBeUndefined();
		expect(rememberedMermaidHeight("editor", "graph TD; A-->C")).toBeUndefined();
	});

	it("keeps the newest heights once full, dropping the oldest", () => {
		for (let i = 0; i < 300; i++) {
			rememberMermaidHeight("editor", `graph ${i}`, i + 1);
		}
		expect(rememberedMermaidHeight("editor", "graph 0")).toBeUndefined();
		expect(rememberedMermaidHeight("editor", "graph 299")).toBe(300);
	});

	it("survives storage that throws or holds garbage", () => {
		localStorage.setItem("engram.mermaidHeights", "{not json");
		expect(rememberedMermaidHeight("editor", "graph TD")).toBeUndefined();
		const setItem = vi.spyOn(Storage.prototype, "setItem").mockImplementation(() => {
			throw new DOMException("quota", "QuotaExceededError");
		});
		expect(() => rememberMermaidHeight("editor", "graph TD", 10)).not.toThrow();
		setItem.mockRestore();
	});
});
