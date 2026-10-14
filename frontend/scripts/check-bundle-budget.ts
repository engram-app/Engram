#!/usr/bin/env bun
// Fails when the JS a browser must fetch before the app can start (see
// bundle-budget.ts) grows past budget, gzipped.
//
// Exists because posthog-js once rode in the entry bundle unnoticed (~300 KB,
// half of it) through one static import. Raise the budget deliberately, in the
// same PR as whatever earned it.
//   bun scripts/check-bundle-budget.ts <build-dir> [budget-kb]
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { gzipSync } from "node:zlib";
import { initialScripts, overBudget } from "./bundle-budget";

/** Gzipped KB. Initial JS was ~172 KB when this was set (2026-10-14). */
const DEFAULT_BUDGET_KB = 200;

const [, , dir, budgetArg] = process.argv;
if (!dir) {
	console.error("usage: bun scripts/check-bundle-budget.ts <build-dir> [budget-kb]");
	process.exit(2);
}
const budget = Number(budgetArg ?? DEFAULT_BUDGET_KB);
const files = initialScripts(readFileSync(join(dir, "index.html"), "utf8"));
const sizes = files.map((f) => ({ f, gz: gzipSync(readFileSync(join(dir, "assets", f))).length }));
const total = sizes.reduce((sum, s) => sum + s.gz, 0);
for (const { f, gz } of sizes.toSorted((a, b) => b.gz - a.gz).slice(0, 8)) {
	console.log(`${(gz / 1024).toFixed(1).padStart(7)} KB  ${f}`);
}
const line = `initial JS ${(total / 1024).toFixed(1)} KB gzipped across ${files.length} files (budget ${budget} KB)`;
if (overBudget(total, budget)) {
	console.error(
		`::error::${line}. Something heavy became eagerly loaded: lazy-load it, or raise the budget on purpose.`,
	);
	process.exit(1);
}
console.log(`OK: ${line}`);
