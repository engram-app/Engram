import { EditorState } from "@codemirror/state";
import { EditorView } from "@codemirror/view";
import { afterEach, describe, expect, test } from "vitest";
import { blockquoteDepth, blockquoteDepthPlugin } from "./blockquote-depth";

describe("blockquoteDepth", () => {
	test("counts nesting from leading > markers", () => {
		expect(blockquoteDepth("> a")).toBe(1);
		expect(blockquoteDepth(">> b")).toBe(2);
		expect(blockquoteDepth("> > c")).toBe(2);
		expect(blockquoteDepth(">>> d")).toBe(3);
		expect(blockquoteDepth("  > indented")).toBe(1);
		expect(blockquoteDepth("plain")).toBe(0);
		expect(blockquoteDepth("a > b")).toBe(0);
	});
});

let view: EditorView;
afterEach(() => view?.destroy());

describe("blockquoteDepthPlugin", () => {
	test("is view-only and sets --bq-depth per quote line", () => {
		const doc = "> a\n>> b\nplain\n";
		view = new EditorView({
			state: EditorState.create({ doc, extensions: [blockquoteDepthPlugin] }),
			parent: document.body,
		});
		// view-only: the document text is never mutated by the decoration.
		expect(view.state.doc.toString()).toBe(doc);
		const lines = [...view.dom.querySelectorAll<HTMLElement>(".cm-line")];
		expect(lines[0]?.style.getPropertyValue("--bq-depth")).toBe("1");
		expect(lines[1]?.style.getPropertyValue("--bq-depth")).toBe("2");
		expect(lines[2]?.style.getPropertyValue("--bq-depth")).toBe("");
	});
});
