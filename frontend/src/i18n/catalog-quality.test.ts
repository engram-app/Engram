import { describe, expect, it } from "vitest";
import { isMember } from "../lib/is-member";
import { problems } from "./auto-translate";
import { LOCALES } from "./locales";
import type { Catalog } from "./translate";

// The checks translategemma's answers must pass, run over the committed catalogs.
// No model, so it stays in the per-PR unit gate: it catches a hand edit or a bad
// merge that drops a brand name, a URL, a placeholder or the register.
const TARGETS = LOCALES.filter((l) => l !== "en");
const catalogs = Object.entries(
	import.meta.glob<{ default: Catalog }>("./locale/*.ts", { eager: true }),
).flatMap(([path, mod]) => {
	const code = path.slice("./locale/".length, -".ts".length);
	return isMember(TARGETS, code) ? [[code, mod.default] as const] : [];
});

describe("committed catalogs pass the translation checks", () => {
	it.each(catalogs)("%s", (code, catalog) => {
		const failures = Object.entries(catalog).flatMap(([key, value]) =>
			// A plural form is checked against the `other` key; a `one` form may drop {count}.
			(typeof value === "string" ? [value] : Object.values(value)).flatMap((form) => {
				const src = form.includes("{count}") ? key : key.replaceAll("{count}", "");
				const found = problems(src, form, code);
				return found.length > 0 ? [{ key, form, found }] : [];
			}),
		);
		expect(failures).toEqual([]);
	});
});
