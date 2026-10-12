import { describe, expect, it } from "vitest";
import {
	type Catalog,
	type Entry,
	HttpError,
	type Profile,
	type StoredState,
	translator,
} from "./core";
import { type RunIo, type RunOptions, run } from "./run";

type Code = "de" | "fr" | "vi" | "ru";
const profile: Profile<Code> = {
	subject: "a test app",
	specs: {
		de: { name: "German", tone: "du", formal: /\bSie\b/u },
		fr: { name: "French", tone: "tu" },
		vi: { name: "Vietnamese", tone: "bạn" },
		ru: { name: "Russian", tone: "вы" },
	},
	brands: ["Engram"],
	glossary: ["Vault"],
};

// German for each masked English text; anything else comes back unchanged.
const DE: Record<string, string> = {
	Vault: "Tresor",
	Save: "Speichern",
	"Open the vault": "Öffne den Tresor",
	"Delete this note now": "Lösche diese Notiz jetzt",
	"conflicts need resolution": "Konflikte lösen",
	"Sync {0}": "{0} synchronisieren",
	"2 files": "2 Dateien",
	"1 file": "1 Datei",
	"1 note": "Eine Notiz",
	"2 notes": "2 Notizen",
	"{0} files": "{0} tệp",
	"Copied wikilink": "Скопирована вики-ссылка",
	"Copied 21 wikilinks": "Скопирована 21 вики-ссылка",
	"Copied 2 wikilinks": "Скопировано 2 вики-ссылки",
	"Copied 5 wikilinks": "Скопировано 5 вики-ссылок",
	"Copied 1.5 wikilinks": "Скопировано 1,5 вики-ссылки",
};

function fakeOllama(digest = "sha256:aaa") {
	const prompts: string[] = [];
	const fetch: RunIo<Code>["fetch"] = async (url, init) => {
		if (url.endsWith("/api/tags")) {
			return reply({ models: [{ name: "gemma:1", digest }] });
		}
		const { prompt } = JSON.parse(init.body ?? "{}") as { prompt: string };
		prompts.push(prompt);
		const text = prompt.slice(prompt.lastIndexOf("\n\n\n") + 3);
		const answer = text
			.split("\n")
			.map((line) => {
				const m = /^(?<n>\[\d+\] )?(?<t>.*)$/u.exec(line);
				const t = m?.groups?.t ?? "";
				return `${m?.groups?.n ?? ""}${DE[t.trim()] ?? t}`;
			})
			.join("\n");
		return reply({ response: answer });
	};
	return { fetch, prompts };
}

function reply(body: { response?: string; models?: { name: string; digest: string }[] }) {
	return Promise.resolve({
		ok: true,
		status: 200,
		text: () => Promise.resolve(JSON.stringify(body)),
		json: () => Promise.resolve(body),
	});
}

function harness(
	catalogs: Record<string, Catalog>,
	state: Record<string, StoredState> = {},
	extra: Partial<RunIo<Code>> = {},
) {
	const files = { ...catalogs };
	let saved: Record<string, StoredState> = state;
	const io: RunIo<Code> = {
		fetch: fakeOllama().fetch,
		loadCatalog: (code) => Promise.resolve(files[code] ?? {}),
		writeCatalog: (code, c) => {
			files[code] = c;
		},
		readState: () => saved,
		writeState: (s) => {
			saved = JSON.parse(JSON.stringify(s));
		},
		log: () => undefined,
		sleep: () => Promise.resolve(),
		...extra,
	};
	return {
		io,
		files,
		state: () => saved,
	};
}

function opts(entries: Entry[], io: RunIo<Code>, more: Partial<RunOptions<Code>> = {}) {
	return {
		profile,
		targets: ["de"] as readonly Code[],
		entries,
		ollama: "http://ollama",
		model: "gemma:1",
		all: false,
		concurrency: 1,
		requestTimeoutMs: 1000,
		today: "2026-10-12",
		stuckDays: 14,
		io,
		...more,
	};
}

