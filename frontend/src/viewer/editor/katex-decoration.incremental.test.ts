import { describe, expect, test } from "vitest";
import { katexDecoration, katexRenderer } from "./katex-decoration";
import { diffFromFresh, parsedState, placed, workDuring } from "./render-test-utils";

const ext = [katexDecoration];
const PARA = "costs $5 and $x^2$ here\n\n$$\na+b\n$$\n\n";
const diff = (s: Parameters<typeof diffFromFresh>[0]) => diffFromFresh(s, ext, katexDecoration);

describe("math renders incrementally", () => {
	test("a keystroke in a long note rescans only around the edit; far widgets keep identity", () => {
		const s = parsedState(PARA.repeat(1500), ext);
		const first = placed(s.field(katexDecoration)).at(0);
		let after = s;
		const at = s.doc.line(6001).from;
		const work = workDuring(katexRenderer, () => {
			after = s.update({ changes: { from: at, insert: "x" } }).state;
		});
		expect(work).toBeLessThan(200);
		expect(placed(after.field(katexDecoration)).at(0)?.[2]).toBe(first?.[2]);
		expect(diff(after)).toEqual([]);
	});

	test("opening and closing a $$ that pairs off-screen matches a fresh build", () => {
		let s = parsedState(`top\n\n${PARA.repeat(300)}`, ext);
		for (const changes of [
			{ from: 0, insert: "$$" },
			{ from: 2, insert: "y$$" },
			{ from: 0, to: 5 },
			{ from: s.doc.length, insert: "\n$$ open" },
		]) {
			s = s.update({ changes }).state;
			expect(diff(s)).toEqual([]);
		}
	});

	test("reveal follows the caret and matches a fresh build", () => {
		let s = parsedState(PARA.repeat(20), ext);
		for (const anchor of [15, 30, PARA.length + 4, 0, s.doc.length]) {
			s = s.update({ selection: { anchor } }).state;
			expect(diff(s)).toEqual([]);
		}
	});

	test("edge cases: empty doc, edits at the very start and end", () => {
		let s = parsedState("", ext);
		expect(placed(s.field(katexDecoration))).toEqual([]);
		for (const changes of [
			{ from: 0, insert: "$a$" },
			{ from: 3, insert: " $$b$$" },
			{ from: 0, to: 1 },
		]) {
			s = s.update({ changes, selection: { anchor: 0 } }).state;
			expect(diff(s)).toEqual([]);
		}
	});

	test("display math typed top to bottom, one key at a time, renders", () => {
		let s = parsedState("intro\n\n", ext, 7);
		for (const ch of "$$\nx^2\n$$\n\nafter") {
			const at = s.selection.main.head;
			s = s.update({ changes: { from: at, insert: ch }, selection: { anchor: at + 1 } }).state;
		}
		s = s.update({ selection: { anchor: 0 } }).state;
		expect(diff(s)).toEqual([]);
		expect(placed(s.field(katexDecoration)).map(([f, t]) => [f, t])).toEqual([[7, 16]]);
	});

	test("a keystroke below an unpaired $$ keeps the next inline math", () => {
		let s = parsedState("$$ lone\nmid\nmid\nline $y$\n", ext, 0);
		s = s.update({ changes: { from: 9, insert: "x" } }).state;
		expect(diff(s)).toEqual([]);
	});
});
