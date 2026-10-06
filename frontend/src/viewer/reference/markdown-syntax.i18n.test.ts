import { describe, expect, test } from "vitest";
import { englishT, type Translate } from "@/i18n/translate";
import {
	CATEGORY_INTROS,
	entrySyntax,
	filterSyntax,
	previewSource,
	resolveSample,
	SYNTAX_ENTRIES,
} from "./markdown-syntax";
import english from "./markdown-syntax.english.fixture.json" with { type: "json" };

// The English strings every entry produced BEFORE its samples became
// translatable (captured from the pre-change module). Translating must never
// change what an English user inserts or sees.
describe("English samples are unchanged", () => {
	test("every entry still yields its pre-i18n syntax, demo and context lines", () => {
		const now: Record<string, unknown> = {};
		for (const e of SYNTAX_ENTRIES) {
			now[e.id] = {
				syntax: e.syntax,
				demo: e.demo,
				pre: e.templatePrelude?.map((line) => resolveSample(line, englishT)),
				post: e.templatePostlude?.map((line) => resolveSample(line, englishT)),
			};
		}
		const intro = CATEGORY_INTROS.Callouts?.syntax;
		now["__intro-callouts"] = {
			syntax: intro === undefined ? undefined : resolveSample(intro, englishT),
		};
		expect(JSON.parse(JSON.stringify(now))).toEqual(english);
	});
});

const GERMAN: Record<string, string> = {
	Title: "Titel",
	"Body.": "Inhalt.",
	Cell: "Zelle",
	Left: "Links",
	Center: "Mitte",
	Right: "Rechts",
	"Claim.": "Behauptung.",
	"Source.": "Quelle.",
	"Shipped on time.": "Pünktlich geliefert.",
	"My note": "Meine Notiz",
	idea: "Idee",
	draft: "Entwurf",
	"Worth knowing, but not urgent.": "Gut zu wissen, aber nicht dringend.",
	"Example text.": "Beispieltext.",
};
const de: Translate = (en) => GERMAN[en] ?? en;
const entry = (id: string) => {
	const found = SYNTAX_ENTRIES.find((e) => e.id === id);
	if (!found) {
		throw new Error(`no entry ${id}`);
	}
	return found;
};

describe("English resolution through the accessors", () => {
	test("entrySyntax / previewSource with englishT equal the pinned strings", () => {
		for (const e of SYNTAX_ENTRIES) {
			const pinned = english[e.id as keyof typeof english] as { syntax: string; demo?: string };
			expect(entrySyntax(e, englishT), e.id).toBe(pinned.syntax);
			expect(previewSource(e, englishT), e.id).toBe(pinned.demo ?? pinned.syntax);
		}
	});

	test("resolveSample passes a plain string through and calls a function with t", () => {
		expect(resolveSample("plain", de)).toBe("plain");
		expect(resolveSample((t) => t("Title"), de)).toBe("Titel");
	});
});

describe("translated samples keep every syntax token", () => {
	test("callout template translates the words, not [!tip]-", () => {
		expect(entrySyntax(entry("callout-foldable"), de)).toBe("> [!tip]- Titel\n> Inhalt.");
	});

	test("gallery inserts translate the placeholders but keep the type identifier", () => {
		expect(entrySyntax(entry("callout-note"), de)).toBe("> [!note] Titel\n> Inhalt.");
	});

	test("gallery demo keeps the English type as title and translates the body", () => {
		expect(previewSource(entry("callout-note"), de)).toBe(
			"> [!note] note\n> Gut zu wissen, aber nicht dringend.",
		);
	});

	test("table keeps the divider row byte-identical", () => {
		expect(entrySyntax(entry("table"), de)).toBe(
			"| Links | Mitte | Rechts |\n| :--- | :---: | ---: |\n| Zelle | Zelle | Zelle |",
		);
	});

	test("footnote translates claim, source and the demo, keeps [^1]", () => {
		expect(entrySyntax(entry("footnote"), de)).toBe("Behauptung.[^1]\n\n[^1]: Quelle.");
		expect(previewSource(entry("footnote"), de)).toMatch(
			/^Pünktlich geliefert\.\[\^1\]\n\n\[\^1\]: /u,
		);
	});

	test("frontmatter translates values, keeps the keys", () => {
		expect(entrySyntax(entry("frontmatter"), de)).toBe(
			"---\ntitle: Meine Notiz\ntags: [Idee, Entwurf]\n---",
		);
	});

	test("the Callouts intro template translates its placeholder words", () => {
		const intro = CATEGORY_INTROS.Callouts?.syntax;
		expect(resolveSample(intro ?? "", de)).toBe("> [!type] Titel\n> Body text.");
	});

	test("an unknown callout type would still get a (translated) neutral body", () => {
		expect(de("Example text.")).toBe("Beispieltext.");
	});
});

describe("search with a translator", () => {
	test("still finds an entry by its English keyword", () => {
		expect(filterSyntax("admonition", de).map((e) => e.id)).toContain("callout-note");
		expect(filterSyntax("footnote", de).map((e) => e.id)).toContain("footnote");
	});

	test("also finds an entry by its translated sample text", () => {
		expect(filterSyntax("Quelle", de).map((e) => e.id)).toContain("footnote");
	});
});
