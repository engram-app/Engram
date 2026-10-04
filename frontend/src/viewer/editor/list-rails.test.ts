import { markdown, markdownLanguage } from "@codemirror/lang-markdown";
import { EditorState } from "@codemirror/state";
import { EditorView } from "@codemirror/view";
import { afterEach, expect, test } from "vitest";
import { listRails } from "./list-rails";

let view: EditorView;
afterEach(() => view?.destroy());

function rails(doc: string): (string | null)[] {
	view = new EditorView({
		state: EditorState.create({
			doc,
			selection: { anchor: 0 },
			extensions: [markdown({ base: markdownLanguage }), listRails],
		}),
		parent: document.body,
	});
	return [...view.dom.querySelectorAll<HTMLElement>(".cm-line")].map((l) =>
		l.classList.contains("cm-list-rails") ? l.style.getPropertyValue("--rails") : null,
	);
}

test("each nesting level above the first adds a rail", () => {
	expect(rails("- a\n\t- b\n\t\t- c\n- d")).toEqual([null, "1", "2", null]);
});

test("a top-level list and plain text have none", () => {
	expect(rails("- a\n- b\n\ntext")).toEqual([null, null, null, null]);
});

test("a continuation paragraph, and the blank line before it, carry their item's rails", () => {
	expect(rails("- a\n\t- b\n\n\t  more of b")).toEqual([null, "1", "1", "1"]);
});

test("is view-only", () => {
	const doc = "- a\n\t- b";
	rails(doc);
	expect(view.state.doc.toString()).toBe(doc);
});

test("a rail under an ordered item sits left of one under a bullet (the number box is narrower)", () => {
	const x = (doc: string) => {
		rails(doc);
		const [, line] = view.dom.querySelectorAll<HTMLElement>(".cm-line");
		return line?.style.backgroundPosition ?? "";
	};
	const ul = x("- a\n\t- b");
	const ol = x("1. a\n\t1. b");
	expect(ul).toContain("1.4em");
	expect(ol).toContain("1.15em");
});
