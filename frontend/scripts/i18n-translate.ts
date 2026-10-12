#!/usr/bin/env bun
// Translate catalogs with translategemma on Ollama. Diff-only by default: fills the
// keys a catalog lacks (a new or edited English string is a new key) and drops keys
// the source no longer uses. One locale at a time; each catalog is written when done.
//   bun scripts/i18n-translate.ts                 every locale, missing keys only
//   bun scripts/i18n-translate.ts --locale vi,ms  only these locales
//   bun scripts/i18n-translate.ts --all           retranslate every key (hours; one-off)
// Env: I18N_OLLAMA_URL (default http://localhost:11434), I18N_MODEL, I18N_CONCURRENCY.
import { spawnSync } from "node:child_process";
import { existsSync, readdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import {
	batchText,
	buildPrompt,
	cleanOutput,
	fromSample,
	GLOSSARY_KEYS,
	HttpError,
	isValid,
	type LocaleState,
	maskPlaceholders,
	mergeCatalog,
	nextLocaleState,
	parseBatch,
	pluralSamples,
	type Target,
	todoKeys,
	unmaskPlaceholders,
	withRetry,
} from "../src/i18n/auto-translate";
import { type Entry, usedEntries } from "../src/i18n/keys-scan";
import { LOCALES } from "../src/i18n/locales";
import type { Catalog, PluralForms } from "../src/i18n/translate";

const OLLAMA = process.env.I18N_OLLAMA_URL ?? "http://localhost:11434";
const MODEL = process.env.I18N_MODEL ?? "translategemma:12b";
const CONCURRENCY = Number(process.env.I18N_CONCURRENCY ?? 4);
const BATCH = 12;
const RETRY_TEMPS = [0, 0.3, 0.6];

const args = process.argv.slice(2);
const all = args.includes("--all");
const pick = args.indexOf("--locale");
const targets = LOCALES.filter((l): l is Target => l !== "en").filter(
	(l) => pick === -1 || (args[pick + 1] ?? "").split(",").includes(l),
);

const src = join(import.meta.dir, "..", "src");
const localeDir = join(src, "i18n", "locale");
const sources = readdirSync(src, { recursive: true, encoding: "utf8" })
	.filter(
		(f) => /\.tsx?$/u.test(f) && !(f.includes(".test.") || f.startsWith(join("i18n", "locale"))),
	)
	.map((f) => readFileSync(join(src, f), "utf8"));
const entries = usedEntries(sources);
const pluralOne = new Map(entries.filter((e) => e.plural).map((e) => [e.key, e.plural?.one]));

const RETRY_DELAYS = [10_000, 30_000, 90_000];
const REQUEST_TIMEOUT = 300_000;

function generate(prompt: string, temperature: number): Promise<string> {
	return withRetry(
		async () => {
			const res = await fetch(`${OLLAMA}/api/generate`, {
				method: "POST",
				body: JSON.stringify({
					model: MODEL,
					prompt,
					stream: false,
					// Keep gemma loaded between requests on the shared Ollama.
					keep_alive: "30m",
					options: { temperature, num_ctx: 4096 },
				}),
				signal: AbortSignal.timeout(REQUEST_TIMEOUT),
			});
			if (!res.ok) {
				throw new HttpError(res.status, `Ollama ${res.status}: ${await res.text()}`);
			}
			const body: { response: string } = await res.json();
			return body.response;
		},
		RETRY_DELAYS,
		(ms) => new Promise((resolve) => setTimeout(resolve, ms)),
	);
}

async function pool(code: Target, tasks: (() => Promise<void>)[]): Promise<void> {
	const queue = [...tasks];
	let done = 0;
	const worker = async (): Promise<void> => {
		for (let task = queue.shift(); task; task = queue.shift()) {
			await task();
			done += 1;
			if (done % 10 === 0) {
				console.log(`${code}: ${done}/${tasks.length} requests`);
			}
		}
	};
	await Promise.all(Array.from({ length: CONCURRENCY }, worker));
}

async function translateOne(
	code: Target,
	glossary: Record<string, string>,
	en: string,
	old?: string,
): Promise<string | null> {
	const { masked, names } = maskPlaceholders(en);
	for (const temp of RETRY_TEMPS) {
		const raw = await generate(
			buildPrompt(code, glossary, batchText([masked]).slice("[1] ".length), false),
			temp,
		);
		const out = cleanOutput(en, unmaskPlaceholders(raw, names), code);
		if (isValid(en, out, code, old)) {
			return out;
		}
	}
	return null;
}

async function translateBatch(
	code: Target,
	glossary: Record<string, string>,
	keys: string[],
	old: Catalog,
	fresh: Catalog,
): Promise<void> {
	const masks = keys.map(maskPlaceholders);
	const answers = parseBatch(
		await generate(buildPrompt(code, glossary, batchText(masks.map((m) => m.masked)), true), 0),
		keys.length,
	);
	for (const [i, key] of keys.entries()) {
		const prev = typeof old[key] === "string" ? old[key] : undefined;
		const raw = answers[i];
		const first =
			raw === undefined
				? null
				: cleanOutput(key, unmaskPlaceholders(raw, masks[i]?.names ?? []), code);
		const out =
			first !== null && isValid(key, first, code, prev)
				? first
				: await translateOne(code, glossary, key, prev);
		if (out !== null) {
			fresh[key] = out;
		}
	}
}

// Each category is translated from a concrete number so the model picks the case form.
async function translatePlural(
	code: Target,
	glossary: Record<string, string>,
	key: string,
	old: Catalog,
	fresh: Catalog,
): Promise<void> {
	const prev = typeof old[key] === "object" ? old[key] : undefined;
	const forms: PluralForms = {};
	for (const { category, sample } of pluralSamples(code)) {
		const en = category === "one" ? (pluralOne.get(key) ?? key) : key;
		const withCount = en.includes("{count}");
		const out = await translateOne(
			code,
			glossary,
			withCount ? en.replaceAll("{count}", sample) : en,
			undefined,
		);
		const form = out !== null && withCount ? fromSample(out, sample) : out;
		if (form === null || !isValid(en, form, code, prev?.[category])) {
			return;
		}
		forms[category] = form;
	}
	fresh[key] = forms;
}

async function glossaryFor(
	code: Target,
	old: Catalog,
	fresh: Catalog,
): Promise<Record<string, string>> {
	const used = new Set(entries.map((e) => e.key));
	const glossary: Record<string, string> = {};
	for (const key of GLOSSARY_KEYS.filter((k) => used.has(k))) {
		const known = old[key];
		const term = typeof known === "string" ? known : await translateOne(code, glossary, key);
		if (term) {
			glossary[key] = term;
			fresh[key] ??= term;
		}
	}
	return glossary;
}

async function loadCatalog(code: Target): Promise<Catalog> {
	const file = join(localeDir, `${code}.ts`);
	if (!existsSync(file)) {
		return {};
	}
	const mod: { default: Catalog } = await import(file);
	return mod.default;
}

function writeCatalog(code: Target, catalog: Catalog): string {
	const file = join(localeDir, `${code}.ts`);
	const body = Object.entries(catalog)
		.map(([k, v]) => `\t${JSON.stringify(k)}: ${JSON.stringify(v)},`)
		.join("\n");
	writeFileSync(
		file,
		`import type { Catalog } from "../translate";\n\nexport default {\n${body}\n} satisfies Catalog;\n`,
	);
	return file;
}

function isPlural(entry: Entry | undefined): boolean {
	return Boolean(entry?.plural);
}

const byKey = new Map(entries.map((e) => [e.key, e]));
// Each file is formatted as soon as it is written: a run killed mid-way (CI step
// timeout) must still leave catalogs that pass `biome ci`.
function format(file: string): void {
	// `bun run`, not the raw bin: its node shebang fails on runners without node.
	const fmt = spawnSync(process.execPath, ["run", "biome", "format", "--write", file], {
		cwd: join(import.meta.dir, ".."),
		stdio: "inherit",
	});
	if (fmt.status !== 0) {
		throw new Error(`biome format failed with status ${fmt.status}`);
	}
}

const stateFile = join(localeDir, "state.json");
const state: Partial<Record<Target, LocaleState>> = existsSync(stateFile)
	? JSON.parse(readFileSync(stateFile, "utf8"))
	: {};
for (const code of targets) {
	const old = await loadCatalog(code);
	const fresh: Catalog = {};
	const todo = todoKeys(entries, old, all, state[code]);
	const glossary = await glossaryFor(code, old, fresh);
	const strings = todo.filter((k) => !(isPlural(byKey.get(k)) || k in fresh));
	const plurals = todo.filter((k) => isPlural(byKey.get(k)));
	const tasks: (() => Promise<void>)[] = [];
	for (let i = 0; i < strings.length; i += BATCH) {
		tasks.push(() => translateBatch(code, glossary, strings.slice(i, i + BATCH), old, fresh));
	}
	for (const key of plurals) {
		tasks.push(() => translatePlural(code, glossary, key, old, fresh));
	}
	await pool(code, tasks);
	const merged = mergeCatalog(entries, old, fresh);
	format(writeCatalog(code, merged));
	// Written per locale, so a killed run resumes: an unstamped locale is redone.
	state[code] = nextLocaleState(todo, fresh, entries);
	writeFileSync(stateFile, `${JSON.stringify(state, null, "\t")}\n`);
	format(stateFile);
	const failed = todo.filter((k) => !(k in fresh));
	const dropped = Object.keys(old).filter((k) => !(k in merged));
	console.log(
		`${code}: ${todo.length - failed.length}/${todo.length} translated, ${failed.filter((k) => k in old).length} kept old, ${failed.filter((k) => !(k in old)).length} still English, ${dropped.length} orphans dropped`,
	);
}
