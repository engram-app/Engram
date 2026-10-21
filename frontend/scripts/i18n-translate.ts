#!/usr/bin/env bun
// Translate the web app's catalogs with translategemma on Ollama. The loop is the
// shared core (src/i18n/core/run.ts); this file is the web app's I/O.
//   bun scripts/i18n-translate.ts                     every locale, diff-only
//   bun scripts/i18n-translate.ts --locale de,ja      only these locales
//   bun scripts/i18n-translate.ts --all               retranslate every key (one-off)
//   bun scripts/i18n-translate.ts --resume <dir>      reuse an open bot PR's locale dir
//   bun scripts/i18n-translate.ts --resume-email <dir> same, for the email catalogs
//   bun scripts/i18n-translate.ts --only keys         one catalog set: email, web or keys
// Three runs share the profile: the backend's email strings (priv/i18n/email/*.json,
// see src/i18n/email-keys.ts), the web app's catalogs (src/i18n/locale/*.ts), then
// the named frontmatter KEY names (src/i18n/locale/keys/*.json, frontmatter-keys.ts).
// Env: I18N_OLLAMA_URL (default http://localhost:11434), I18N_MODEL, I18N_CONCURRENCY,
// I18N_REQUEST_TIMEOUT_MS, I18N_STUCK_DAYS (default 14).
// Exits 1 when a key has failed for longer than I18N_STUCK_DAYS: the model cannot
// translate it, so a person must reword the source or the prompt.
import { spawnSync } from "node:child_process";
import { existsSync, mkdirSync, readdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import type { Catalog, StoredState } from "../src/i18n/core/core";
import { run } from "../src/i18n/core/run";
import { EMAIL_GLOSSARY, EMAIL_SOURCES, emailEntries } from "../src/i18n/email-keys";
import { KEY_DESCRIPTIONS, KEY_ENTRIES } from "../src/i18n/frontmatter-keys";
import { scannedFiles, usedEntries } from "../src/i18n/keys-scan";
import { LOCALES } from "../src/i18n/locales";
import { LEGACY_VERSION, profile, type Target } from "../src/i18n/translate-profile";

const args = process.argv.slice(2);
const flag = (name: string): string | undefined => {
	const i = args.indexOf(name);
	return i === -1 ? undefined : args[i + 1];
};
const pick = flag("--locale")?.split(",");
// `--only keys` (or email, web): run just that catalog set.
const only = flag("--only");
const skip = (set: string): boolean => only !== undefined && only !== set;
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

// One run of the shared core over one set of catalogs. Only the file I/O differs
// between the web app (TS modules) and the email strings (JSON).
function translate(opts: {
	set: "email" | "web" | "keys";
	entries: ReturnType<typeof usedEntries>;
	dir: string;
	resumeDir: string | undefined;
	load: (dir: string, code: Target) => Promise<Catalog>;
	write: (file: string, catalog: Catalog) => void;
	ext: string;
	// biome formats only files under frontend/; the email JSON is written formatted.
	format: boolean;
	profile?: typeof profile;
}) {
	if (skip(opts.set)) {
		return Promise.resolve([]);
	}
	const stateFile = join(opts.dir, "state.json");
	const { resumeDir } = opts;
	return run({
		profile: opts.profile ?? profile,
		targets,
		entries: opts.entries,
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
			loadCatalog: (code) => opts.load(opts.dir, code),
			writeCatalog: (code, catalog) => {
				const file = join(opts.dir, `${code}.${opts.ext}`);
				opts.write(file, catalog);
				if (opts.format) {
					format(file);
				}
			},
			readState: () => readJson(stateFile),
			writeState: (state) => {
				writeFileSync(stateFile, `${JSON.stringify(state, null, "\t")}\n`);
				if (opts.format) {
					format(stateFile);
				}
			},
			resume: resumeDir
				? {
						loadCatalog: (code) => opts.load(resumeDir, code),
						state: readJson(join(resumeDir, "state.json")),
					}
				: undefined,
			log: console.log,
			sleep: (ms) => new Promise((resolve) => setTimeout(resolve, ms)),
		},
	});
}

// Email first: it is ~45 keys, so a web run that hits the step timeout
// cannot starve it.
const backend = join(root, "..");
const emailResults = await translate({
	set: "email",
	entries: emailEntries(EMAIL_SOURCES.map((f) => readFileSync(join(backend, f), "utf8"))),
	dir: join(backend, "priv", "i18n", "email"),
	resumeDir: flag("--resume-email"),
	// Glossary terms come from the web catalog, so both say "vault" the same way.
	load: async (dir, code) => {
		const file = join(dir, `${code}.json`);
		const catalog: Catalog = existsSync(file) ? JSON.parse(readFileSync(file, "utf8")) : {};
		const web = await loadFrom(localeDir, code);
		for (const term of EMAIL_GLOSSARY) {
			if (typeof web[term] === "string") {
				catalog[term] = web[term];
			}
		}
		return catalog;
	},
	ext: "json",
	format: false,
	write: (file, catalog) => writeFileSync(file, `${JSON.stringify(catalog, null, "\t")}\n`),
});
const resumeDir = flag("--resume");
const webResults = await translate({
	set: "web",
	entries: usedEntries(sources),
	dir: localeDir,
	resumeDir,
	load: loadFrom,
	ext: "ts",
	format: true,
	write: (file, catalog) => {
		const body = Object.entries(catalog)
			.map(([k, v]) => `\t${JSON.stringify(k)}: ${JSON.stringify(v)},`)
			.join("\n");
		writeFileSync(
			file,
			`import type { Catalog } from "../translate";\n\nexport default {\n${body}\n} satisfies Catalog;\n`,
		);
	},
});

// The named frontmatter fields' KEY names (src/i18n/frontmatter-keys.ts), read by
// the web app and, at compile time, the backend (Engram.Notes.KeyAliases). Lives
// under locale/ so the bot PR's paths and resume archive already cover it.
const keysDir = join(localeDir, "keys");
mkdirSync(keysDir, { recursive: true });
const keyResults = await translate({
	set: "keys",
	entries: KEY_ENTRIES,
	dir: keysDir,
	resumeDir: resumeDir && join(resumeDir, "keys"),
	load: (dir, code) => {
		const file = join(dir, `${code}.json`);
		return Promise.resolve(existsSync(file) ? JSON.parse(readFileSync(file, "utf8")) : {});
	},
	ext: "json",
	format: true,
	write: (file, catalog) => writeFileSync(file, `${JSON.stringify(catalog, null, "\t")}\n`),
	// One string per request with its note; no web glossary or pins apply to a key name.
	profile: { ...profile, glossary: [], pinned: {}, descriptions: KEY_DESCRIPTIONS },
});

// A key the model echoes back (fr `type`, `source`) fails the echo check, but the
// English key already matches, so it is never stuck: it only stays in `failed`.
const results = [...emailResults, ...webResults, ...keyResults.map((r) => ({ ...r, stuck: [] }))];

const stuck = results.flatMap((r) => r.stuck.map((k) => `${r.code}: ${JSON.stringify(k)}`));
if (stuck.length > 0) {
	console.error(
		`Keys failed for over ${process.env.I18N_STUCK_DAYS ?? 14} days:\n${stuck.join("\n")}`,
	);
	process.exit(1);
}