describe("run", () => {
	it("translates only missing keys and stamps the locale", async () => {
		const ollama = fakeOllama();
		const h = harness({ de: { Vault: "Tresor", Save: "Speichern" } }, {}, { fetch: ollama.fetch });
		const entries = [{ key: "Vault" }, { key: "Save" }, { key: "Open the vault" }];
		// No state: first run translates everything, then a second run is a no-op.
		await run(opts(entries, h.io));
		expect(h.files.de).toEqual({
			Vault: "Tresor",
			Save: "Speichern",
			"Open the vault": "Öffne den Tresor",
		});
		const fp = h.state().de?.translator;
		expect(fp).toMatch(/^[0-9a-f]{8}$/u);
		const before = ollama.prompts.length;
		await run(opts([...entries, { key: "Delete this note now" }], h.io));
		expect(ollama.prompts.length - before).toBe(1);
		expect(h.files.de?.["Delete this note now"]).toBe("Lösche diese Notiz jetzt");
		expect(h.state().de?.translator).toBe(fp);
	});

	it("repairs a trimmed edge space without asking the model", async () => {
		const ollama = fakeOllama();
		const h = harness(
			{ de: { " conflicts need resolution": "Konflikte lösen" } },
			{},
			{ fetch: ollama.fetch },
		);
		const entries = [{ key: " conflicts need resolution" }];
		await run(opts(entries, h.io));
		const prompts = ollama.prompts.length;
		h.files.de = { " conflicts need resolution": "Konflikte lösen" };
		await run(opts(entries, h.io));
		expect(h.files.de[" conflicts need resolution"]).toBe(" Konflikte lösen");
		expect(ollama.prompts.length).toBe(prompts);
	});

	it("records a key the model cannot translate, and the gate tolerates it", async () => {
		const h = harness({ de: {} });
		await run(opts([{ key: "Never seen phrase here" }], h.io));
		expect(h.files.de).toEqual({});
		expect(h.state().de?.failed).toEqual({ "Never seen phrase here": "2026-10-12" });
	});

	it("reports a key stuck longer than the limit", async () => {
		const h = harness({ de: {} });
		await run(opts([{ key: "Never seen phrase here" }], h.io, { today: "2026-09-01" }));
		const [result] = await run(
			opts([{ key: "Never seen phrase here" }], h.io, { today: "2026-10-12" }),
		);
		expect(result?.stuck).toEqual(["Never seen phrase here"]);
	});

	it("redoes the locale when the model digest moves", async () => {
		const h = harness({ de: {} });
		await run(opts([{ key: "Save" }], h.io));
		h.files.de = { Save: "Sichern" };
		h.io.fetch = fakeOllama("sha256:bbb").fetch;
		await run(opts([{ key: "Save" }], h.io));
		expect(h.files.de).toEqual({ Save: "Speichern" });
	});

	it("keeps a pinned entry through a full redo, without changing the fingerprint", async () => {
		const h = harness({ de: {} });
		await run(opts([{ key: "Save" }], h.io));
		const fp = h.state().de?.translator;
		h.files.de = { Save: "Sichern" };
		h.io.fetch = fakeOllama("sha256:bbb").fetch;
		const pinned = { ...profile, pinned: { de: ["Save"] } };
		await run(opts([{ key: "Save" }], h.io, { profile: pinned }));
		expect(h.files.de).toEqual({ Save: "Sichern" });
		expect(h.state().de?.failed).toEqual({});
		// Adding a pin must not redo every locale.
		expect(translator(pinned).fingerprintSource("de")).toBe(
			translator(profile).fingerprintSource("de"),
		);
		expect(fp).toMatch(/^[0-9a-f]{8}$/u);
	});

	it("sends a description with its string alone, and redoes the string when it changes", async () => {
		const ollama = fakeOllama();
		const h = harness({ de: { Save: "Sichern", Vault: "Tresor" } }, {}, { fetch: ollama.fetch });
		const entries = [{ key: "Vault" }, { key: "Save" }, { key: "Open the vault" }];
		await run(opts(entries, h.io));
		const described = {
			...profile,
			descriptions: { Save: "Button that writes the note to disk." },
		};
		const before = ollama.prompts.length;
		await run(opts(entries, h.io, { profile: described }));
		const sent = ollama.prompts.slice(before);
		expect(sent).toHaveLength(1);
		expect(sent[0]).toContain("Button that writes the note to disk.");
		expect(sent[0]?.endsWith("\n\n\nSave")).toBe(true);
		expect(h.files.de?.Save).toBe("Speichern");
		// Unchanged description: nothing to redo, and adding one did not move the fingerprint.
		const again = ollama.prompts.length;
		await run(opts(entries, h.io, { profile: described }));
		expect(ollama.prompts.length).toBe(again);
		expect(translator(described).fingerprintSource("de")).toBe(
			translator(profile).fingerprintSource("de"),
		);
	});

	it("reuses the open bot PR's work only for keys this run would translate", async () => {
		const ollama = fakeOllama();
		const h = harness({ de: { Save: "Speichern" } }, {}, { fetch: ollama.fetch });
		await run(opts([{ key: "Save" }], h.io));
		const stamped = h.state();
		const bot = { Save: "Bot-Speichern", "Open the vault": "Bot-Tresor öffnen" };
		h.io.resume = { loadCatalog: () => Promise.resolve(bot), state: stamped };
		const before = ollama.prompts.length;
		await run(opts([{ key: "Save" }, { key: "Open the vault" }], h.io));
		expect(h.files.de).toEqual({ Save: "Speichern", "Open the vault": "Bot-Tresor öffnen" });
		// Only the glossary check ran; the bot's sentence was not retranslated.
		expect(ollama.prompts.length - before).toBe(0);
	});

	it("leaves locales it does not touch exactly as they were", async () => {
		const legacy = { version: 3, failed: ["X"] };
		const h = harness({ de: {} }, { fr: legacy });
		await run(opts([{ key: "Save" }], h.io));
		expect(h.state().fr).toEqual(legacy);
	});

	it("adopts a legacy numbered state once instead of redoing the locale", async () => {
		const ollama = fakeOllama();
		const h = harness(
			{ de: { Save: "Sichern" } },
			{ de: { version: 3, failed: [] } },
			{ fetch: ollama.fetch },
		);
		await run(opts([{ key: "Save" }], h.io, { legacyVersion: 3 }));
		expect(h.files.de).toEqual({ Save: "Sichern" });
		expect(ollama.prompts).toEqual([]);
	});

	it("translates a plural from sample numbers", async () => {
		const h = harness({ de: {} });
		await run(opts([{ key: "{count} files", plural: { one: "{count} file" } }], h.io));
		expect(h.files.de).toEqual({
			"{count} files": { one: "{count} Datei", other: "{count} Dateien" },
		});
	});

	it("accepts a `one` form that spells the number out, where `one` means only 1", async () => {
		const h = harness({ de: {} });
		await run(opts([{ key: "{count} notes", plural: { one: "{count} note" } }], h.io));
		expect(h.files.de).toEqual({
			"{count} notes": { one: "Eine Notiz", other: "{count} Notizen" },
		});
	});

	it("translates a single-form language's plural with {count} as a placeholder", async () => {
		const h = harness({ vi: {} });
		await run(
			opts([{ key: "{count} files", plural: { one: "{count} file" } }], h.io, { targets: ["vi"] }),
		);
		expect(h.files.vi).toEqual({ "{count} files": { other: "{count} tệp" } });
	});

	it("translates `one` from the counted form where it also covers 21", async () => {
		// English "Copied wikilink" has no number, but ru `one` renders 21 too.
		const h = harness({ ru: {} });
		const entry = { key: "Copied {count} wikilinks", plural: { one: "Copied wikilink" } };
		await run(opts([entry], h.io, { targets: ["ru"] }));
		expect(h.files.ru?.["Copied {count} wikilinks"]).toEqual({
			one: "Скопирована {count} вики-ссылка",
			few: "Скопировано {count} вики-ссылки",
			many: "Скопировано {count} вики-ссылок",
			other: "Скопировано {count} вики-ссылки",
		});
		expect(h.state().ru?.failed).toEqual({});
	});

	it("does not reuse a bot entry that only carried main's old value over", async () => {
		const v1 = [{ key: "{count} files", plural: { one: "{count} doc" } }];
		const h = harness({ de: {} });
		DE["1 doc"] = "1 Dok";
		await run(opts(v1, h.io));
		const carried = JSON.parse(JSON.stringify(h.files.de));
		h.io.resume = { loadCatalog: () => Promise.resolve(carried), state: h.state() };
		await run(opts([{ key: "{count} files", plural: { one: "{count} file" } }], h.io));
		expect(h.files.de?.["{count} files"]).toEqual({
			one: "{count} Datei",
			other: "{count} Dateien",
		});
	});

	it("tracks a content redo that failed as failed, so it is retried", async () => {
		const h = harness({ de: {} });
		await run(opts([{ key: "{count} files", plural: { one: "{count} file" } }], h.io));
		// The English singular changes to one the model answers with nothing.
		DE["1 broken file"] = "";
		await run(opts([{ key: "{count} files", plural: { one: "{count} broken file" } }], h.io));
		expect(Object.keys(h.state().de?.failed ?? {})).toEqual(["{count} files"]);
	});

	it("writes the open bot PR's entries for every locale before translating any", async () => {
		const entries = [{ key: "Save" }, { key: "Open the vault" }];
		const h = harness({ de: { Save: "Speichern" }, fr: { Save: "Enregistrer" } });
		await run(opts([{ key: "Save" }], h.io, { targets: ["de", "fr"] }));
		const bot: Record<string, Catalog> = {
			de: { Save: "Speichern", "Open the vault": "Bot-Tresor öffnen" },
			fr: { Save: "Enregistrer", "Open the vault": "Ouvre le coffre" },
		};
		h.io.resume = { loadCatalog: (c) => Promise.resolve(bot[c] ?? {}), state: h.state() };
		// de translates fine; fr's model call dies, as on a CI timeout.
		const base = h.io.fetch;
		h.io.fetch = (url, init) =>
			init.body?.includes("French") ? Promise.reject(new HttpError(400, "boom")) : base(url, init);
		await expect(
			run(opts([...entries, { key: "Delete this note now" }], h.io, { targets: ["de", "fr"] })),
		).rejects.toThrow();
		expect(h.files.fr?.["Open the vault"]).toBe("Ouvre le coffre");
	});

	it("retranslates sentences that use a glossary term whose translation changed", async () => {
		const entries = [{ key: "Vault" }, { key: "Open the vault" }];
		const h = harness({ de: { Vault: "Tresor", "Open the vault": "Öffne den Speicher" } });
		await run(opts(entries, h.io));
		// The state now pins Vault = Tresor; a person changes the term.
		h.files.de = { Vault: "Ablage", "Open the vault": "Öffne den Speicher" };
		await run(opts(entries, h.io));
		expect(h.files.de?.["Open the vault"]).toBe("Öffne den Tresor");
	});
});
