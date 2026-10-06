import { describe, expect, it } from "vitest";
import type { Tn } from "@/i18n/translate";
import { translatePlural } from "@/i18n/translate";
import { unsearchableNotesNotice } from "./plan-cards";

const tn: Tn = (en, count, vars) => translatePlural({}, "en", en, count, vars);

describe("unsearchableNotesNotice", () => {
	it("is null when every note is indexed", () => {
		expect(unsearchableNotesNotice({ indexed: 5, total: 5 }, tn)).toBeNull();
	});

	it("uses the singular for one hidden note", () => {
		expect(unsearchableNotesNotice({ indexed: 1999, total: 2000 }, tn)).toBe(
			"1 of your notes isn't searchable. Only your oldest 1,999 are indexed, so your newest notes won't show up in search.",
		);
	});

	it("uses the plural and groups digits for many hidden notes", () => {
		expect(unsearchableNotesNotice({ indexed: 2000, total: 3500 }, tn)).toBe(
			"1,500 of your notes aren't searchable. Only your oldest 2,000 are indexed, so your newest notes won't show up in search.",
		);
	});
});
