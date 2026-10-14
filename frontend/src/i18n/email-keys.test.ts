import { readFileSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import type { Catalog, LocaleState } from "./core/core";
import { sourceProblems } from "./core/core";
import { EMAIL_SOURCES, emailEntries } from "./email-keys";
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
		]);
	});
	it("ignores translate calls in comments", () => {
		const elixir = ['  # Each sentence is one `t(l, "...")` call.', '  t(l, "Real.")'].join("\n");
		expect(emailEntries([elixir]).map((e) => e.key)).toEqual(["Real."]);
	});
});

// The gate over the committed email catalogs (same checks as the web app's),
// so a hand edit, a missing key or an orphan fails the PR, not production.
const backend = join(__dirname, "..", "..", "..");
const entries = emailEntries(EMAIL_SOURCES.map((f) => readFileSync(join(backend, f), "utf8")));
const dir = join(backend, "priv", "i18n", "email");
const read = (file: string): unknown => JSON.parse(readFileSync(join(dir, file), "utf8"));
const states = read("state.json") as Record<string, LocaleState>;

describe("committed email catalogs", () => {
	it("finds the email strings", () => {
		expect(entries.length).toBeGreaterThan(20);
		expect(sourceProblems(entries)).toEqual([]);
	});
	it.each(LOCALES.filter((l) => l !== "en"))("%s passes the translation checks", (code) => {
		const catalog = read(`${code}.json`) as Catalog;
		expect(tr.catalogProblems(entries, catalog, code, states[code])).toEqual([]);
	});
});
