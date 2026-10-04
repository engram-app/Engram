import { GFM, parser as markdownParser } from "@lezer/markdown";
import { describe, expect, test } from "vitest";
import { bareBulletAsText } from "./bare-bullet";

const parser = markdownParser.configure([GFM, bareBulletAsText]);

function names(doc: string): string[] {
	const out: string[] = [];
	parser.parse(doc).iterate({
		enter: (n) => {
			out.push(n.name);
		},
	});
	return out;
}

// A bare `-` is an empty list item to CommonMark, so the live preview drew the
// bullet the instant the dash was typed and swapped back to a dash when the next
// character made it ordinary text. Obsidian only draws it once `- ` is typed.
describe("bareBulletAsText", () => {
	test.each(["-", "*", "+"])("a bare %s is not a list item", (mark) => {
		expect(names(mark)).not.toContain("ListMark");
		expect(names(mark)).not.toContain("BulletList");
	});

	test.each(["-", "*", "+"])("%s followed by a space is a list item", (mark) => {
		expect(names(`${mark} `)).toContain("ListMark");
	});

	test("a marker with text is a list item", () => {
		expect(names("- item")).toContain("ListMark");
	});

	test("a bare marker nested under an item is not a list item", () => {
		expect(names("- a\n  -").filter((n) => n === "ListMark")).toHaveLength(1);
	});

	test("ordered markers are untouched", () => {
		expect(names("1.")).toContain("ListMark");
	});

	test("a dash under a paragraph is still a setext heading underline", () => {
		expect(names("hello\n-")).toContain("SetextHeading2");
	});

	test("the line after a bare marker still parses normally", () => {
		expect(names("-\n- item")).toContain("ListMark");
	});
});
