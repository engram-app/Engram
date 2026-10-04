import { markdown, markdownLanguage } from "@codemirror/lang-markdown";
import { EditorState } from "@codemirror/state";
import { EditorView } from "@codemirror/view";
import { afterEach, expect, test } from "vitest";
import { indentedCodeLines } from "./indented-code";

let view: EditorView;
afterEach(() => view?.destroy());

function lineClasses(doc: string): string[][] {
	view = new EditorView({
		state: EditorState.create({
			doc,
			selection: { anchor: 0 },
			extensions: [markdown({ base: markdownLanguage }), indentedCodeLines],
		}),
		parent: document.body,
	});
	return [...view.dom.querySelectorAll(".cm-line")].map((l) => [...l.classList]);
}

test("a tab-indented paragraph is drawn like a fenced code block, so a stray Tab is visible", () => {
	const lines = lineClasses("para\n\n\tcode here\n\tmore code\n\nafter");
	expect(lines[2]).toContain("cm-atomic-fenced-code");
	expect(lines[3]).toContain("cm-atomic-fenced-code");
	expect(lines[0]).not.toContain("cm-atomic-fenced-code");
	expect(lines[5]).not.toContain("cm-atomic-fenced-code");
});

test("an indented continuation inside a list item is NOT code", () => {
	const lines = lineClasses("- item\n\n\tcontinued paragraph\n");
	expect(lines[2]).not.toContain("cm-atomic-fenced-code");
});

test("is view-only", () => {
	const doc = "a\n\n\tb\n";
	lineClasses(doc);
	expect(view.state.doc.toString()).toBe(doc);
});

test("Enter on an indented line leaves an indent-only line that stays styled", () => {
	const lines = lineClasses("para\n\n\tcode\n\t\nafter");
	expect(lines[2]).toContain("cm-atomic-fenced-code");
	expect(lines[3]).toContain("cm-atomic-fenced-code");
	expect(lines[4]).not.toContain("cm-atomic-fenced-code");
});

test("a truly empty line after the block is not part of it", () => {
	const lines = lineClasses("para\n\n\tcode\n\nafter");
	expect(lines[3]).not.toContain("cm-atomic-fenced-code");
});
