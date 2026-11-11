import { EditorState, type Extension } from "@codemirror/state";
import { EditorView, runScopeHandlers } from "@codemirror/view";
import { afterEach, describe, expect, test } from "vitest";
import { attachmentEmbeds } from "./attachment-embed";
import { calloutDecoration } from "./callout-decoration";
import { katexDecoration } from "./katex-decoration";
import { mermaidDecoration } from "./mermaid-decoration";

// ArrowDown / ArrowUp from the line next to a rendered widget must put the
// caret on the widget's source (revealing it, like a click), not step over it.
// Driven through the real key path (runScopeHandlers), for every widget the
// render core draws, with the widget mid-doc, at the start and at the end.

let view: EditorView | undefined;
afterEach(() => view?.destroy());

const embeds = attachmentEmbeds({
	resolve: (t) => `img/${t}`,
	load: () => new Promise(() => undefined),
});

const WIDGETS: [string, string, Extension, string][] = [
	["display math", "$$\nx^2\n$$", katexDecoration, ".cm-katex-widget"],
	["mermaid", "```mermaid\ngraph LR\n  A --> B\n```", mermaidDecoration, ".cm-mermaid-widget"],
	["image embed", "![[pic.png]]", embeds, ".cm-attachment-embed"],
	["callout", "> [!note] Callout", calloutDecoration, ".cm-callout-title"],
];

function mount(doc: string, ext: Extension, anchor: number) {
	view = new EditorView({
		state: EditorState.create({ doc, extensions: ext, selection: { anchor } }),
		parent: document.body,
	});
	return view;
}

function press(v: EditorView, key: "ArrowDown" | "ArrowUp") {
	return runScopeHandlers(v, new KeyboardEvent("keydown", { key }), "editor");
}

describe.each(WIDGETS)("arrow keys enter a rendered %s", (_name, block, ext, selector) => {
	test("ArrowDown from the line above lands on its first line and reveals it", () => {
		const doc = `above\n${block}\nbelow`;
		const v = mount(doc, ext, 0);
		expect(v.dom.querySelector(selector)).not.toBeNull();
		expect(press(v, "ArrowDown")).toBe(true);
		expect(v.state.selection.main.head).toBe(6);
		expect(v.dom.querySelector(selector)).toBeNull();
	});

	test("ArrowUp from the line below lands on its last line and reveals it", () => {
		const doc = `above\n${block}\nbelow`;
		const v = mount(doc, ext, doc.length);
		expect(press(v, "ArrowUp")).toBe(true);
		expect(v.state.selection.main.head).toBe(6 + block.length);
		expect(v.dom.querySelector(selector)).toBeNull();
	});

	test("at the start of the note, ArrowUp from below enters it", () => {
		const doc = `${block}\nbelow`;
		const v = mount(doc, ext, doc.length);
		expect(press(v, "ArrowUp")).toBe(true);
		expect(v.state.selection.main.head).toBe(block.length);
	});

	test("at the end of the note, ArrowDown from above enters it", () => {
		const doc = `above\n${block}`;
		const v = mount(doc, ext, 0);
		expect(press(v, "ArrowDown")).toBe(true);
		expect(v.state.selection.main.head).toBe(6);
	});
});

describe("ArrowDown walks one line per press past rendered blocks", () => {
	// happy-dom has no layout, so CM6's own cursorLineDown cannot be measured
	// here. This pins our half of the key path: every press is either handled by
	// the block-entry keymap (and then moves exactly one line) or left to the
	// default motion, never both. The default motion is modelled as "next line".
	test("through math, mermaid and a callout, then 20 plain lines", () => {
		const blocks = [
			"$$\nx^2\n$$",
			"```mermaid\ngraph LR\n  A --> B\n```",
			"> [!note] Callout\n> Some callout text",
		];
		const plain = Array.from({ length: 20 }, (_, i) =>
			i % 3 === 0 ? `- Item ${i}` : i % 3 === 1 ? "  - Nested" : "",
		);
		const doc = ["## Section", "", ...blocks.flatMap((b) => [b, ""]), ...plain].join("\n");
		const v = mount(doc, [katexDecoration, mermaidDecoration, calloutDecoration], 0);
		for (
			let pressed = 0;
			v.state.doc.lineAt(v.state.selection.main.head).number < v.state.doc.lines;
			pressed++
		) {
			const before = v.state.doc.lineAt(v.state.selection.main.head).number;
			if (!press(v, "ArrowDown")) {
				v.dispatch({ selection: { anchor: v.state.doc.line(before + 1).from } });
			}
			expect(v.state.doc.lineAt(v.state.selection.main.head).number, `press ${pressed}`).toBe(
				before + 1,
			);
		}
	});

	// The skip in a real browser: KaTeX's `.katex-display` margin collapsed out
	// of the widget, so CM6 measured the block 2em short and mapped every y below
	// it to the line after the one under it. The widget must contain its margins.
	test("a display math widget keeps KaTeX's margins inside the box CM6 measures", () => {
		const v = mount("a\n$$\nx\n$$\nb", katexDecoration, 0);
		const css = v.state
			.facet(EditorView.styleModule)
			.map((m) => m.getRules())
			.join("\n");
		expect(css).toMatch(/div\.cm-katex-widget[^{]*\{[^}]*display: flow-root/u);
	});
});
