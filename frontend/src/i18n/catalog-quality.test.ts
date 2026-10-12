import { describe, expect, it } from "vitest";
import { isMember } from "../lib/is-member";
import type { Catalog, LocaleState } from "./core/core";
import { sourceProblems } from "./core/core";
import { usedEntries } from "./keys-scan";
import state from "./locale/state.json" with { type: "json" };
import { LOCALES } from "./locales";
import { tr } from "./translate-profile";

// The gate the translator's answers must pass, run over the committed catalogs with
// the same checks (core catalogProblems). No model, so it stays in the per-PR unit
// gate: it catches a hand edit, a bad merge, a missing key or an orphan. A key the
// translator gave up on is tolerated only while it is listed in state.json.
const TARGETS = LOCALES.filter((l) => l !== "en");
const sources = Object.values(
	import.meta.glob<string>(["../**/*.{ts,tsx}", "!../**/*.test.*", "!../i18n/locale/**"], {
		query: "?raw",
		import: "default",
		eager: true,
	}),
);
const entries = usedEntries(sources);
const states = state as unknown as Record<string, LocaleState>;
const catalogs = Object.entries(
	import.meta.glob<{ default: Catalog }>("./locale/*.ts", { eager: true }),
).flatMap(([path, mod]) => {
	const code = path.slice("./locale/".length, -".ts".length);
	return isMember(TARGETS, code) ? [[code, mod.default] as const] : [];
});

describe("committed catalogs", () => {
	it("ships a catalog for every non-English locale", () => {
		expect(catalogs.map(([code]) => code).sort()).toEqual([...TARGETS].sort());
	});
	it.each(catalogs)("%s passes the translation checks", (code, catalog) => {
		expect(tr.catalogProblems(entries, catalog, code, states[code])).toEqual([]);
	});
	it("source strings can be translated", () => {
		expect(sourceProblems(entries)).toEqual([]);
	});
});
