import { EditorState } from "@codemirror/state";
import { EditorView } from "@codemirror/view";
import { afterEach, describe, expect, test } from "vitest";
import { toggleLinePrefix, toggleWrap } from "./format-commands";

let view: EditorView;
afterEach(() => view?.destroy());

function mount(doc: string, from: number, to: number): EditorView {
	view = new EditorView({
		state: EditorState.create({ doc, selection: { anchor: from, head: to } }),
		parent: document.body,
	});
	return view;
}

describe("format-commands", () => {
	test("toggleWrap wraps the selection with markers", () => {
		mount("hello world", 0, 5); // "hello"
		toggleWrap(view, "**");
		expect(view.state.doc.toString()).toBe("**hello** world");
	});

	test("toggleLinePrefix adds a heading prefix to the caret line", () => {
		mount("title", 0, 0);
		toggleLinePrefix(view, "# ");
		expect(view.state.doc.toString()).toBe("# title");
	});

	test("toggleLinePrefix does not prefix a line the selection only touches at its start boundary", () => {
		mount("one\ntwo\nthree", 0, 8); // ends exactly at the start of "three"
		toggleLinePrefix(view, "# ");
		expect(view.state.doc.toString()).toBe("# one\n# two\nthree");
	});

	test("toggleLinePrefix is idempotent on an already-prefixed line", () => {
		mount("# already\nplain", 0, 0);
		toggleLinePrefix(view, "# ");
		expect(view.state.doc.toString()).toBe("# already\nplain");
	});
});
