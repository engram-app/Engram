import { EditorState } from "@codemirror/state";
import { EditorView } from "@codemirror/view";
import { afterEach, describe, expect, test } from "vitest";
import { insertSnippet, toggleCheckbox, toggleLinePrefix, toggleWrap } from "./format-commands";

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

	// What the toolbar's wikilink button relies on: two insertions at the SAME
	// position, with the caret mapped between them rather than to either edge.
	test("toggleWrap on an empty selection leaves the caret between the markers", () => {
		mount("", 0, 0);
		toggleWrap(view, "[[", "]]");
		expect(view.state.doc.toString()).toBe("[[]]");
		expect(view.state.selection.main.head).toBe(2);
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
			insertSnippet(view, "| a |", { block: true });
			expect(view.state.doc.toString()).toBe("a\n| a |\nb");
		});

		test("takes the trailing remainder from the line the selection ENDS on", () => {
			// Regression: the tail used to be sliced out of the line holding `from`,
			// so a multi-line selection indexed past that line's end, got "", and
			// glued the remainder onto the snippet ("he\n| a |rld").
			mount("hello\nworld", 2, 8);
			insertSnippet(view, "| a |", { block: true });
			expect(view.state.doc.toString()).toBe("he\n| a |\nrld");
		});

		test("consumes the blank line it is dropped on instead of adding another", () => {
			// Caret on the empty line between two paragraphs: that line BECOMES the
			// snippet's line. Synthesizing breaks here would leave stray blank lines.
			mount("one\n\ntwo", 4, 4);
			insertSnippet(view, "| a |", { block: true });
			expect(view.state.doc.toString()).toBe("one\n| a |\ntwo");
		});

		test("keeps a blank line above a rule so it is not read as a setext heading", () => {
			// `a\n---` is an <h2>, not a divider: the paragraph above is swallowed and
			// the rule disappears. Every other block snippet may interrupt a paragraph.
			mount("ab", 1, 1);
			insertSnippet(view, "---", { block: true });
			expect(view.state.doc.toString()).toBe("a\n\n---\nb");
		});

		test("does not consume the blank line separating a rule from the text above", () => {
			mount("one\n\ntwo", 4, 4);
			insertSnippet(view, "---", { block: true });
			expect(view.state.doc.toString()).toBe("one\n\n---\ntwo");
		});

		test("adds no blank line above a rule at the very start of the document", () => {
			mount("", 0, 0);
			insertSnippet(view, "---", { block: true });
			expect(view.state.doc.toString()).toBe("---");
		});

		test("an inline snippet never gains line breaks, even mid-word", () => {
			mount("ab", 1, 1);
			insertSnippet(view, "`c`");
			expect(view.state.doc.toString()).toBe("a`c`b");
		});
	});

	// An insertion sitting exactly on the caret maps the caret BEFORE it by
	// default, so tapping the list button left the cursor to the left of the
	// "- " and you had to reach over and move it before typing.
	describe("caret lands after the inserted marker", () => {
		test("toggleLinePrefix puts the caret after a bullet on an empty line", () => {
			mount("", 0, 0);
			toggleLinePrefix(view, "- ");
			expect(view.state.doc.toString()).toBe("- ");
			expect(view.state.selection.main.head).toBe(2);
		});

		test("toggleLinePrefix keeps the caret in front of existing text, not the marker", () => {
			mount("item", 0, 0);
			toggleLinePrefix(view, "- ");
			expect(view.state.doc.toString()).toBe("- item");
			expect(view.state.selection.main.head).toBe(2);
		});

		test("toggleLinePrefix preserves a caret already inside the text", () => {
			mount("item", 2, 2); // between "it" and "em"
			toggleLinePrefix(view, "- ");
			expect(view.state.selection.main.head).toBe(4);
		});

		test("toggleCheckbox puts the caret after the box, not at the line start", () => {
			mount("buy milk", 0, 0);
			toggleCheckbox(view);
			expect(view.state.doc.toString()).toBe("- [ ] buy milk");
			expect(view.state.selection.main.head).toBe(6);
		});

		test("toggleCheckbox keeps the caret next to the same word when checking", () => {
			// Caret before "milk" in "- [ ] buy milk" → same spot once checked.
			mount("- [ ] buy milk", 10, 10);
			toggleCheckbox(view);
			expect(view.state.doc.toString()).toBe("- [x] buy milk");
			expect(view.state.selection.main.head).toBe(10);
		});
	});

	// Obsidian's "toggle checkbox status": plain text and bare bullets become an
	// unchecked task, and an existing task flips state rather than being removed.
	describe("toggleCheckbox", () => {
		test("turns a plain line into an unchecked task", () => {
			mount("buy milk", 0, 0);
			toggleCheckbox(view);
			expect(view.state.doc.toString()).toBe("- [ ] buy milk");
		});

		test("turns a bare bullet into an unchecked task without doubling the marker", () => {
			mount("- buy milk", 0, 0);
			toggleCheckbox(view);
			expect(view.state.doc.toString()).toBe("- [ ] buy milk");
		});

		test("checks an unchecked task", () => {
			mount("- [ ] buy milk", 0, 0);
			toggleCheckbox(view);
			expect(view.state.doc.toString()).toBe("- [x] buy milk");
		});

		test("unchecks a checked task rather than deleting it", () => {
			mount("- [x] buy milk", 0, 0);
			toggleCheckbox(view);
			expect(view.state.doc.toString()).toBe("- [ ] buy milk");
		});

		// Indentation carries list nesting; rewriting from column 0 would flatten
		// a sub-task into a top-level one.
		test("preserves leading indentation", () => {
			mount("\t\t- [ ] nested", 0, 0);
			toggleCheckbox(view);
			expect(view.state.doc.toString()).toBe("\t\t- [x] nested");
		});

		test("applies to every line the selection touches", () => {
			mount("one\ntwo", 0, 7);
			toggleCheckbox(view);
			expect(view.state.doc.toString()).toBe("- [ ] one\n- [ ] two");
		});

		// An uppercase X is valid task syntax and means done; treating it as
		// unrecognised would prepend a second checkbox.
		test("treats an uppercase X as checked", () => {
			mount("- [X] done", 0, 0);
			toggleCheckbox(view);
			expect(view.state.doc.toString()).toBe("- [ ] done");
		});

		test("leaves a blank line alone", () => {
			mount("", 0, 0);
			toggleCheckbox(view);
			expect(view.state.doc.toString()).toBe("");
		});
	});
});
