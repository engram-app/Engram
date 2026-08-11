import { markdown, markdownLanguage } from "@codemirror/lang-markdown";
import { EditorState } from "@codemirror/state";
import { EditorView } from "@codemirror/view";
import { afterEach, describe, expect, test } from "vitest";
import {
	insertLink,
	insertSnippet,
	setHeading,
	toggleCheckbox,
	toggleCode,
	toggleLinePrefix,
	toggleList,
	toggleQuote,
	toggleWrap,
} from "./format-commands";

let view: EditorView;
afterEach(() => view?.destroy());

// The real editor loads the markdown grammar, and toggleWrap now asks the
// parser whether the selection is already emphasised -- string matching cannot
// tell `*` from the inner half of `**`. Mounting a bare view here would leave
// the tree empty and silently exercise only the wrap half.
function mount(doc: string, from: number, to: number): EditorView {
	view = new EditorView({
		state: EditorState.create({
			doc,
			selection: { anchor: from, head: to },
			extensions: [markdown({ base: markdownLanguage })],
		}),
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

	// Tapping the bold button twice has to undo it — otherwise the second tap
	// produces "****hello****", which is what a wrap-only command does.
	describe("toggleWrap unwraps what it wrapped", () => {
		test("strips the markers when the selection is already wrapped", () => {
			mount("**hello**", 2, 7);
			toggleWrap(view, "**");
			expect(view.state.doc.toString()).toBe("hello");
		});

		test("keeps the same text selected after unwrapping", () => {
			mount("**hello**", 2, 7);
			toggleWrap(view, "**");
			expect(
				view.state.sliceDoc(view.state.selection.main.from, view.state.selection.main.to),
			).toBe("hello");
		});

		test("collapses an empty pair the caret sits inside", () => {
			mount("****", 2, 2);
			toggleWrap(view, "**");
			expect(view.state.doc.toString()).toBe("");
		});

		// `*` is a prefix of `**`, so a naive check sees bold text as italic and
		// "italicising" it would silently downgrade it to plain italic.
		test("nests italic inside bold rather than downgrading it", () => {
			mount("**bold**", 2, 6);
			toggleWrap(view, "*");
			expect(view.state.doc.toString()).toBe("***bold***");
		});

		test("still unwraps bold when the run is exactly the marker", () => {
			mount("**bold**", 2, 6);
			toggleWrap(view, "**");
			expect(view.state.doc.toString()).toBe("bold");
		});

		// The other direction, which a rule patched only to protect the case above
		// gets wrong: un-bolding bold-italic has to leave the italic behind.
		test("un-bolds bold-italic down to italic", () => {
			mount("***both***", 3, 7);
			toggleWrap(view, "**");
			expect(view.state.doc.toString()).toBe("*both*");
		});

		test("un-italicises bold-italic down to bold", () => {
			mount("***both***", 3, 7);
			toggleWrap(view, "*");
			expect(view.state.doc.toString()).toBe("**both**");
		});

		// Obsidian toggles off from anywhere inside the emphasis, not just when
		// the whole span is selected.
		test("unwraps from a caret sitting inside the emphasis", () => {
			mount("**bold**", 4, 4);
			toggleWrap(view, "**");
			expect(view.state.doc.toString()).toBe("bold");
		});

		test("leaves an unmatched leading marker alone", () => {
			mount("**hello", 2, 7);
			toggleWrap(view, "**");
			expect(view.state.doc.toString()).toBe("****hello**");
		});
	});

	// What the toolbar's wikilink button relies on: two insertions at the SAME
	// position, with the caret mapped between them rather than to either edge.
	test("toggleWrap on an empty selection leaves the caret between the markers", () => {
		mount("", 0, 0);
		toggleWrap(view, "[[", "]]");
		expect(view.state.doc.toString()).toBe("[[]]");
		expect(view.state.selection.main.head).toBe(2);
	});

	// Asymmetric markers have no syntax node to look up, but the empty-pair check
	// still applies to them — without it a second tap gave "[[[[]]]]".
	test("toggleWrap collapses an empty asymmetric pair too", () => {
		mount("", 0, 0);
		toggleWrap(view, "[[", "]]");
		toggleWrap(view, "[[", "]]");
		expect(view.state.doc.toString()).toBe("");
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

	// The heading picker SETS a level rather than prepending, so tapping H3 on an
	// H1 line has to replace the marker — toggleLinePrefix would have produced
	// "### # title", since "# title" does not start with "### ".
	describe("setHeading", () => {
		test("turns a plain line into a heading", () => {
			mount("title", 0, 0);
			setHeading(view, 1);
			expect(view.state.doc.toString()).toBe("# title");
		});

		test("replaces an existing heading marker rather than stacking one", () => {
			mount("# title", 0, 0);
			setHeading(view, 3);
			expect(view.state.doc.toString()).toBe("### title");
		});

		test("demotes a deeper heading back up", () => {
			mount("###### deep", 0, 0);
			setHeading(view, 2);
			expect(view.state.doc.toString()).toBe("## deep");
		});

		// No seventh "Normal text" button: tapping the level a line already has is
		// the way back to plain text, matching the bar's other toggles.
		test("removes the heading when the line is already at that level", () => {
			mount("## title", 0, 0);
			setHeading(view, 2);
			expect(view.state.doc.toString()).toBe("title");
		});

		test("applies to every line the selection touches", () => {
			mount("one\ntwo", 0, 7);
			setHeading(view, 2);
			expect(view.state.doc.toString()).toBe("## one\n## two");
		});

		// Tapping H1 on an empty line then typing is how you start a section, so
		// unlike toggleCheckbox this does NOT skip blank lines.
		test("marks an empty line so the next keystroke lands in the heading", () => {
			mount("", 0, 0);
			setHeading(view, 1);
			expect(view.state.doc.toString()).toBe("# ");
			expect(view.state.selection.main.head).toBe(2);
		});

		// "## " on a blank line renders as an empty heading, and a blank line is
		// what separates the paragraphs you just selected. toggleList already
		// skips them; this has to as well.
		test("skips blank lines inside a multi-line selection", () => {
			mount("one\n\ntwo", 0, 8);
			setHeading(view, 2);
			expect(view.state.doc.toString()).toBe("## one\n\n## two");
		});

		test("keeps the caret next to the same word when changing level", () => {
			// Caret before "title" in "# title" -> still before it once H3.
			mount("# title", 2, 2);
			setHeading(view, 3);
			expect(view.state.doc.toString()).toBe("### title");
			expect(view.state.selection.main.head).toBe(4);
		});

		// `#foo` with no space is not a heading in CommonMark, so it is content.
		test("does not treat a spaceless hash run as an existing marker", () => {
			mount("#tag", 0, 0);
			setHeading(view, 1);
			expect(view.state.doc.toString()).toBe("# #tag");
		});
	});

	describe("toggleCode", () => {
		test("wraps a word in backticks", () => {
			mount("thing", 0, 5);
			toggleCode(view);
			expect(view.state.doc.toString()).toBe("`thing`");
		});

		// Same trap as bold: a wrap-only command doubles to ``thing`` on tap two.
		test("unwraps on a second tap", () => {
			mount("`thing`", 1, 6);
			toggleCode(view);
			expect(view.state.doc.toString()).toBe("thing");
		});

		// Inline backticks cannot span lines in CommonMark -- `a\nb` is literal
		// text, not code -- so a multi-line selection has to become a fence.
		test("fences a selection that spans lines", () => {
			mount("one\ntwo", 0, 7);
			toggleCode(view);
			expect(view.state.doc.toString()).toBe("```\none\ntwo\n```");
		});

		// A fence only opens a code block when it STARTS a line, so fencing the
		// raw selection produced "text ```" — markdown that renders as prose.
		// Like every other block command here, it works on whole lines.
		test("fences whole lines when the selection starts mid-line", () => {
			mount("text one\ntwo", 5, 12);
			toggleCode(view);
			expect(view.state.doc.toString()).toBe("```\ntext one\ntwo\n```");
		});

		test("fences whole lines when the selection ends mid-line", () => {
			mount("one\ntwo tail", 0, 7);
			toggleCode(view);
			expect(view.state.doc.toString()).toBe("```\none\ntwo tail\n```");
		});

		test("selects the fenced body so it can be replaced or indented", () => {
			mount("one\ntwo", 0, 7);
			toggleCode(view);
			const { from, to } = view.state.selection.main;
			expect(view.state.sliceDoc(from, to)).toBe("one\ntwo");
		});

		test("leaves the caret inside an empty inline pair", () => {
			mount("", 0, 0);
			toggleCode(view);
			expect(view.state.doc.toString()).toBe("``");
			expect(view.state.selection.main.head).toBe(1);
		});
	});

	describe("toggleQuote", () => {
		test("quotes the caret line", () => {
			mount("said", 0, 0);
			toggleQuote(view);
			expect(view.state.doc.toString()).toBe("> said");
		});

		test("quotes every line the selection touches", () => {
			mount("one\ntwo", 0, 7);
			toggleQuote(view);
			expect(view.state.doc.toString()).toBe("> one\n> two");
		});

		test("unquotes on a second tap", () => {
			mount("> one\n> two", 0, 11);
			toggleQuote(view);
			expect(view.state.doc.toString()).toBe("one\ntwo");
		});

		test("quotes a mixed selection rather than clearing it", () => {
			mount("> one\ntwo", 0, 9);
			toggleQuote(view);
			expect(view.state.doc.toString()).toBe("> > one\n> two");
		});

		// `>text` with no space is still a quote to CommonMark, so removing only
		// `"> "` would leave a stray marker behind.
		test("removes a spaceless marker too", () => {
			mount(">one", 0, 0);
			toggleQuote(view);
			expect(view.state.doc.toString()).toBe("one");
		});

		// Indentation carries nesting; unquoting is not the same as outdenting.
		test("keeps leading indentation when unquoting", () => {
			mount("\t> nested", 0, 0);
			toggleQuote(view);
			expect(view.state.doc.toString()).toBe("\tnested");
		});
	});

	describe("insertLink", () => {
		// The URL is the part you cannot guess, so that is where the caret goes.
		test("wraps the selection and lands the caret in the URL slot", () => {
			mount("engram", 0, 6);
			insertLink(view);
			expect(view.state.doc.toString()).toBe("[engram]()");
			expect(view.state.selection.main.head).toBe(9);
		});

		// Nothing selected means there is no link text yet, so start there instead.
		test("lands the caret in the text slot when nothing is selected", () => {
			mount("", 0, 0);
			insertLink(view);
			expect(view.state.doc.toString()).toBe("[]()");
			expect(view.state.selection.main.head).toBe(1);
		});

		test("inserts at the caret without eating the surrounding text", () => {
			mount("ab", 1, 1);
			insertLink(view);
			expect(view.state.doc.toString()).toBe("a[]()b");
		});
	});

	// One command for both list kinds, because they have to compose: prefixing a
	// numbered line with "- " would produce "- 1. foo", so each has to be able to
	// REPLACE the other's marker rather than stack on it.
	describe("toggleList", () => {
		test("numbers the caret line", () => {
			mount("thing", 0, 0);
			toggleList(view, true);
			expect(view.state.doc.toString()).toBe("1. thing");
		});

		test("numbers a selection sequentially, not all as 1.", () => {
			mount("one\ntwo\nthree", 0, 13);
			toggleList(view, true);
			expect(view.state.doc.toString()).toBe("1. one\n2. two\n3. three");
		});

		test("removes the numbers on a second tap", () => {
			mount("1. one\n2. two", 0, 13);
			toggleList(view, true);
			expect(view.state.doc.toString()).toBe("one\ntwo");
		});

		test("switches a bullet list to a numbered one", () => {
			mount("- one\n- two", 0, 11);
			toggleList(view, true);
			expect(view.state.doc.toString()).toBe("1. one\n2. two");
		});

		test("switches a numbered list back to bullets", () => {
			mount("1. one\n2. two", 0, 13);
			toggleList(view, false);
			expect(view.state.doc.toString()).toBe("- one\n- two");
		});

		test("preserves indentation so nesting survives", () => {
			mount("\t\tnested", 0, 0);
			toggleList(view, true);
			expect(view.state.doc.toString()).toBe("\t\t1. nested");
		});

		test("marks a lone empty line so the next keystroke lands in the item", () => {
			mount("", 0, 0);
			toggleList(view, true);
			expect(view.state.doc.toString()).toBe("1. ");
			expect(view.state.selection.main.head).toBe(3);
		});

		// A blank line ends a list in markdown, so numbering one mid-selection
		// would split the list AND consume an ordinal.
		test("skips blank lines inside a multi-line selection", () => {
			mount("one\n\ntwo", 0, 8);
			toggleList(view, true);
			expect(view.state.doc.toString()).toBe("1. one\n\n2. two");
		});

		test("re-numbers only when every selected line is already that kind", () => {
			mount("1. one\nplain", 0, 12);
			toggleList(view, true);
			expect(view.state.doc.toString()).toBe("1. one\n2. plain");
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
