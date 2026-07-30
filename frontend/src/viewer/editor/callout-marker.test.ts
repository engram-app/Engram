import { markdown, markdownLanguage } from "@codemirror/lang-markdown";
import { syntaxTree } from "@codemirror/language";
import { EditorState } from "@codemirror/state";
import { describe, expect, test } from "vitest";
import { calloutMarker } from "./callout-marker";

/** Node names in the parse tree of `doc`, in document order. */
function nodes(doc: string, withMarker = true): string[] {
	const state = EditorState.create({
		doc,
		extensions: [
			markdown({
				base: markdownLanguage,
				extensions: withMarker ? [calloutMarker] : [],
			}),
		],
	});
	const found: string[] = [];
	syntaxTree(state).iterate({
		enter: (n) => {
			found.push(n.name);
		},
	});
	return found;
}

describe("calloutMarker", () => {
	test("the bug it fixes is real: lezer parses [!type] as a Link without it", () => {
		// Not an assumption about CommonMark — the baseline is measured here so
		// that if lezer ever stops doing this, THIS test fails rather than the fix
		// quietly becoming dead weight.
		expect(nodes("> [!important] How this works", false)).toContain("Link");
	});

	test("claims the marker so no Link node is produced", () => {
		const found = nodes("> [!important] How this works");
		expect(found).toContain("CalloutMarker");
		expect(found).not.toContain("Link");
		// LinkMark is what Atomic replaces, which is why the brackets vanished
		// from a revealed callout header.
		expect(found).not.toContain("LinkMark");
	});

	test("covers the fold markers, which are part of the syntax", () => {
		for (const doc of ["> [!note]- Folded", "> [!note]+ Open"]) {
			expect(nodes(doc)).toContain("CalloutMarker");
		}
	});

	test("leaves a REAL link alone on a callout body line", () => {
		const found = nodes("> [!note] Title\n> see [the docs](https://example.com)");
		expect(found).toContain("CalloutMarker");
		expect(found).toContain("Link");
	});

	test("does not claim a bracket mid-line, where a link is what you meant", () => {
		// The marker is only a marker at the start of the blockquote's content.
		// `[!x]` further along is prose or a link, and Reading mode agrees.
		const found = nodes("> see [!important] here");
		expect(found).not.toContain("CalloutMarker");
	});

	test("ignores a bracket that is not a marker at all", () => {
		expect(nodes("> [not a callout] text")).not.toContain("CalloutMarker");
		expect(nodes("> [!] text")).not.toContain("CalloutMarker");
	});
});
