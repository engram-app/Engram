#!/usr/bin/env bun
// Stamp the i18n core's header hashes, then copy the core into other repos.
//   bun scripts/i18n-core-sync.ts                       restamp after editing the core
//   bun scripts/i18n-core-sync.ts --to <dir> [--to <dir>]  also vendor it into <dir>
// <dir> is the other repo's i18n core directory (plugin and marketing: src/i18n/core).
// The workspace's `make i18n-core-sync` passes both. Only this canonical copy is
// ever edited; a vendored copy edited in place fails its own header test.
import { copyFileSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { hash } from "../src/i18n/core/core";

const dir = join(import.meta.dir, "..", "src", "i18n", "core");
const STAMPED = ["core.ts", "run.ts"];
const FILES = [...STAMPED, "README.md"];

for (const name of STAMPED) {
	const file = join(dir, name);
	const text = readFileSync(file, "utf8");
	const body = text.slice(text.indexOf("\n") + 1);
	writeFileSync(file, `// i18n-core ${hash(body)}\n${body}`);
}

const args = process.argv.slice(2);
for (const [i, arg] of args.entries()) {
	if (arg !== "--to") {
		continue;
	}
	const to = args[i + 1];
	if (!to) {
		throw new Error("--to needs a directory");
	}
	mkdirSync(to, { recursive: true });
	for (const name of FILES) {
		copyFileSync(join(dir, name), join(to, name));
	}
	console.log(`i18n core -> ${to}`);
}
