// i18n-core bee71125
// The translategemma run loop shared by every repo's `scripts/i18n-translate.ts`.
// Diff-only: per locale it fills keys the catalog lacks, retries failed keys, heals
// entries that fail a current check, and redoes everything when the fingerprint
// (prompt, profile, model digest) moved. Each catalog is written when its locale
// finishes, so a killed run keeps what it finished. All I/O comes in through
// `RunIo`: no Node or DOM imports (see core.ts).
import {
	batchText,
	type Catalog,
	type Entry,
	exactOne,
	formSource,
	fromSample,
	glossaryStale,
	HttpError,
	hash,
	type LocaleState,
	mergeCatalog,
	nextLocaleState,
	oneChangedKeys,
	type PluralForms,
	type Profile,
	parseBatch,
	pluralCategories,
	pluralSamples,
	richLines,
	type StoredState,
	stuckKeys,
	todoKeys,
	translator,
	upgradeState,
	withRetry,
} from "./core";

interface RunIo<T extends string> {
	fetch: (
		url: string,
		init: { method: string; body?: string; signal: AbortSignal },
	) => Promise<{
		ok: boolean;
		status: number;
		text: () => Promise<string>;
		// The fields of Ollama's /api/generate and /api/tags replies the loop reads.
		json: () => Promise<{ response?: string; models?: { name: string; digest: string }[] }>;
	}>;
	loadCatalog: (code: T) => Promise<Catalog>;
	// The repo's file shape; formats the file before returning.
	writeCatalog: (code: T, catalog: Catalog) => void;
	readState: () => Record<string, StoredState>;
	writeState: (state: Record<string, StoredState>) => void;
	// The open bot PR's catalogs and state, when there is one: entries it already
	// translated for keys this run would translate are reused, not redone.
	resume?: { loadCatalog: (code: T) => Promise<Catalog>; state: Record<string, StoredState> };
	log: (message: string) => void;
	sleep: (ms: number) => Promise<void>;
}

interface RunOptions<T extends string> {
	profile: Profile<T>;
	targets: readonly T[];
	entries: readonly Entry[];
	ollama: string;
	model: string;
	all: boolean;
	// Ollama queues requests and a queued request's timeout runs while it waits, so
	// more in flight than the server works on only adds timeouts. 2 survives a busy FastRaid.
	concurrency: number;
	requestTimeoutMs: number;
	// YYYY-MM-DD, for `state.failed`.
	today: string;
	// A failed key older than this many days is reported as stuck.
	stuckDays: number;
	// The repo's last numbered TRANSLATOR_VERSION, adopted once (see upgradeState).
	legacyVersion?: number;
	io: RunIo<T>;
}

interface LocaleResult {
	code: string;
	translated: number;
	todo: number;
	keptOld: number;
	// Missing (English shows) or invalid; listed in state.failed.
	failed: number;
	orphans: number;
	stuck: string[];
}

const BATCH = 12;
const RETRY_TEMPS = [0, 0.3, 0.6];
const RETRY_DELAYS = [10_000, 30_000, 90_000];

// The digest pins the weights: `ollama pull` can move a tag under the same name.
async function modelDigest<T extends string>(opts: RunOptions<T>): Promise<string> {
	const res = await opts.io.fetch(`${opts.ollama}/api/tags`, {
		method: "GET",
		signal: AbortSignal.timeout(30_000),
	});
	if (!res.ok) {
		throw new HttpError(res.status, `Ollama /api/tags ${res.status}: ${await res.text()}`);
	}
	const body = await res.json();
	const want = opts.model.includes(":") ? opts.model : `${opts.model}:latest`;
	const found = body.models?.find((m) => m.name === want);
	if (!found) {
		throw new Error(`Ollama has no model ${want}; pull it first`);
	}
	return found.digest;
}

