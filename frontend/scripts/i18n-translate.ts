#!/usr/bin/env bun
// Translate the web app's catalogs with translategemma on Ollama. The loop is the
// shared core (src/i18n/core/run.ts); this file is the web app's I/O.
//   bun scripts/i18n-translate.ts                     every locale, diff-only
//   bun scripts/i18n-translate.ts --locale de,ja      only these locales
//   bun scripts/i18n-translate.ts --all               retranslate every key (one-off)
//   bun scripts/i18n-translate.ts --resume <dir>      reuse an open bot PR's locale dir
// Env: I18N_OLLAMA_URL (default http://localhost:11434), I18N_MODEL, I18N_CONCURRENCY,
// I18N_REQUEST_TIMEOUT_MS, I18N_STUCK_DAYS (default 14).
// Exits 1 when a key has failed for longer than I18N_STUCK_DAYS: the model cannot
// translate it, so a person must reword the source or the prompt.
import { spawnSync } from "node:child_process";
import { existsSync, readdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import type { Catalog, StoredState } from "../src/i18n/core/core";
import { run } from "../src/i18n/core/run";
import { scannedFiles, usedEntries } from "../src/i18n/keys-scan";
import { LOCALES } from "../src/i18n/locales";
import { LEGACY_VERSION, profile, type Target } from "../src/i18n/translate-profile";

const args = process.argv.slice(2);
const flag = (name: string): string | undefined => {
	const i = args.indexOf(name);
	return i === -1 ? undefined : args[i + 1];
};
const pick = flag("--locale")?.split(",");
const targets = LOCALES.filter((l): l is Target => l !== "en").filter(
	(l) => !pick || pick.includes(l),
);

const root = join(import.meta.dir, "..");
const src = join(root, "src");
const localeDir = join(src, "i18n", "locale");
const sources = scannedFiles(readdirSync(src, { recursive: true, encoding: "utf8" })).map((f) =>
	readFileSync(join(src, f), "utf8"),
);

async function loadFrom(dir: string, code: Target): Promise<Catalog> {
	const file = join(dir, `${code}.ts`);
	if (!existsSync(file)) {
		return {};
	}
	const mod: { default: Catalog } = await import(file);
	return mod.default;
}

function readJson(file: string): Record<string, StoredState> {
	return existsSync(file) ? JSON.parse(readFileSync(file, "utf8")) : {};
}

// Each file is formatted as soon as it is written: a run killed mid-way (CI step
// timeout) must still leave catalogs that pass `biome ci`.
function format(file: string): void {
	// `bun run`, not the raw bin: its node shebang fails on runners without node.
	const fmt = spawnSync(process.execPath, ["run", "biome", "format", "--write", file], {
		cwd: root,
		stdio: "inherit",
	});
	if (fmt.status !== 0) {
		throw new Error(`biome format failed with status ${fmt.status}`);
	}
}

const stateFile = join(localeDir, "state.json");
const resumeDir = flag("--resume");
const results = await run({
	profile,
	targets,
	entries: usedEntries(sources),
	ollama: process.env.I18N_OLLAMA_URL ?? "http://localhost:11434",
	model: process.env.I18N_MODEL ?? "translategemma:12b",
	all: args.includes("--all"),
	concurrency: Number(process.env.I18N_CONCURRENCY ?? 2),
	requestTimeoutMs: Number(process.env.I18N_REQUEST_TIMEOUT_MS ?? 600_000),
	today: new Date().toISOString().slice(0, 10),
	stuckDays: Number(process.env.I18N_STUCK_DAYS ?? 14),
	legacyVersion: LEGACY_VERSION,
	io: {
		fetch: (url, init) => fetch(url, init),
		loadCatalog: (code) => loadFrom(localeDir, code),
		writeCatalog: (code, catalog) => {
			const file = join(localeDir, `${code}.ts`);
			const body = Object.entries(catalog)
				.map(([k, v]) => `\t${JSON.stringify(k)}: ${JSON.stringify(v)},`)
				.join("\n");
			writeFileSync(
				file,
				`import type { Catalog } from "../translate";\n\nexport default {\n${body}\n} satisfies Catalog;\n`,
			);
			format(file);
		},
		readState: () => readJson(stateFile),
		writeState: (state) => {
			writeFileSync(stateFile, `${JSON.stringify(state, null, "\t")}\n`);
			format(stateFile);
		},
		resume: resumeDir
			? {
					loadCatalog: (code) => loadFrom(resumeDir, code),
					state: readJson(join(resumeDir, "state.json")),
				}
			: undefined,
		log: console.log,
		sleep: (ms) => new Promise((resolve) => setTimeout(resolve, ms)),
	},
});

const stuck = results.flatMap((r) => r.stuck.map((k) => `${r.code}: ${JSON.stringify(k)}`));
if (stuck.length > 0) {
	console.error(
		`Keys failed for over ${process.env.I18N_STUCK_DAYS ?? 14} days:\n${stuck.join("\n")}`,
	);
	process.exit(1);
}
