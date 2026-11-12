import { markdown, markdownLanguage } from "@codemirror/lang-markdown";
import type { StateField } from "@codemirror/state";
import type { DecorationSet } from "@codemirror/view";
import { describe, expect, test } from "vitest";
import { listRails, listRailsRenderer } from "./list-rails";
import { diffFromFresh, parsedState, placed, settle, workDuring } from "./render-test-utils";

const ext = [markdown({ base: markdownLanguage }), listRails];
const field = listRails[0] as StateField<DecorationSet>;

const parsed = (doc: string) => parsedState(doc, ext);

const NESTED = "- a\n\t- b\n\t\t- c\n";
// 1200 lines, 6000 chars: twice the core's 3000-char mount parse, and 30x the
// 200-char work bound below, so a full rebuild cannot pass. Bigger docs only
// slowed the setup (two full parses and builds) toward vitest's 5 s limit.
const LONG = NESTED.repeat(400);

describe("list rails render incrementally", () => {
	test("a keystroke at the end of a long list keeps every rail above it (no rebuild)", () => {
		const s = parsed(LONG);
		const before = placed(s.field(field));
		const end = s.doc.length;
		let after = s;
		const work = workDuring(listRailsRenderer, () => {
			after = s.update({ changes: { from: end, insert: "x" } }).state;
		});
		expect(work).toBeLessThan(200);
		const now = placed(after.field(field));
		// The first rail is far from the edit: the SAME object, mapped, not rebuilt.
		expect(now[0]?.[2]).toBe(before[0]?.[2]);
		// The typed line is a lazy continuation of the last item, so it gains rails.
		expect(diffFromFresh(settle(after), ext, field)).toEqual([]);
	});

	test("a keystroke in the middle of a long list re-renders one item, not the list", () => {
		const s = parsed(LONG);
		let after = s;
		const mid = s.doc.line(601).to;
		const work = workDuring(listRailsRenderer, () => {
			after = s.update({ changes: { from: mid, insert: "x" } }).state;
		});
		expect(work).toBeLessThan(200);
		expect(diffFromFresh(settle(after), ext, field)).toEqual([]);
	});

	test("matches a fresh build after nesting, un-nesting and joining edits", () => {
		let s = parsed(`${NESTED.repeat(30)}\npara\n\n${NESTED.repeat(30)}`);
		const edits = [
			{ from: 0, insert: "\t" },
			{ from: s.doc.line(10).from, insert: "\t\t- new\n" },
			{ from: s.doc.line(5).from, to: s.doc.line(5).from + 1 },
			{ from: s.doc.line(90).from, to: s.doc.line(92).to },
			// Bullet to number: CommonMark splits the list there.
			{ from: s.doc.line(40).from + 1, to: s.doc.line(40).from + 2, insert: "1." },
			// Join two items into one line.
			{ from: s.doc.line(50).to, to: s.doc.line(51).from },
			// A blank line then an unindented paragraph ends the list.
			{ from: s.doc.line(60).to, insert: "\n\nbreak" },
		];
		for (const changes of edits) {
			s = settle(s.update({ changes }).state);
			expect(diffFromFresh(s, ext, field)).toEqual([]);
		}
	});

	test("edge cases: empty doc, edit at start, delete everything", () => {
		let s = parsed("");
		expect(placed(s.field(field))).toEqual([]);
		s = settle(s.update({ changes: { from: 0, insert: NESTED } }).state);
		expect(diffFromFresh(s, ext, field)).toEqual([]);
		s = s.update({ changes: { from: 0, to: s.doc.length } }).state;
		expect(placed(s.field(field))).toEqual([]);
	});
});
