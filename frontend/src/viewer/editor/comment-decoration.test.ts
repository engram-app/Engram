import { markdown, markdownLanguage } from "@codemirror/lang-markdown";
import { EditorState } from "@codemirror/state";
import { EditorView } from "@codemirror/view";
import { afterEach, describe, expect, test } from "vitest";
import { commentDecoration } from "./comment-decoration";

// Comments (`%%…%%` and `<!-- -->`) stay visible while editing, greyed like
// Obsidian's editing view; the reading view hides them.

let view: EditorView;
afterEach(() => view?.destroy());

function mount(doc: string) {
	view = new EditorView({
		state: EditorState.create({
			doc,
			extensions: [markdown({ base: markdownLanguage }), commentDecoration],
		}),
		parent: document.body,
	});
}

const marked = () =>
	Array.from(view.dom.querySelectorAll(".cm-comment"), (e) => e.textContent).join("");

describe("commentDecoration", () => {
	test("greys an inline %% comment, markers included", () => {
		mount("an %%inline%% note\n");
		expect(marked()).toBe("%%inline%%");
	});

	test("greys an HTML comment", () => {
		mount("a <!-- hidden --> b\n");
		expect(marked()).toBe("<!-- hidden -->");
	});

	test("greys a multi-line block across its lines", () => {
		mount("before\n\n%%\nblock\ncomment\n%%\n\nafter\n");
		// One mark per line it covers (a mark never contains a line break).
		expect(view.dom.querySelectorAll(".cm-comment").length).toBeGreaterThanOrEqual(4);
		expect(marked()).toBe("%%blockcomment%%");
	});

	test("does not touch the text around a comment", () => {
		mount("keep %%x%% keep\n");
		expect(marked()).toBe("%%x%%");
	});

	test("leaves code alone", () => {
		mount("```\n%%x%%\n```\n`%%y%%`\n");
		expect(view.dom.querySelector(".cm-comment")).toBeNull();
	});

	test("is view-only: the document is unchanged", () => {
		const doc = "a %%x%% b <!-- y -->\n";
		mount(doc);
		expect(view.state.doc.toString()).toBe(doc);
	});

	test("follows edits: a comment typed later is greyed", () => {
		mount("hello\n");
		view.dispatch({ changes: { from: 5, insert: " %%later%%" } });
		expect(marked()).toBe("%%later%%");
	});
});
