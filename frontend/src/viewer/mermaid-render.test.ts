import { afterEach, describe, expect, it, vi } from "vitest";

const initialize = vi.fn();
const render = vi.fn(async (..._args: unknown[]) => ({ svg: '<svg data-drawn=""></svg>' }));
vi.mock("mermaid", () => ({ default: { initialize, render } }));

const { drawMermaid, renderMermaid, rememberMermaidHeight, rememberedMermaidHeight } = await import(
	"./mermaid-render"
);

afterEach(() => {
	render.mockClear();
	document.body.replaceChildren();
});

describe("renderMermaid", () => {
	// Mermaid 12 defaults `layout` to "elk", which downloads a 1.4 MB layout
	// engine for every diagram. Obsidian draws with dagre; so do we. A diagram
	// can still opt into ELK through its own config.
	it("lays diagrams out with dagre, never the ELK default", async () => {
		await renderMermaid("graph TD; A-->B", false);
		await renderMermaid("graph TD; A-->B", true);
		expect(initialize).toHaveBeenCalled();
		for (const [config] of initialize.mock.calls) {
			expect(config).toMatchObject({ layout: "dagre" });
		}
	});

	it("gives every render its own DOM id", async () => {
		await renderMermaid("graph TD", false);
		await renderMermaid("graph TD", false);
		const [first, second] = render.mock.calls.map(([id]) => id);
		expect(first).not.toBe(second);
	});
});

// Without a container, mermaid measures each diagram in a scratch div appended
// to <body>. That overflowed the page for the length of a render, so the
// window scrollbar flashed in and out and narrowed the note while it was there.
describe("render scratch space", () => {
	it("measures in a clipped, fixed container instead of <body>", async () => {
		await renderMermaid("graph TD; A-->B", false);
		const [call] = render.mock.calls;
		const [, , container] = call ?? [];
		expect(container).toBeInstanceOf(HTMLElement);
		const el = container as HTMLElement;
		expect(el.isConnected).toBe(true);
		expect(el.style.position).toBe("fixed");
		expect(el.style.overflow).toBe("hidden");
		expect(el.style.height).toBe("0px");
	});
});

describe("drawMermaid", () => {
	const noop = { drawn: () => undefined, failed: () => undefined };

	it("holds the remembered height until the SVG lands, then records the real one", async () => {
		rememberMermaidHeight("reading", "graph LR", 120);
		const el = document.createElement("div");
		document.body.append(el);
		const drawn = vi.fn();
		drawMermaid(el, "reading", "graph LR", false, { ...noop, drawn });
		expect(el.style.minHeight).toBe("120px");
		await vi.waitFor(() => expect(drawn).toHaveBeenCalledOnce());
		expect(el.querySelector("svg")).not.toBeNull();
		expect(el.style.minHeight).toBe("");
	});

	it("leaves the element alone once cancelled", async () => {
		const el = document.createElement("div");
		const drawn = vi.fn();
		const cancel = drawMermaid(el, "reading", "graph RL", false, { ...noop, drawn });
		cancel();
		await renderMermaid("graph RL", false);
		expect(drawn).not.toHaveBeenCalled();
		expect(el.innerHTML).toBe("");
	});

	it("reports a failed draw and drops the reservation", async () => {
		render.mockRejectedValueOnce(new Error("Parse error"));
		rememberMermaidHeight("editor", "graph BAD", 90);
		const el = document.createElement("div");
		const failed = vi.fn();
		drawMermaid(el, "editor", "graph BAD", false, { ...noop, failed });
		await vi.waitFor(() => expect(failed).toHaveBeenCalledOnce());
		expect(el.style.minHeight).toBe("");
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

	it("persists across a reload", async () => {
		rememberMermaidHeight("editor", "graph persisted", 64);
		vi.resetModules();
		const fresh = await import("./mermaid-render");
		expect(fresh.rememberedMermaidHeight("editor", "graph persisted")).toBe(64);
	});

	it("survives storage that throws or holds garbage", async () => {
		localStorage.setItem("engram.mermaidHeights", "{not json");
		vi.resetModules();
		const fresh = await import("./mermaid-render");
		expect(fresh.rememberedMermaidHeight("editor", "graph TD")).toBeUndefined();
		const setItem = vi.spyOn(Storage.prototype, "setItem").mockImplementation(() => {
			throw new DOMException("quota", "QuotaExceededError");
		});
		expect(() => fresh.rememberMermaidHeight("editor", "graph TD", 10)).not.toThrow();
		setItem.mockRestore();
	});
});
