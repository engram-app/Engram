import { describe, expect, test } from "vitest";
import { CATEGORY_INTROS, SYNTAX_ENTRIES } from "./markdown-syntax";
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
				pre: e.templatePrelude,
				post: e.templatePostlude,
			};
		}
		now["__intro-callouts"] = { syntax: CATEGORY_INTROS.Callouts?.syntax };
		expect(JSON.parse(JSON.stringify(now))).toEqual(english);
	});
});
