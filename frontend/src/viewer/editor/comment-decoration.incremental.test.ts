import { markdown, markdownLanguage } from "@codemirror/lang-markdown";
import { describe, expect, test } from "vitest";
import { commentDecoration, commentRenderer } from "./comment-decoration";
import { diffFromFresh, parsedState, placed, settle, workDuring } from "./render-test-utils";

const ext = [markdown({ base: markdownLanguage }), commentDecoration];
const PARA = "text %%c%% more\n\n";

describe("comments render incrementally", () => {
	test("a keystroke in a long note rescans only around the edit", () => {
		const s = parsedState(PARA.repeat(3000), ext);
		let after = s;
		const mid = s.doc.line(3001).from;
		const work = workDuring(commentRenderer, () => {
			after = s.update({ changes: { from: mid, insert: "x" } }).state;
		});
		expect(work).toBeLessThan(200);
		expect(diffFromFresh(settle(after), ext, commentDecoration)).toEqual([]);
	});

	test("opening a %% at the top greys everything below it, closing it restores the rest", () => {
		let s = parsedState(`top\n\n${PARA.repeat(200)}`, ext);
		s = settle(s.update({ changes: { from: 0, insert: "%%" } }).state);
		expect(diffFromFresh(s, ext, commentDecoration)).toEqual([]);
		// Every %% below now pairs differently.
		expect(placed(s.field(commentDecoration))[0]?.[0]).toBe(0);
		s = settle(s.update({ changes: { from: 2, insert: "x%%" } }).state);
		expect(diffFromFresh(s, ext, commentDecoration)).toEqual([]);
		s = settle(s.update({ changes: { from: 0, to: 5 } }).state);
		expect(diffFromFresh(s, ext, commentDecoration)).toEqual([]);
	});

	test("opening a code fence turns the comments below into code, closing it brings them back", () => {
		let s = parsedState(PARA.repeat(100), ext);
		s = settle(s.update({ changes: { from: 0, insert: "```\n" } }).state);
		expect(diffFromFresh(s, ext, commentDecoration)).toEqual([]);
		expect(placed(s.field(commentDecoration))).toEqual([]);
		s = settle(s.update({ changes: { from: s.doc.line(50).from, insert: "```\n" } }).state);
		expect(diffFromFresh(s, ext, commentDecoration)).toEqual([]);
	});

	test("edge cases: empty doc, edits at the very start and end", () => {
		let s = parsedState("", ext);
		expect(placed(s.field(commentDecoration))).toEqual([]);
		s = settle(s.update({ changes: { from: 0, insert: "%%a%%" } }).state);
		expect(diffFromFresh(s, ext, commentDecoration)).toEqual([]);
		s = settle(s.update({ changes: { from: s.doc.length, insert: " %%" } }).state);
		expect(diffFromFresh(s, ext, commentDecoration)).toEqual([]);
	});
});
