import { describe, expect, test } from "vitest";
import { filterSyntax, groupByCategory, SYNTAX_ENTRIES } from "./markdown-syntax";

describe("markdown-syntax catalogue", () => {
	test("entry ids are unique", () => {
		const ids = SYNTAX_ENTRIES.map((e) => e.id);
		expect(new Set(ids).size).toBe(ids.length);
	});

	test("every entry carries a non-empty snippet and blurb", () => {
		for (const entry of SYNTAX_ENTRIES) {
			expect(entry.syntax.trim(), entry.id).not.toBe("");
			expect(entry.blurb.trim(), entry.id).not.toBe("");
		}
	});

	test("every multi-line snippet is marked block, so insertion breaks the line", () => {
		// A multi-line snippet inserted mid-sentence without a leading break
		// produces broken markdown — the two facts must not drift apart.
		for (const entry of SYNTAX_ENTRIES) {
			if (entry.syntax.includes("\n")) {
				expect(entry.block, `${entry.id} is multi-line but not marked block`).toBe(true);
			}
		}
	});
});

describe("filterSyntax", () => {
	test("returns everything for an empty query", () => {
		expect(filterSyntax("")).toHaveLength(SYNTAX_ENTRIES.length);
		expect(filterSyntax("   ")).toHaveLength(SYNTAX_ENTRIES.length);
	});

	test("matches on the label", () => {
		expect(filterSyntax("strikethrough").map((e) => e.id)).toEqual(["strikethrough"]);
	});

	test("matches on a keyword that appears nowhere else in the entry", () => {
		// "admonition" is not in any callout label, syntax, or blurb.
		const ids = filterSyntax("admonition").map((e) => e.id);
		expect(ids).toContain("callout-note");
		expect(ids).toContain("callout-warning");
	});

	test("matches on the snippet text itself", () => {
		expect(filterSyntax("[[").map((e) => e.id)).toContain("wikilink");
	});

	test("is case-insensitive", () => {
		expect(filterSyntax("MERMAID").map((e) => e.id)).toContain("mermaid");
	});

	test("requires every term, in any order", () => {
		const forward = filterSyntax("block math").map((e) => e.id);
		const reverse = filterSyntax("math block").map((e) => e.id);
		expect(forward).toContain("math-block");
		expect(forward).toEqual(reverse);
	});

	test("returns nothing when a term matches no entry", () => {
		expect(filterSyntax("mermaid nonsenseterm")).toHaveLength(0);
	});

	test("finds syntax by the problem, not just the name", () => {
		// A user hunting for a divider will not type "thematic break".
		expect(filterSyntax("divider").map((e) => e.id)).toContain("rule");
		expect(filterSyntax("checkbox").map((e) => e.id)).toContain("task-list");
		expect(filterSyntax("latex").map((e) => e.id)).toContain("math-inline");
	});
});

describe("groupByCategory", () => {
	test("groups entries under their category, preserving order", () => {
		const grouped = groupByCategory(SYNTAX_ENTRIES);
		expect(grouped[0]?.[0]).toBe("Text");
		expect(grouped.map(([name]) => name)).toEqual([
			"Text",
			"Structure",
			"Links",
			"Callouts",
			"Code",
			"Math",
			"Properties",
		]);
	});

	test("loses no entries", () => {
		const grouped = groupByCategory(SYNTAX_ENTRIES);
		const total = grouped.reduce((sum, [, entries]) => sum + entries.length, 0);
		expect(total).toBe(SYNTAX_ENTRIES.length);
	});

	test("returns no empty groups for a narrow filter", () => {
		const grouped = groupByCategory(filterSyntax("callout"));
		expect(grouped).toHaveLength(1);
		expect(grouped[0]?.[0]).toBe("Callouts");
	});
});
