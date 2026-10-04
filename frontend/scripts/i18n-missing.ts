#!/usr/bin/env bun
// Report: which catalog keys each locale still lacks. Always exits 0.
//   bun scripts/i18n-missing.ts                 full JSON report
//   bun scripts/i18n-missing.ts --locale de     that locale's missing entries (JSON array)
//   bun scripts/i18n-missing.ts --count         "code: missingCount" per locale
import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { usedEntries } from "../src/i18n/keys-scan";
import { findMissing } from "../src/i18n/missing";
import type { Catalog } from "../src/i18n/translate";

const src = join(import.meta.dir, "..", "src");
const files = readdirSync(src, { recursive: true, encoding: "utf8" }).filter(
	(f) => /\.tsx?$/u.test(f) && !(f.includes(".test.") || f.startsWith(join("i18n", "locale"))),
);
const sources = files.map((f) => readFileSync(join(src, f), "utf8"));

const catalogs: Record<string, Catalog> = {};
const localeDir = join(src, "i18n", "locale");
for (const file of readdirSync(localeDir)) {
	const mod: { default: Catalog } = await import(join(localeDir, file));
	catalogs[file.slice(0, -".ts".length)] = mod.default;
}

const { total, missing } = findMissing(usedEntries(sources), catalogs);
const locales = Object.keys(catalogs).sort();
const args = process.argv.slice(2);
const pick = args.indexOf("--locale");

if (args.includes("--count")) {
	for (const code of locales) {
		console.log(`${code}: ${missing[code]?.length ?? 0}`);
	}
} else if (pick === -1) {
	console.log(JSON.stringify({ locales, total, missing }, null, 2));
} else {
	const code = args[pick + 1] ?? "";
	console.log(JSON.stringify(missing[code] ?? [], null, 2));
}
