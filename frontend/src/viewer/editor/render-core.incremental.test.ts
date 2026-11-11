import { markdown, markdownLanguage } from "@codemirror/lang-markdown";
import { syntaxTree } from "@codemirror/language";
import { EditorState, type StateField } from "@codemirror/state";
import type { DecorationSet } from "@codemirror/view";
import { describe, expect, test } from "vitest";
import { embedRenderer } from "./attachment-embed";
import { commentDecoration, commentRenderer } from "./comment-decoration";
import { indentedCodeLines, indentedCodeRenderer } from "./indented-code";
import { listRails, listRailsRenderer } from "./list-rails";
import { mermaidDecoration, mermaidRenderer } from "./mermaid-decoration";
import { defineRenderer } from "./render-core";
import { diffFromFresh, parsedState, placed, settle, workDuring } from "./render-test-utils";

// Cross-renderer cases for the render core: cost inside large blocks, and
// correctness while the parser lags.

const embeds = embedRenderer({ resolve: (t) => `img/${t}`, load: () => Promise.resolve("blob:x") });
const embedField = defineRenderer(embeds);
const railsField = listRails[0] as StateField<DecorationSet>;
const ext = [
	markdown({ base: markdownLanguage }),
	commentDecoration,
	indentedCodeLines,
	listRails,
	mermaidDecoration,
	embedField,
];
const fields: [string, StateField<DecorationSet>][] = [
	["comments", commentDecoration],
	["indented code", indentedCodeLines],
	["list rails", railsField],
	["mermaid", mermaidDecoration],
	["embeds", embedField],
];

describe("render core cost", () => {
	test("a keystroke inside a closed 5000-line fence costs the edited line, in every renderer", () => {
		const body = Array.from(
			{ length: 5000 },
			(_, i) => `const v${i} = ${i}; // %% ![[a.png]]`,
		).join("\n");
		const s = parsedState(`- top\n\t- nested\n\n\`\`\`js\n${body}\n\`\`\`\n\nafter %%c%%\n`, ext);
		const at = s.doc.line(2500).from + 3;
		let after = s;
		const cost: Record<string, number> = {};
		const run = () => {
			after = s.update({ changes: { from: at, insert: "x" } }).state;
		};
		for (const [name, r] of [
			["comments", commentRenderer],
			["list rails", listRailsRenderer],
			["indented code", indentedCodeRenderer],
			["mermaid", mermaidRenderer],
			["embeds", embeds],
		] as const) {
			cost[name] = workDuring(r, run);
		}
		expect(s.doc.length).toBeGreaterThan(150_000);
		for (const [name, chars] of Object.entries(cost)) {
			expect(chars, name).toBeLessThan(500);
		}
		const settled = settle(after);
		for (const [name, f] of fields) {
			expect(diffFromFresh(settled, ext, f), name).toEqual([]);
		}
	});
});

describe("decorations hold while the parser lags", () => {
	test("open a fence at the top of a long note, append a list, close it: matches a fresh build", () => {
		const para = "some text %%c%% and ![[a.png]] here\n\n\tcode line\n\n- a\n\t- b\n\n";
		// Far past the mount parse budget (3000 chars) and never settled until the
		// end, so every edit lands while most of the note is still unparsed.
		let s = EditorState.create({
			doc: para.repeat(Math.ceil(60_000 / para.length)),
			extensions: ext,
		});
		expect(syntaxTree(s).length).toBeLessThan(s.doc.length);
		s = s.update({ changes: { from: 0, insert: "```\n" } }).state;
		s = s.update({ changes: { from: s.doc.length, insert: "\n- x\n\t- y\n" } }).state;
		s = s.update({ changes: { from: 0, to: 4 } }).state;
		s = settle(s);
		for (const [name, f] of fields) {
			expect(diffFromFresh(s, ext, f), name).toEqual([]);
		}
		expect(placed(s.field(railsField)).length).toBeGreaterThan(0);
	}, 60_000);
});

describe("an edit that changes a later block", () => {
	const md = markdown({ base: markdownLanguage });

	test("breaking a fence opener lets a later ``` open to the end: comments below follow", () => {
		const cext = [md, commentDecoration];
		let s = parsedState("```js\na\nc %%\nd\n```\n\n%%\nblock\n%%\n\n%%\nblock\n%%\n", cext);
		s = settle(s.update({ changes: { from: 1, insert: "---" } }).state);
		expect(diffFromFresh(s, cext, commentDecoration)).toEqual([]);
	});

	test("unmaking an HTML block lets a later ``` open to the end: indented code below follows", () => {
		const iext = [md, indentedCodeLines];
		let s = parsedState(
			"%%\nblock\ncomment```\n%%\n\n<div>\nhtml\n```re\n</div>\n\n%%\nblock\ncomment\n%%\n\n$$ lone\nmore\nmore\n\n\tcode1\n\tcode2\n\tcode3\n\n\tcode1```\tcode2\n\tcode3\n",
			iext,
		);
		s = settle(s.update({ changes: { from: 27, to: 30, insert: "- " } }).state);
		expect(diffFromFresh(s, iext, indentedCodeLines)).toEqual([]);
	});
});
