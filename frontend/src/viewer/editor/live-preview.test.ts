import { EditorState } from "@codemirror/state";
import { EditorView } from "@codemirror/view";
import { afterEach, describe, expect, test } from "vitest";
import { livePreviewExtensions } from "./live-preview";

const MD = "# Heading\n\n**bold** and *italic* and [[Wiki Link]]\n";

let view: EditorView;
afterEach(() => view?.destroy());

// before\n  0..6 | \n 7 | > [!note] Title\n 8..23 | > body line\n 24..35 | \n 36 | after\n 37..42
const CALLOUT_DOC = "before\n\n> [!note] Title\n> body line\n\nafter\n";

/** Text of the callout's header line as actually rendered. */
function headerLineText(): string | null {
	return [...view.dom.querySelectorAll(".cm-line")][2]?.textContent ?? null;
}

function mountCallout(anchor: number): EditorView {
	view = new EditorView({
		state: EditorState.create({
			doc: CALLOUT_DOC,
			selection: { anchor },
			extensions: livePreviewExtensions({
				resolveWikiLink: (n) => `/w/wiki/${n}`,
				openWikiLink: () => {},
			}),
		}),
		parent: document.body,
	});
	return view;
}

describe("livePreviewExtensions", () => {
	test("is view-only: decorations never change the document text", () => {
		const ext = livePreviewExtensions({
			resolveWikiLink: (n) => `/w/wiki/${n}`,
			openWikiLink: () => {},
		});
		const state = EditorState.create({ doc: MD, extensions: ext });
		// Building state + reading facets must not alter doc bytes.
		expect(state.doc.toString()).toBe(MD);
	});

	test("does not throw when composed with markdown language", () => {
		const ext = livePreviewExtensions({
			resolveWikiLink: (n) => `/w/wiki/${n}`,
			openWikiLink: () => {},
		});
		expect(() => EditorState.create({ doc: MD, extensions: ext })).not.toThrow();
	});

	// The callout title is a replace decoration over the SAME line inlinePreview
	// decorates for its QuoteMark. At equal precedence Atomic's replace won and
	// ours was dropped — but only on rebuilds after the first, so a callout
	// rendered correctly until you put the caret in it, and arrowing back out
	// left the header line completely blank. The widget was in the decoration set
	// throughout; it lost the overlap. Hence Prec.highest in live-preview.ts.
	//
	// These assert through the FULL extension stack on purpose: calloutDecoration
	// alone was always symmetric, which is exactly why the bug survived its own
	// unit tests.
	test.each([
		["out the bottom", [12, 30, 36, 37]],
		["out the top", [30, 12, 7, 0]],
		["in, out, back in, out again", [0, 12, 0, 30, 37]],
	])("keeps the callout title rendered when the caret leaves %s", (_label, steps) => {
		mountCallout(steps[0] as number);
		for (const pos of steps.slice(1)) {
			view.dispatch({ selection: { anchor: pos } });
		}
		// Ends outside the block every time, so the rendered title must be back.
		expect(headerLineText()).toBe("Title");
	});

	test("still reveals the raw header while the caret is inside the callout", () => {
		// The other half of the contract: Prec.highest must not pin the widget on
		// permanently, or the block would become uneditable.
		mountCallout(0);
		expect(headerLineText()).toBe("Title");
		view.dispatch({ selection: { anchor: 12 } });
		expect(headerLineText()).not.toBe("Title");
		expect(headerLineText()).toContain("note");
	});
});