async function run<T extends string>(opts: RunOptions<T>): Promise<LocaleResult[]> {
	const { io, entries } = opts;
	const tr = translator(opts.profile);
	const digest = await modelDigest(opts);
	const byKey = new Map(entries.map((e) => [e.key, e]));
	const used = new Set(byKey.keys());

	function generate(prompt: string, temperature: number): Promise<string> {
		return withRetry(
			async () => {
				const res = await io.fetch(`${opts.ollama}/api/generate`, {
					method: "POST",
					body: JSON.stringify({
						model: opts.model,
						prompt,
						stream: false,
						// Keep gemma loaded between requests on the shared Ollama.
						keep_alive: "30m",
						options: { temperature, num_ctx: 4096 },
					}),
					signal: AbortSignal.timeout(opts.requestTimeoutMs),
				});
				if (!res.ok) {
					throw new HttpError(res.status, `Ollama ${res.status}: ${await res.text()}`);
				}
				const { response } = await res.json();
				if (response === undefined) {
					throw new Error("Ollama reply has no response field");
				}
				return response;
			},
			RETRY_DELAYS,
			io.sleep,
			io.log,
		);
	}

	async function pool(code: T, tasks: (() => Promise<void>)[]): Promise<void> {
		const queue = [...tasks];
		let done = 0;
		const worker = async (): Promise<void> => {
			for (let task = queue.shift(); task; task = queue.shift()) {
				await task();
				done += 1;
				if (done % 10 === 0) {
					io.log(`${code}: ${done}/${tasks.length} requests`);
				}
			}
		};
		await Promise.all(Array.from({ length: opts.concurrency }, worker));
	}

	async function translateOne(
		code: T,
		terms: Record<string, string>,
		en: string,
		old?: string,
	): Promise<string | null> {
		const { masked, names } = tr.mask(en);
		for (const temp of RETRY_TEMPS) {
			const raw = await generate(
				tr.buildPrompt(code, terms, batchText([masked]).slice("[1] ".length), false),
				temp,
			);
			const out = tr.cleanOutput(en, tr.unmask(raw, names), code);
			if (tr.isValid(en, out, code, old)) {
				return out;
			}
		}
		// Headline markup the model reshuffles: translate each line's plain text,
		// rebuild the tags here, and check the whole result again.
		const split = richLines(en);
		if (!split) {
			return null;
		}
		const parts: string[] = [];
		for (const line of split.inner) {
			const part = await translateOne(code, terms, line);
			if (part === null) {
				return null;
			}
			parts.push(part);
		}
		const joined = split.join(parts);
		return tr.isValid(en, joined, code, old) ? joined : null;
	}

	async function translateBatch(
		code: T,
		terms: Record<string, string>,
		keys: string[],
		old: Catalog,
		fresh: Catalog,
	): Promise<void> {
		const masks = keys.map(tr.mask);
		const answers = parseBatch(
			await generate(tr.buildPrompt(code, terms, batchText(masks.map((m) => m.masked)), true), 0),
			keys.length,
		);
		for (const [i, key] of keys.entries()) {
			const prev = typeof old[key] === "string" ? old[key] : undefined;
			const raw = answers[i];
			const first =
				raw === undefined ? null : tr.cleanOutput(key, tr.unmask(raw, masks[i]?.names ?? []), code);
			const out =
				first !== null && tr.isValid(key, first, code, prev)
					? first
					: await translateOne(code, terms, key, prev);
			if (out !== null) {
				fresh[key] = out;
			}
		}
	}

	// Each category is translated from a concrete number so the model picks the case form.
	async function translatePlural(
		code: T,
		terms: Record<string, string>,
		entry: Entry,
		fresh: Catalog,
	): Promise<void> {
		const forms: PluralForms = {};
		// One form only (ja, zh, vi): no grammar to pick, so {count} stays a masked
		// placeholder. A sample number next to other tokens got swapped for one.
		if (pluralCategories(code).length === 1) {
			const out = await translateOne(code, terms, entry.key);
			if (out !== null) {
				fresh[entry.key] = { other: out };
			}
			return;
		}
		for (const { category, sample } of pluralSamples(code)) {
			// The English singular only where `one` means exactly 1. Where it also
			// renders 21 (ru), "Copied wikilink" would read "one" for 21: translate
			// the counted form with the sample instead.
			const en =
				category === "one" && exactOne(code) ? (entry.plural?.one ?? entry.key) : entry.key;
			const withCount = en.includes("{count}");
			const out = await translateOne(
				code,
				terms,
				withCount ? en.replaceAll("{count}", sample) : en,
			);
			let form = out !== null && withCount ? fromSample(out, sample) : out;
			// "Eine Notiz": the number spelled out, fine where `one` is only ever 1.
			if (
				form === null &&
				out !== null &&
				category === "one" &&
				exactOne(code) &&
				!/\d/u.test(out)
			) {
				form = out;
			}
			if (form === null || !tr.isValid(formSource(en, form), form, code)) {
				return;
			}
			forms[category] = form;
		}
		// The whole entry must pass the gate, not only each form.
		if (tr.entryProblems(entry, forms, code).length === 0) {
			fresh[entry.key] = forms;
		}
	}

	// Glossary terms are pinned in every prompt. A term already in the catalog is
	// kept as is: the repos copy them from Obsidian's official translations, so the
	// model never rewrites one. Only a missing term is translated. A changed term
	// redoes the sentences that use it (glossaryStale).
	async function glossaryFor(
		code: T,
		old: Catalog,
		fresh: Catalog,
	): Promise<Record<string, string>> {
		const terms: Record<string, string> = {};
		for (const key of tr.glossary.filter((k) => used.has(k))) {
			// A repaired or resumed value beats the raw old one.
			const known = fresh[key] ?? old[key];
			const term = typeof known === "string" ? known : await translateOne(code, terms, key);
			if (term) {
				terms[key] = term;
				fresh[key] = term;
			}
		}
		return terms;
	}

	const raw = io.readState();
	// Locales this run does not touch are written back as they were.
	const state: Record<string, StoredState> = { ...raw };
	const results: LocaleResult[] = [];
	// Phase 1, before any model call: plan every locale and write the open bot PR's
	// reusable entries. A run that dies later (timeout, Ollama outage) then still
	// leaves the PR's work in the tree, so the bot PR is not reset to main.
	const plans: {
		code: T;
		fingerprint: string;
		prev: LocaleState | undefined;
		stale: boolean;
		old: Catalog;
		fresh: Catalog;
		todo: Set<string>;
	}[] = [];
	for (const code of opts.targets) {
		const fingerprint = hash(`${tr.fingerprintSource(code)}|${opts.model}|${digest}`);
		const prev = upgradeState(raw[code], fingerprint, opts.legacyVersion, opts.today);
		const stale = opts.all || !prev || prev.translator !== fingerprint;
		const old = await io.loadCatalog(code);
		const fresh: Catalog = {};
		const todo = new Set([
			...todoKeys(entries, old, opts.all, prev, fingerprint),
			...tr.invalidKeys(entries, old, code),
		]);
		// Reuse the open bot PR's work for keys this run would redo anyway, if the same
		// translator built it. Never its entries for other keys: main may have moved.
		// An entry equal to main's old value was carried over, not translated, and a
		// plural built from another English `one` form is stale.
		if (io.resume) {
			const theirs = upgradeState(io.resume.state[code], "", undefined, opts.today);
			if (theirs?.translator === fingerprint) {
				const cat = await io.resume.loadCatalog(code);
				for (const k of todo) {
					const v = cat[k];
					const e = byKey.get(k);
					if (
						v !== undefined &&
						e &&
						!(k in theirs.failed) &&
						JSON.stringify(v) !== JSON.stringify(old[k]) &&
						(!e.plural || theirs.one?.[k] === e.plural.one) &&
						tr.entryProblems(e, v, code).length === 0
					) {
						fresh[k] = v;
					}
				}
			}
		}
		if (Object.keys(fresh).length > 0) {
			io.writeCatalog(code, mergeCatalog(entries, old, fresh));
		}
		plans.push({ code, fingerprint, prev, stale, old, fresh, todo });
	}

	for (const { code, fingerprint, prev, stale, old, fresh, todo } of plans) {
		// An entry a current check rejects but cleanOutput repairs (trimmed edge
		// spaces, bled <0> tokens) needs no model call.
		for (const k of todo) {
			const v = old[k];
			if (k in fresh || typeof v !== "string" || byKey.get(k)?.plural) {
				continue;
			}
			const cleaned = tr.cleanOutput(k, v, code);
			if (!stale && tr.isValid(k, cleaned, code)) {
				fresh[k] = cleaned;
			}
		}
		const terms = await glossaryFor(code, old, fresh);
		// Content redos: the English or a pinned term changed, so the old entry has the
		// old meaning even though it passes every check. Not redone = failed.
		const redo = new Set([
			...oneChangedKeys(entries, prev),
			...glossaryStale(entries, prev?.glossary, terms),
		]);
		for (const k of glossaryStale(entries, prev?.glossary, terms)) {
			todo.add(k);
			delete fresh[k];
		}
		for (const k of todo) {
			if (!(k in fresh || byKey.get(k)?.plural) && tr.isBrandOnly(k)) {
				fresh[k] = k;
			}
		}
		const pending = [...todo].filter((k) => !(k in fresh));
		const strings = pending.filter((k) => !byKey.get(k)?.plural);
		const plurals = pending.flatMap((k) => {
			const e = byKey.get(k);
			return e?.plural ? [e] : [];
		});
		const tasks: (() => Promise<void>)[] = [];
		for (let i = 0; i < strings.length; i += BATCH) {
			tasks.push(() => translateBatch(code, terms, strings.slice(i, i + BATCH), old, fresh));
		}
		for (const e of plurals) {
			tasks.push(() => translatePlural(code, terms, e, fresh));
		}
		await pool(code, tasks);
		const merged = mergeCatalog(entries, old, fresh);
		io.writeCatalog(code, merged);
		const list = [...todo];
		// Failed: still missing or invalid, or a content redo that did not land. A
		// fingerprint redo that could not beat a valid old entry is not a failure.
		const failed = list.filter((k) => {
			const v = merged[k];
			const e = byKey.get(k);
			return (
				v === undefined ||
				!e ||
				tr.entryProblems(e, v, code).length > 0 ||
				(redo.has(k) && !(k in fresh))
			);
		});
		const next = nextLocaleState(failed, entries, prev, fingerprint, terms, opts.today);
		state[code] = next;
		io.writeState(state);
		const result: LocaleResult = {
			code,
			// A pinned glossary term can be in fresh yet invalid: it counts as failed.
			translated: list.filter((k) => k in fresh && !failed.includes(k)).length,
			todo: list.length,
			keptOld: list.filter((k) => !(k in fresh || failed.includes(k))).length,
			failed: failed.length,
			orphans: Object.keys(old).filter((k) => !(k in merged)).length,
			stuck: stuckKeys(next, opts.today, opts.stuckDays),
		};
		io.log(
			`${code}: ${result.translated}/${result.todo} translated, ${result.keptOld} kept old, ${result.failed} failed, ${result.orphans} orphans dropped${result.stuck.length > 0 ? `, ${result.stuck.length} stuck over ${opts.stuckDays} days` : ""}`,
		);
		results.push(result);
	}
	return results;
}

export type { LocaleResult, RunIo, RunOptions };
export { run };
