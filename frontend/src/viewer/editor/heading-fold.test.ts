import { foldable, forceParsing } from "@codemirror/language";
import { EditorView } from "@codemirror/view";
import { markdown, markdownLanguage } from "@codemirror/lang-markdown";
import { EditorState } from "@codemirror/state";
import { afterEach, describe, expect, it } from "vitest";
import { noParagraphFold } from "./heading-fold";

const DOC = `# Title

intro line

## Section A

alpha one
alpha two

## Section B

beta one
`;

// A real view, not a bare EditorState. CodeMirror parses lazily up to the
// viewport, and a state on its own has no viewport — so `foldable` saw only the
// first heading. `ensureSyntaxTree` does NOT fix it: it returns a tree without
// writing it back to the state, so `syntaxTree(state)` (what `foldable` reads)
// stays partial. `forceParsing` on a mounted view updates the state field.
//
// Symptom if this regresses: passes run alone, fails in the full suite, and
// only the later headings are missing.
const views: EditorView[] = [];

afterEach(() => {
	for (const v of views.splice(0)) {
		v.destroy();
	}
});

function stateFor(extensions: Parameters<typeof markdown>[0]) {
	const view = new EditorView({
		state: EditorState.create({ doc: DOC, extensions: [markdown(extensions)] }),
	});
	views.push(view);
	forceParsing(view, view.state.doc.length, 1e9);
	return view.state;
}

function foldRanges(extensions: Parameters<typeof markdown>[0]) {
	const state = stateFor(extensions);
	const out: { text: string; foldable: boolean }[] = [];
	for (let n = 1; n <= state.doc.lines; n++) {
		const line = state.doc.line(n);
		out.push({ text: line.text, foldable: foldable(state, line.from, line.to) !== null });
	}
	return out;
}

const foldableLines = (rows: ReturnType<typeof foldRanges>) =>
	rows.filter((r) => r.foldable).map((r) => r.text);

describe("heading folding", () => {
	// The fold LOGIC is lang-markdown's `headerIndent` foldService, not ours —
	// pinned here because our UI is useless if a dep bump drops it.
	it("makes every heading foldable", () => {
		expect(
			foldableLines(foldRanges({ base: markdownLanguage, extensions: noParagraphFold })),
		).toEqual(["# Title", "## Section A", "## Section B"]);
	});

	it("folds a heading's whole section, not just its line", () => {
		const state = stateFor({ base: markdownLanguage, extensions: noParagraphFold });
		const heading = state.doc.line(5); // "## Section A"
		const range = foldable(state, heading.from, heading.to);

		expect(range).not.toBeNull();
		// Starts after the heading text (the heading stays visible) and covers
		// the body through to the next heading of the same or higher level.
		expect(range?.from).toBe(heading.to);
		expect(state.doc.sliceString(range?.from ?? 0, range?.to ?? 0)).toContain("alpha two");
		expect(state.doc.sliceString(range?.from ?? 0, range?.to ?? 0)).not.toContain("Section B");
	});

	// Without noParagraphFold, lang-markdown's foldNodeProp marks any non-heading
	// Block foldable — so a two-line paragraph grew its own arrow. Obsidian never
	// folds a paragraph, and a chevron beside every wrapped one is hover noise.
	it("leaves paragraphs alone", () => {
		const withFix = foldableLines(
			foldRanges({ base: markdownLanguage, extensions: noParagraphFold }),
		);
		const without = foldableLines(foldRanges({ base: markdownLanguage }));

		expect(withFix).not.toContain("alpha one");
		expect(without).toContain("alpha one");
	});
});
