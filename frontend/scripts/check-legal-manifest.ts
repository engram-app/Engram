#!/usr/bin/env bun
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { join } from "node:path";
const dir = join(import.meta.dir, "..", "src", "legal", "versions");
const manifest = JSON.parse(readFileSync(join(dir, "legal-manifest.json"), "utf8"));
const docPrefix: Record<string, string> = { terms_of_service: "terms", privacy_policy: "privacy" };
let bad = 0;
for (const [doc, versions] of Object.entries(manifest) as [string, Record<string, string>][]) {
	for (const [v, hash] of Object.entries(versions)) {
		const bytes = readFileSync(join(dir, `${docPrefix[doc]}-${v}.md`));
		const got = createHash("sha256").update(bytes).digest("hex");
		if (got !== hash) {
			console.error(`legal manifest mismatch: ${doc} ${v}`);
			bad++;
		}
	}
}
if (bad) process.exit(1);
console.log("legal manifest OK");
