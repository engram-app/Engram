import { describe, expect, test } from "vitest";
import { blockquoteDepthPlugin, blockquoteRenderer } from "./blockquote-depth";
import { calloutDecoration, calloutRenderer } from "./callout-decoration";
import { diffFromFresh, parsedState, placed, workDuring } from "./render-test-utils";

const CALLOUT = "> [!tip] Title\n> body\n\npara\n\n";

describe("callouts render incrementally", () => {
	test("a keystroke in a long note rescans only around the edit", () => {
		const s = parsedState(CALLOUT.repeat(2000), [calloutDecoration], 0);
		let after = s;
		const at = s.doc.line(5001).from;
		const work = workDuring(calloutRenderer, () => {
			after = s.update({ changes: { from: at, insert: "x" } }).state;
		});
		expect(work).toBeLessThan(100);
		expect(diffFromFresh(after, [calloutDecoration], calloutDecoration)).toEqual([]);
	});

	test("typing a > line under a callout extends it", () => {
		let s = parsedState(`${CALLOUT}tail`, [calloutDecoration], CALLOUT.length + 4);
		s = s.update({ changes: { from: s.doc.line(2).to, insert: "\n> more" } }).state;
		expect(diffFromFresh(s, [calloutDecoration], calloutDecoration)).toEqual([]);
		// header + body + the new line carry the callout class
		expect(placed(s.field(calloutDecoration)).filter(([f, t]) => f === t)).toHaveLength(3);
	});

	test("moving the caret in and out re-decorates only that block, and matches a fresh build", () => {
		let s = parsedState(CALLOUT.repeat(50), [calloutDecoration], s0());
		const far = placed(s.field(calloutDecoration)).at(-1);
		s = s.update({ selection: { anchor: 3 } }).state;
		expect(diffFromFresh(s, [calloutDecoration], calloutDecoration)).toEqual([]);
		// A block nowhere near the caret keeps its decoration object.
		expect(placed(s.field(calloutDecoration)).at(-1)?.[2]).toBe(far?.[2]);
		s = s.update({ selection: { anchor: s.doc.length } }).state;
		expect(diffFromFresh(s, [calloutDecoration], calloutDecoration)).toEqual([]);
	});
});

function s0() {
	return CALLOUT.length * 25 + 2;
}

describe("blockquote depth renders incrementally", () => {
	test("a keystroke rescans one line, and nesting edits match a fresh build", () => {
		let s = parsedState("> a\n>> b\n\n".repeat(3000), [blockquoteDepthPlugin]);
		let after = s;
		const work = workDuring(blockquoteRenderer, () => {
			after = s.update({ changes: { from: s.doc.line(4000).from, insert: ">" } }).state;
		});
		expect(work).toBeLessThan(50);
		expect(diffFromFresh(after, [blockquoteDepthPlugin], blockquoteDepthPlugin)).toEqual([]);
		s = after.update({ changes: { from: 0, to: 1 } }).state;
		expect(diffFromFresh(s, [blockquoteDepthPlugin], blockquoteDepthPlugin)).toEqual([]);
	});
});
