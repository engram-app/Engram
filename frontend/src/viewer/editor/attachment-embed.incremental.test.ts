import { markdown, markdownLanguage } from "@codemirror/lang-markdown";
import type { StateField } from "@codemirror/state";
import type { DecorationSet } from "@codemirror/view";
import { describe, expect, test } from "vitest";
import { attachmentEmbeds, refreshAttachmentEmbeds } from "./attachment-embed";
import { diffFromFresh, parsedState, placed, settle } from "./render-test-utils";

const known = new Set(["pic.png"]);
const opts = {
	resolve: (t: string) => (known.has(t) ? `img/${t}` : null),
	load: () => Promise.resolve("blob:x"),
};
const embeds = attachmentEmbeds(opts);
const ext = [markdown({ base: markdownLanguage }), embeds];
const field = embeds[0] as StateField<DecorationSet>;
const PARA = "see ![[pic.png]] and ![[later.png]]\n\n";

describe("attachment embeds render incrementally", () => {
	test("a keystroke far from an embed keeps its widget decoration (no rebuild)", () => {
		const s = parsedState(PARA.repeat(2000), ext);
		const first = placed(s.field(field)).at(0);
		const after = settle(s.update({ changes: { from: s.doc.length, insert: "x" } }).state);
		expect(placed(after.field(field)).at(0)?.[2]).toBe(first?.[2]);
		expect(diffFromFresh(after, ext, field)).toEqual([]);
	});

	test("opening a code fence hides the embeds below; closing it brings them back", () => {
		let s = parsedState(PARA.repeat(100), ext);
		s = settle(s.update({ changes: { from: 0, insert: "```\n" } }).state);
		expect(placed(s.field(field))).toEqual([]);
		s = settle(s.update({ changes: { from: s.doc.line(60).from, insert: "```\n" } }).state);
		expect(diffFromFresh(s, ext, field)).toEqual([]);
	});

	test("a refreshed attachment list re-decorates without an edit", () => {
		let s = parsedState(PARA.repeat(3), ext);
		expect(placed(s.field(field))).toHaveLength(3);
		known.add("later.png");
		s = s.update({ effects: refreshAttachmentEmbeds.of(null) }).state;
		expect(placed(s.field(field))).toHaveLength(6);
		known.delete("later.png");
	});

	test("a shorter or different fence cannot close a longer one", () => {
		const s = parsedState("````md\n```js\n````\n\n![[pic.png]]\n", ext);
		expect(placed(s.field(field))).toHaveLength(1);
	});
});
