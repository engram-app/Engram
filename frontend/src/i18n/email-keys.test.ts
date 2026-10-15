import { readFileSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import type { Catalog, LocaleState } from "./core/core";
import { sourceProblems } from "./core/core";
import { EMAIL_GLOSSARY, EMAIL_SOURCES, emailEntries } from "./email-keys";
import { LOCALES } from "./locales";
import { tr } from "./translate-profile";

describe("emailEntries", () => {
	it("reads translate calls and changelogs, unescaping quotes", () => {
		const elixir = [
			'    #{t(l, "Hi {name},", name: name)}',
			'  I18n.t(l, "Your vault \\"{vault}\\" was deleted.", vault: v)',
			'  "2026-10-12" => %{material: false, changelog:\n    "Analytics linked."}',
			"  t(l, version.changelog)",
		].join("\n");
		expect(emailEntries([elixir]).map((e) => e.key)).toEqual([
			"Hi {name},",
			'Your vault "{vault}" was deleted.',
			"Analytics linked.",
			...EMAIL_GLOSSARY,
		]);
	});
	// A version with no effective date is silent: no email or notice ever
	// shows its changelog, so translating it only adds dead catalog entries.
	it("skips the changelog of a silent (nil effective_date) version", () => {
		const elixir = [
			'  "2026-10-12" => %{material: false, effective_date: ~D[2026-11-11], changelog: "Told."}',
			'  "2026-10-14" => %{\n    material: false,\n    effective_date: nil,\n    changelog:\n      "Silent."\n  }',
		].join("\n");
		expect(emailEntries([elixir]).map((e) => e.key)).toEqual(["Told.", ...EMAIL_GLOSSARY]);
	});
	it("adds the glossary terms, so emails say vault the way the app does", () => {
		const keys = emailEntries(['t(l, "Hi.")']).map((e) => e.key);
		expect(keys).toEqual(["Hi.", ...EMAIL_GLOSSARY]);
	});
	it("ignores translate calls in comments", () => {
		const elixir = ['  # Each sentence is one `t(l, "...")` call.', '  t(l, "Real.")'].join("\n");
		expect(emailEntries([elixir]).map((e) => e.key)).toEqual(["Real.", ...EMAIL_GLOSSARY]);
	});
});

// The gate over the committed email catalogs (same checks as the web app's),
// so a hand edit, a missing key or an orphan fails the PR, not production.
const backend = join(__dirname, "..", "..", "..");
const entries = emailEntries(EMAIL_SOURCES.map((f) => readFileSync(join(backend, f), "utf8")));
const dir = join(backend, "priv", "i18n", "email");
const read = (file: string): unknown => JSON.parse(readFileSync(join(dir, file), "utf8"));
const states = read("state.json") as Record<string, LocaleState>;

// House voice: emails speak as "we", never "I" (one person reads as a tiny
// company). See the workspace docs/context/customer-email-voice.md.
describe("email voice", () => {
	it("no email string speaks in the first person singular", () => {
		const firstPerson = /\b(?:I|I'm|I've|I'd|I'll|me|my|mine)\b/u;
		expect(entries.map((e) => e.key).filter((k) => firstPerson.test(k))).toEqual([]);
	});
});

describe("committed email catalogs", () => {
	it("finds the email strings", () => {
		expect(entries.length).toBeGreaterThan(20);
		expect(sourceProblems(entries)).toEqual([]);
	});
	it.each(LOCALES.filter((l) => l !== "en"))("%s passes the translation checks", (code) => {
		const catalog = read(`${code}.json`) as Catalog;
		expect(tr.catalogProblems(entries, catalog, code, states[code])).toEqual([]);
	});
	it.each(LOCALES.filter((l) => l !== "en"))(
		"%s uses the web app's glossary terms",
		async (code) => {
			const email = read(`${code}.json`) as Catalog;
			const web: { default: Catalog } = await import(`./locale/${code}.ts`);
			for (const term of EMAIL_GLOSSARY) {
				expect(email[term]).toBe(web.default[term]);
			}
		},
	);
});
