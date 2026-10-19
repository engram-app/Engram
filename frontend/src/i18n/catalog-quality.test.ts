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

// The Revoke confirm dialog puts Cancel next to the destructive button. ko, ms
// and ru translated the generic "Revoke" as their word for Cancel, so the two
// buttons read the same. The dialog's labels must never equal Cancel.
describe("Revoke confirm dialog", () => {
	it.each(catalogs)("%s: no dialog label reads as Cancel", (_code, catalog) => {
		const cancel = catalog.Cancel;
		for (const key of ["Revoke access", "Revoking…", 'Revoke "{name}"?']) {
			expect(typeof catalog[key]).toBe("string");
			expect(catalog[key]).not.toBe(cancel);
		}
	});
});

// Billing cadences sit side by side (the Monthly | Annual toggle, Paddle
// interval labels). uk rendered Monthly and monthly as its word for Weekly,
// so the toggle read "Weekly | Annually" (2026-10-19).
describe("billing cadences", () => {
	// Each set is shown together: the toggle, then Paddle's interval labels.
	const sets = [
		["Monthly", "Annual"],
		["Daily", "Weekly", "Monthly", "Annually"],
		["daily", "weekly", "monthly", "annual"],
	];
	it.each(catalogs)("%s: each cadence reads differently", (_code, catalog) => {
		for (const keys of sets) {
			const values = keys.map((k) => catalog[k]).filter((v) => typeof v === "string");
			expect(new Set(values).size, keys.join(" / ")).toBe(values.length);
		}
	});
});
