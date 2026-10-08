import { describe, expect, test } from "vitest";
import { findComments, stripComments } from "./comments";

// Comment syntax. Neither form is a markdown standard: `%%…%%` is Obsidian's
// (inline or multi-line block), and `<!-- … -->` is plain HTML, which CommonMark
// and GFM pass through and every renderer hides. Both are scanned outside code.
const texts = (s: string) => findComments(s).map((c) => s.slice(c.from, c.to));

describe("findComments", () => {
	test("finds an inline %% comment, markers included", () => {
		expect(texts("an %%inline%% note")).toEqual(["%%inline%%"]);
	});

	test("finds a multi-line %% block", () => {
		const s = "before\n\n%%\nblock\ncomment\n%%\n\nafter";
		expect(texts(s)).toEqual(["%%\nblock\ncomment\n%%"]);
	});

	test("finds an HTML comment", () => {
		expect(texts("a <!-- hidden --> b")).toEqual(["<!-- hidden -->"]);
	});

	test("finds a multi-line HTML comment", () => {
		expect(texts("a <!--\nx\ny\n--> b")).toEqual(["<!--\nx\ny\n-->"]);
	});

	test("finds several comments, of both kinds, in order", () => {
		expect(texts("%%a%% mid <!-- b --> and %%c%%")).toEqual(["%%a%%", "<!-- b -->", "%%c%%"]);
	});

	test("an unclosed %% runs to the end of the note, as in Obsidian", () => {
		expect(texts("keep %%then everything\nafter")).toEqual(["%%then everything\nafter"]);
	});

	test("an unclosed <!-- runs to the end of the note", () => {
		expect(texts("keep <!-- then all\nof it")).toEqual(["<!-- then all\nof it"]);
	});

	test("a lone percent sign is not a comment", () => {
		expect(texts("it grew 50% and then 20% more")).toEqual([]);
	});

	test("ignores comment markers inside fenced code", () => {
		expect(texts("```\n%%not a comment%%\n<!-- nor this -->\n```\n")).toEqual([]);
	});

	test("ignores comment markers inside inline code", () => {
		expect(texts("use `%%x%%` and `<!-- y -->` here")).toEqual([]);
	});

	test("resumes after a fence closes", () => {
		expect(texts("```\n%%x%%\n```\nreal %%y%% here")).toEqual(["%%y%%"]);
	});

	test("finds a comment inside a table cell", () => {
		expect(texts("| a | b %%note%% |\n| --- | --- |")).toEqual(["%%note%%"]);
	});

	test("reports exact offsets", () => {
		const s = "ab %%cd%% ef";
		expect(findComments(s)).toEqual([{ from: 3, to: 9, kind: "percent" }]);
		expect(findComments("x <!--y-->")).toEqual([{ from: 2, to: 10, kind: "html" }]);
	});
});

describe("stripComments", () => {
	test("removes comments and keeps the text around them", () => {
		expect(stripComments("a %%x%% b")).toBe("a  b");
		expect(stripComments("a <!-- x --> b")).toBe("a  b");
	});

	test("removes a block comment, leaving the surrounding blank lines", () => {
		expect(stripComments("one\n\n%%\nhidden\n%%\n\ntwo")).toBe("one\n\n\n\ntwo");
	});

	test("returns text without comments untouched", () => {
		expect(stripComments("plain **bold** text")).toBe("plain **bold** text");
	});

	test("leaves code alone", () => {
		const md = "```\n%%keep%%\n```\nand `%%keep too%%`";
		expect(stripComments(md)).toBe(md);
	});

	test("an unclosed %% hides the rest", () => {
		expect(stripComments("shown %%hidden\nhidden too")).toBe("shown ");
	});

	test("leaves a fence nested in a list item alone, however deep", () => {
		const md = "- item\n    - nested\n        ```\n        %%timeit\n        ```\n\nafter";
		expect(stripComments(md)).toBe(md);
	});

	test("leaves a fence inside a callout or blockquote alone", () => {
		const md = '> [!note]\n> ```c\n> printf("%%d");\n> ```\n\nafter';
		expect(stripComments(md)).toBe(md);
	});

	test("leaves an indented code block alone", () => {
		const md = "para\n\n    %%not a comment\n\nafter";
		expect(stripComments(md)).toBe(md);
	});

	test("a ~~~ line does not close a ``` fence", () => {
		const md = "```\n~~~\n%%keep%%\n```\n";
		expect(stripComments(md)).toBe(md);
	});

	test("an indented line after a list item is list content, not code", () => {
		expect(stripComments("- item\n\n    text %%gone%% more")).toBe("- item\n\n    text  more");
	});
});
