import matter from "gray-matter";
import { describe, expect, test } from "vitest";
import { filterSyntax, groupByCategory, previewSource, SYNTAX_ENTRIES } from "./markdown-syntax";

describe("markdown-syntax catalogue", () => {
	test("entry ids are unique", () => {
		const ids = SYNTAX_ENTRIES.map((e) => e.id);
		expect(new Set(ids).size).toBe(ids.length);
	});

	test("every entry carries a non-empty snippet", () => {
		for (const entry of SYNTAX_ENTRIES) {
			expect(entry.syntax.trim(), entry.id).not.toBe("");
		}
	});

	test("a blurb, where present, is non-empty", () => {
		// Blurbs are optional on purpose: one that restates the label is noise.
		for (const entry of SYNTAX_ENTRIES) {
			if (entry.blurb !== undefined) {
				expect(entry.blurb.trim(), entry.id).not.toBe("");
			}
		}
	});

	test("a demo, where present, actually differs from the template", () => {
		// A demo identical to `syntax` is pure duplication — drop it and let
		// previewSource fall back instead.
		for (const entry of SYNTAX_ENTRIES) {
			if (entry.demo !== undefined) {
				expect(entry.demo, entry.id).not.toBe(entry.syntax);
			}
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

	test("inline entries stay single-line in both their template and their demo", () => {
		// Inline entries render on ONE row (label, template, result). A multi-line
		// string would blow that layout apart.
		for (const entry of SYNTAX_ENTRIES) {
			if (!entry.block) {
				expect(entry.syntax.includes("\n"), `${entry.id} template`).toBe(false);
				expect(previewSource(entry).includes("\n"), `${entry.id} demo`).toBe(false);
			}
		}
	});

	test("no previewed entry is silently emptied by frontmatter parsing", () => {
		// NoteView runs gray-matter before rendering, and it swallows a LEADING
		// "---" as a frontmatter delimiter — so a bare horizontal rule previewed
		// as an empty box. Any entry whose preview parses to nothing is claiming
		// to demonstrate something while showing nothing.
		for (const entry of SYNTAX_ENTRIES) {
			if (entry.renderable !== false) {
				expect(matter(previewSource(entry)).content.trim(), entry.id).not.toBe("");
			}
		}
	});

	test("a template-led row renders the very template it shows", () => {
		// These rows put the syntax on the left and its result on the right. A
		// separate `demo` would make the right-hand side the rendering of some
		// OTHER string — the two would look related while being unrelated, which
		// is worse than no example at all.
		for (const entry of SYNTAX_ENTRIES) {
			if (entry.templateLed) {
				expect(entry.demo, `${entry.id} must render its own template`).toBeUndefined();
				expect(previewSource(entry), entry.id).toBe(entry.syntax);
			}
		}
	});

	test("sample text never just names its own feature", () => {
		// The tautology this catalogue was rewritten to kill: `**bold**` rendering
		// the word "bold" under a label reading "Bold" taught nothing. A template
		// may still contain a generic word like "code"; what it must not do is
		// echo the entry's own label back.
		for (const entry of SYNTAX_ENTRIES) {
			// Rows that render no label are exempt: the rule exists to stop a
			// VISIBLE label and its example saying the same thing twice. With no
			// label on screen there is nothing to duplicate, and a self-describing
			// sample ("**Bold text**" rendering as bold text) is the whole point.
			if (entry.hideTemplate || entry.templateLed) {
				continue;
			}
			const label = entry.label.toLowerCase();
			expect(previewSource(entry).toLowerCase(), entry.id).not.toContain(label);
		}
	});
});

describe("callout gallery", () => {
	const gallery = SYNTAX_ENTRIES.filter((e) => e.hideTemplate);

	test("is generated from the library map, not typed out by hand", () => {
		// 13 base types today. Asserting a hardcoded list here would defeat the
		// point — this only checks the generation produced a plausible set and
		// covers the types users actually reach for.
		expect(gallery.length).toBeGreaterThanOrEqual(10);
		const ids = gallery.map((e) => e.id);
		for (const type of ["note", "tip", "warning", "danger", "success", "quote"]) {
			expect(ids, type).toContain(`callout-${type}`);
		}
	});

	test("titles each demo with its own type name", () => {
		for (const entry of gallery) {
			expect(previewSource(entry), entry.id).toMatch(
				new RegExp(`^> \\[!${entry.label}\\] ${entry.label}\\n> .+`, "u"),
			);
		}
	});

	test("still inserts a usable template rather than the demo", () => {
		for (const entry of gallery) {
			expect(entry.syntax, entry.id).toBe(`> [!${entry.label}] Title\n> Body.`);
		}
	});
});

describe("previewSource", () => {
	test("prefers the worked example", () => {
		const callout = SYNTAX_ENTRIES.find((e) => e.id === "callout-warning");
		expect(previewSource(callout as never)).toBe(callout?.demo);
	});

	test("falls back to the template when there is no demo", () => {
		// A tag already teaches on its own — no worked example needed.
		const tag = SYNTAX_ENTRIES.find((e) => e.id === "tag");
		expect(tag?.demo).toBeUndefined();
		expect(previewSource(tag as never)).toBe(tag?.syntax);
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
			"Headings",
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
