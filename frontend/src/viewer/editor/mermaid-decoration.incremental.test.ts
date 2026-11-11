import { EditorState } from "@codemirror/state";
import { EditorView } from "@codemirror/view";
import { afterEach, describe, expect, test } from "vitest";
import { enterMermaidDown, mermaidDecoration } from "./mermaid-decoration";
import { diffFromFresh, parsedState, placed } from "./render-test-utils";

const ext = [mermaidDecoration];
const BLOCK = "para\n\n```mermaid\ngraph LR\n  A --> B\n```\n\n```ts\nconst x = 1;\n```\n\n";
const diff = (s: EditorState) => diffFromFresh(s, ext, mermaidDecoration);

let view: EditorView | undefined;
afterEach(() => view?.destroy());

describe("mermaid renders incrementally", () => {
	test("a keystroke far from a diagram keeps its widget (no rebuild, no redraw)", () => {
		const s = parsedState(BLOCK.repeat(800), ext);
		const first = placed(s.field(mermaidDecoration)).at(0);
		const after = s.update({ changes: { from: s.doc.length, insert: "x" } }).state;
		expect(placed(after.field(mermaidDecoration)).at(0)?.[2]).toBe(first?.[2]);
		expect(diff(after)).toEqual([]);
	});

	test("opening a fence above swallows the diagrams below; closing it restores them", () => {
		let s = parsedState(BLOCK.repeat(50), ext);
		s = s.update({ changes: { from: 0, insert: "````\n" } }).state;
		expect(placed(s.field(mermaidDecoration))).toEqual([]);
		expect(diff(s)).toEqual([]);
		s = s.update({ changes: { from: s.doc.line(100).from, insert: "````\n" } }).state;
		expect(diff(s)).toEqual([]);
		expect(placed(s.field(mermaidDecoration)).length).toBeGreaterThan(0);
	});

	test("arrow-key entry still finds a fence after edits above it", () => {
		const doc = "a\nb\n```mermaid\ngraph LR\n```\nafter\n";
		view = new EditorView({
			state: EditorState.create({ doc, extensions: ext, selection: { anchor: 0 } }),
			parent: document.body,
		});
		view.dispatch({ changes: { from: 0, insert: "zz\n" }, selection: { anchor: 5 } });
		expect(enterMermaidDown(view)).toBe(true);
		expect(view.state.selection.main.head).toBe(view.state.doc.toString().indexOf("```mermaid"));
	});
});
