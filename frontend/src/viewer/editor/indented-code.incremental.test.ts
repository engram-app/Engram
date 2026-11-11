import { markdown, markdownLanguage } from "@codemirror/lang-markdown";
import { describe, expect, test } from "vitest";
import { indentedCodeLines, indentedCodeRenderer } from "./indented-code";
import { diffFromFresh, parsedState, settle, workDuring } from "./render-test-utils";

const ext = [markdown({ base: markdownLanguage }), indentedCodeLines];
const BLOCK = "para\n\n\tcode\n\tmore\n\n";

describe("indented code renders incrementally", () => {
	test("a keystroke in a long note re-renders only the block it is in", () => {
		const s = parsedState(BLOCK.repeat(1500), ext);
		let after = s;
		const mid = s.doc.line(3000).from;
		const work = workDuring(indentedCodeRenderer, () => {
			after = s.update({ changes: { from: mid, insert: "x" } }).state;
		});
		expect(s.doc.length).toBeGreaterThan(20_000);
		expect(work).toBeLessThan(100);
		expect(diffFromFresh(settle(after), ext, indentedCodeLines)).toEqual([]);
	});

	test("matches a fresh build after indenting, Enter on a code line, and un-indenting", () => {
		let s = parsedState(BLOCK.repeat(20), ext);
		const edits = [
			{ from: 0, insert: "\t" },
			{ from: s.doc.line(4).to, insert: "\n\t" },
			{ from: s.doc.line(9).from, to: s.doc.line(9).from + 1 },
			{ from: s.doc.line(20).from, to: s.doc.line(30).to },
		];
		for (const changes of edits) {
			s = settle(s.update({ changes }).state);
			expect(diffFromFresh(s, ext, indentedCodeLines)).toEqual([]);
		}
	});
});
