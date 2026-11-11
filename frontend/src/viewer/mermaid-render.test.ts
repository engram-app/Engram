import { afterEach, describe, expect, it, vi } from "vitest";

const renderAsync = vi.fn(async (..._args: unknown[]) => ({ svg: '<svg data-drawn=""></svg>' }));
vi.mock("pele/lazy", () => ({ renderAsync }));

const { drawMermaid, renderMermaid, rememberMermaidHeight, rememberedMermaidHeight } = await import(
	"./mermaid-render"
);

afterEach(() => {
	renderAsync.mockClear();
	document.body.replaceChildren();
});

describe("renderMermaid", () => {
	// Diagrams are note content. Pele's security page: keep the options ours,
	// and the hooks it inserts unfiltered (icons, math) are never passed.
	it("renders with remote images off, no-referrer links and no unfiltered hooks", async () => {
		await renderMermaid("graph TD; A-->B");
		const [, options] = renderAsync.mock.calls[0] ?? [];
		expect(options).toMatchObject({ images: false, linkRel: "noopener noreferrer nofollow" });
		expect(options).not.toHaveProperty("icons");
		expect(options).not.toHaveProperty("math");
	});

	it("gives every render its own id prefix, so two diagrams on a page never share ids", async () => {
		await renderMermaid("graph TD");
		await renderMermaid("graph TD");
		const [first, second] = renderAsync.mock.calls.map(
			([, o]) => (o as { idPrefix: string }).idPrefix,
		);
		expect(first).not.toBe(second);
	});
});

describe("drawMermaid", () => {
	const noop = { drawn: () => undefined, failed: () => undefined };

	it("holds the remembered height until the SVG lands, then records the real one", async () => {
		rememberMermaidHeight("reading", "graph LR", 120);
		const el = document.createElement("div");
		document.body.append(el);
		const drawn = vi.fn();
		drawMermaid(el, "reading", "graph LR", { ...noop, drawn });
		expect(el.style.minHeight).toBe("120px");
		await vi.waitFor(() => expect(drawn).toHaveBeenCalledOnce());
		expect(el.querySelector("svg")).not.toBeNull();
		expect(el.style.minHeight).toBe("");
	});

	it("leaves the element alone once cancelled", async () => {
		const el = document.createElement("div");
		const drawn = vi.fn();
		const cancel = drawMermaid(el, "reading", "graph RL", { ...noop, drawn });
		cancel();
		await renderMermaid("graph RL");
		expect(drawn).not.toHaveBeenCalled();
		expect(el.innerHTML).toBe("");
	});

	it("reports a failed draw and drops the reservation", async () => {
		renderAsync.mockRejectedValueOnce(new Error("Parse error"));
		rememberMermaidHeight("editor", "graph BAD", 90);
		const el = document.createElement("div");
		const failed = vi.fn();
		drawMermaid(el, "editor", "graph BAD", { ...noop, failed });
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
