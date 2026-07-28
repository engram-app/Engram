import { EditorState } from "@codemirror/state";
import { EditorView } from "@codemirror/view";
import { afterEach, describe, expect, test } from "vitest";
import { insertSnippet, toggleLinePrefix, toggleWrap } from "./format-commands";

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

	describe("insertSnippet", () => {
		test("inserts an inline snippet at the caret", () => {
			mount("ab", 1, 1);
			insertSnippet(view, "**x**");
			expect(view.state.doc.toString()).toBe("a**x**b");
		});

		test("leaves the caret after the inserted snippet, ready to keep typing", () => {
			mount("ab", 1, 1);
			insertSnippet(view, "**x**");
			expect(view.state.selection.main.head).toBe(1 + "**x**".length);
			expect(view.state.selection.main.empty).toBe(true);
		});

		test("replaces the selection rather than inserting alongside it", () => {
			mount("hello", 0, 5);
			insertSnippet(view, "`code`");
			expect(view.state.doc.toString()).toBe("`code`");
		});

		test("inserts a block snippet as-is when the caret is already on an empty line", () => {
			mount("", 0, 0);
			insertSnippet(view, "> [!note]\n> body", { block: true });
			expect(view.state.doc.toString()).toBe("> [!note]\n> body");
		});

		test("breaks a block snippet onto its own line when text precedes the caret", () => {
			mount("text", 4, 4);
			insertSnippet(view, "| a |", { block: true });
			expect(view.state.doc.toString()).toBe("text\n| a |");
		});

		test("also breaks the trailing remainder onto its own line", () => {
			mount("ab", 1, 1);
			insertSnippet(view, "---", { block: true });
			expect(view.state.doc.toString()).toBe("a\n---\nb");
		});

		test("consumes the blank line it is dropped on instead of adding another", () => {
			// Caret on the empty line between two paragraphs: that line BECOMES the
			// snippet's line. Synthesizing breaks here would leave stray blank lines.
			mount("one\n\ntwo", 4, 4);
			insertSnippet(view, "---", { block: true });
			expect(view.state.doc.toString()).toBe("one\n---\ntwo");
		});

		test("an inline snippet never gains line breaks, even mid-word", () => {
			mount("ab", 1, 1);
			insertSnippet(view, "`c`");
			expect(view.state.doc.toString()).toBe("a`c`b");
		});
	});
});
