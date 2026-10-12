import { describe, expect, it } from "vitest";
import {
	batchText,
	coreHeaderOk,
	exactOne,
	fromSample,
	glossaryStale,
	HttpError,
	hash,
	mergeCatalog,
	nextLocaleState,
	type Profile,
	parseBatch,
	pluralSamples,
	richLines,
	sourceProblems,
	stuckKeys,
	todoKeys,
	translator,
	upgradeState,
	withRetry,
} from "./core";

const HAN = /\p{Script=Han}/u;
const profile: Profile<"de" | "fr" | "es" | "ja" | "ru" | "vi" | "ms" | "zh"> = {
	subject: "the user interface of Engram",
	specs: {
		de: {
			name: "German",
			tone: "Address the user informally (du, dein), never Sie.",
			formal: /\b(?:Ihr(?:e[nmrs]?)?|Ihnen)\b|[\p{Ll},] Sie\b/u,
		},
		fr: { name: "French", tone: "tu", formal: /\b(?:vous|votre|vos)\b/iu },
		es: { name: "Spanish", tone: "tú" },
		ja: {
			name: "Japanese",
			tone: "polite",
			script: /[\p{Script=Hiragana}\p{Script=Katakana}\p{Script=Han}]/u,
			spaceless: true,
		},
		ru: {
			name: "Russian",
			tone: "вы",
			formal: /(?:^|[^\p{L}])(?:ты|твой|твои)(?![\p{L}])/iu,
			script: /\p{Script=Cyrillic}/u,
		},
		vi: { name: "Vietnamese", tone: "bạn" },
		ms: { name: "Malay", tone: "anda" },
		zh: { name: "Simplified Chinese", tone: "concise", script: HAN, spaceless: true },
	},
	brands: ["Engram Vault Sync", "Engram", "Obsidian", "Starter", "Pro"],
	glossary: ["Vault", "Sync Center"],
};
const tr = translator(profile);

describe("cleanOutput", () => {
	it("drops a period the source lacks and keeps one it has", () => {
		expect(tr.cleanOutput("All vaults", "Alle Vaults.", "de")).toBe("Alle Vaults");
		expect(tr.cleanOutput("Sync", "同期。", "ja")).toBe("同期");
		expect(tr.cleanOutput("No matches.", "Keine Treffer.", "de")).toBe("Keine Treffer.");
	});

	it("strips wrapping quotes the source lacks", () => {
		expect(tr.cleanOutput("Revoke", '"Widerrufen"', "de")).toBe("Widerrufen");
	});

	it("removes the space after CJK sentence ends", () => {
		expect(tr.cleanOutput("A. B.", "あ。 い。", "ja")).toBe("あ。い。");
	});

	it("restores newline markers and drops stray ones", () => {
		expect(tr.cleanOutput("a\n\nb", "x ⏎ ⏎ y", "de")).toBe("x\n\ny");
		expect(tr.cleanOutput("Done.", "Fertig. ⏎", "de")).toBe("Fertig.");
	});

	it("puts back the source's edge spaces, which join it to its neighbours", () => {
		expect(tr.cleanOutput(" conflicts need resolution", "Konflikte lösen", "de")).toBe(
			" Konflikte lösen",
		);
		expect(tr.cleanOutput("Your account at ", "Dein Konto bei", "de")).toBe("Dein Konto bei ");
		expect(tr.cleanOutput(" conflicts", "个冲突", "zh")).toBe("个冲突");
	});

	it("drops numbered tags bled from a neighbour line", () => {
		expect(tr.cleanOutput("Getting Started", "<0>Erste Schritte</0>", "de")).toBe("Erste Schritte");
	});
});

describe("problems", () => {
	it("names every failed check", () => {
		expect(tr.problems("Your {plan} plan", "Ihr Tarif", "de")).toEqual([
			"placeholders",
			"register",
		]);
		expect(tr.problems("Open Obsidian", "Öffne die App", "de")).toEqual(["brand"]);
		expect(tr.problems("API keys", "API-Schlüssel", "de")).toEqual([]);
	});

	it("allows a repeated placeholder, rejects a dropped or invented one", () => {
		expect(tr.problems("Disconnect {name}", "Ngắt {name}, {name} sẽ dừng", "vi")).toEqual([]);
		expect(tr.problems("Plan", "Tarif {plan}", "de")).toEqual(["placeholders"]);
	});

	it("rejects a lost newline, URL or code span, and an empty or runaway answer", () => {
		expect(tr.problems("a\nb", "a b", "de")).toContain("newlines");
		expect(tr.problems("See https://engram.page", "Siehe die Seite", "de")).toContain("literal");
		expect(tr.problems("Run `npx x`", "Führe x aus", "de")).toContain("literal");
		expect(tr.problems("Revoke", "", "de")).toContain("empty");
		expect(tr.problems("Sync", "Synchronisieren ".repeat(5).trim(), "de")).toContain("length");
	});

	it("keeps plan names untranslated, whole words only, inflection allowed", () => {
		expect(tr.problems("Upgrade to Pro", "Actualiza a Profesional", "es")).toEqual(["brand"]);
		expect(tr.problems("Upgrade to Pro", "Actualiza a Pro", "es")).toEqual([]);
		expect(tr.problems("Pro", "Pro版", "zh")).toEqual([]);
		expect(tr.problems("Edit profile", "Editar perfil", "es")).toEqual([]);
		expect(tr.problems("Obsidian's flavour", "Obsidians Stil", "de")).toEqual([]);
	});

	it("keeps a label's emoji or mark, and adds none to a sentence", () => {
		expect(tr.problems("🔄 Sync Center", "Sync-Zentrale", "de")).toEqual(["symbols"]);
		expect(tr.problems("Open sync center", "Buka 🔄 Pusat Sync", "ms")).toEqual(["symbols"]);
		expect(tr.problems("✓ Saved", "✓ Gespeichert", "de")).toEqual([]);
		expect(tr.problems("12 notes · 3 files", "12 Notizen, 3 Dateien", "de")).toEqual(["symbols"]);
		expect(tr.problems("en·gram: a memory unit", "engrama: uma unidade de memória", "es")).toEqual(
			[],
		);
	});

	it("requires the locale's script in a sentence, not in a short label", () => {
		expect(tr.problems("Open a note to insert", "Open a note to insert it", "ja")).toEqual([
			"script",
		]);
		expect(tr.problems("Identity:", "ID:", "ja")).toEqual([]);
	});

	it("never waives a check for an old entry that failed it too", () => {
		// The gate has no `old`; a waiver would let the translator write what it rejects.
		expect(tr.problems("Try again.", "Réessayez, vous.", "fr", "Réessayez, vous.")).toEqual([
			"register",
		]);
		expect(tr.problems("Open a note to insert", "Open the note", "ja", "Open it")).toContain(
			"script",
		);
	});

	it("rejects lost edge spaces, except in spaceless scripts", () => {
		expect(tr.problems(" conflicts", "Konflikte", "de")).toEqual(["edges"]);
		expect(tr.problems("at ", "bei", "de")).toEqual(["edges"]);
		expect(tr.problems(" conflicts", "个冲突", "zh")).toEqual([]);
	});

	it("rejects an English phrase echoed back, a lone word only over a real translation", () => {
		expect(tr.problems("Open the vault folder", "Open the vault folder", "de")).toEqual([
			"untranslated",
		]);
		expect(tr.problems("Status", "Status", "de")).toEqual([]);
		expect(tr.problems("Unnamed", "Unnamed", "de", "Ohne Namen")).toEqual(["untranslated"]);
		expect(
			tr.problems("Engram Vault Sync for Obsidian", "Engram Vault Sync for Obsidian", "de"),
		).toEqual([]);
	});

	it("keeps every number but a lone 1, which a language may spell out", () => {
		// The model once put a placeholder where the plural sample "2" was.
		expect(tr.problems("2 of {indexed} notes", "{indexed} 件のうち {indexed} 件", "ja")).toEqual([
			"numbers",
		]);
		expect(tr.problems("2 of {indexed} notes", "{indexed} 件のうち 2 件", "ja")).toEqual([]);
		expect(tr.problems("1 of your notes", "Eine deiner Notizen", "de")).toEqual([]);
		expect(tr.problems("2,000 notes", "2.000 Notizen", "de")).toEqual([]);
		expect(tr.problems("3-way merge", "трёхстороннее слияние", "ru")).toEqual([]);
		expect(tr.problems("A CodeMirror 6 editor", "Ein CodeMirror 6-Editor", "de")).toEqual([]);
		expect(tr.problems("2,000 notes", "2 000 notes", "fr")).not.toContain("numbers");
	});

	it("sees tags with capital or non-Latin names the model invented", () => {
		// Live on the marketing site: "<Engram> 对比", "<보유한> 폴더".
		expect(tr.problems("Engram vs Relay", "<Engram> 对比 Relay", "zh")).toContain("tags");
		expect(tr.problems("Your folders", "<보유한> 폴더", "ja")).toContain("tags");
	});

	it("unwraps angle brackets the model put around words in untagged copy", () => {
		expect(tr.cleanOutput("Claude today", "今天使用 <Claude>", "zh")).toBe("今天使用 Claude");
		expect(tr.cleanOutput("Read <b>this</b>", "Lies <b>das</b>", "de")).toBe("Lies <b>das</b>");
	});

	it("strips wrapping guillemets the source lacks", () => {
		expect(tr.cleanOutput("Save", "«Enregistrer»", "fr")).toBe("Enregistrer");
	});

	it("keeps tags and rejects numbered tokens the model invented", () => {
		expect(tr.problems("Read <b>this</b>", "Lies <b>das</b>", "de")).toEqual([]);
		expect(tr.problems("Read <b>this</b>", "Lies das", "de")).toEqual(["tags"]);
		expect(tr.problems("FAQ", "<0>FAQ</0>", "de")).toContain("stray");
	});
});

describe("isBrandOnly", () => {
	it("is true when nothing but brands, placeholders and punctuation remains", () => {
		expect(tr.isBrandOnly("Pro")).toBe(true);
		expect(tr.isBrandOnly("{plan} Pro")).toBe(true);
		expect(tr.isBrandOnly("Upgrade to Pro")).toBe(false);
	});
});

describe("entryProblems / invalidKeys / catalogProblems", () => {
	const plural = { key: "{count} files", plural: { one: "{count} file" } };

	it("checks every plural category of the locale, and the shape", () => {
		expect(
			tr.entryProblems(plural, { one: "{count} Datei", other: "{count} Dateien" }, "de"),
		).toEqual([]);
		expect(tr.entryProblems(plural, { other: "{count} Dateien" }, "de")).toEqual(["shape"]);
		expect(tr.entryProblems(plural, "{count} 個のファイル", "ja")).toEqual([]);
		expect(tr.entryProblems({ key: "Save" }, { other: "x" }, "de")).toEqual(["shape"]);
	});

	it("lets only an exact-one `one` form drop {count}", () => {
		// ru `one` also renders 21, so "Одна заметка" would read "one note" for 21.
		expect(
			tr.entryProblems(
				plural,
				{ one: "Один файл", few: "{count} файла", many: "{count} файлов", other: "{count} файла" },
				"ru",
			),
		).toEqual(["count"]);
		expect(tr.entryProblems(plural, { other: "ファイル" }, "ja")).toEqual(["count"]);
	});

	it("lets a plural form drop {count}, not invent one", () => {
		expect(tr.entryProblems(plural, { one: "eine Datei", other: "{count} Dateien" }, "de")).toEqual(
			[],
		);
		expect(tr.entryProblems(plural, { one: "{n} Datei", other: "{count} Dateien" }, "de")).toEqual([
			"placeholders",
		]);
	});

	it("lists committed entries that fail a current check", () => {
		const entries = [{ key: "Upgrade to Pro" }, { key: "Save" }, { key: "Gone" }];
		expect(
			tr.invalidKeys(
				entries,
				{ "Upgrade to Pro": "Actualiza a Profesional", Save: "Guardar" },
				"es",
			),
		).toEqual(["Upgrade to Pro"]);
	});

	it("gates missing, invalid and orphan entries, tolerating only tracked failures", () => {
		const entries = [{ key: "Save" }, { key: "Upgrade to Pro" }, { key: "Hard one" }];
		const catalog = { Save: "Guardar", "Upgrade to Pro": "Actualiza a Profesional", Old: "x" };
		expect(tr.catalogProblems(entries, catalog, "es", undefined)).toEqual([
			'es: brand in "Upgrade to Pro"',
			'es: missing "Hard one"',
			'es: orphan "Old"',
		]);
		const state = {
			translator: "x",
			failed: { "Upgrade to Pro": "2026-10-01", "Hard one": "2026-10-01" },
		};
		expect(tr.catalogProblems(entries, catalog, "es", state)).toEqual(['es: orphan "Old"']);
	});
});

describe("mask / unmask", () => {
	it("swaps placeholders, brands and tags for numbered tokens", () => {
		expect(tr.mask("Vaults ({used} / {cap})")).toEqual({
			masked: "Vaults ({0} / {1})",
			names: ["{used}", "{cap}"],
		});
		expect(tr.mask("Open {path} in Obsidian")).toEqual({
			masked: "Open {0} in {1}",
			names: ["{path}", "Obsidian"],
		});
		expect(tr.mask("Read <a href='x'>docs</a>")).toEqual({
			masked: "Read <0>docs</0>",
			names: ["<a href='x'>"],
		});
		expect(tr.mask("Edit profile").masked).toBe("Edit profile");
		expect(tr.mask("Engram Vault Sync").names).toEqual(["Engram Vault Sync"]);
	});

	it("reuses one token for a repeated name and restores reordered ones", () => {
		expect(tr.mask("{a} and {a}").masked).toBe("{0} and {0}");
		expect(tr.unmask("{1} / {0}", ["{used}", "{cap}"])).toBe("{cap} / {used}");
		expect(tr.unmask("选择{0}", ["Starter"])).toBe("选择Starter");
		expect(tr.unmask("Lies <0>Doku</0>", ["<a href='x'>"])).toBe("Lies <a href='x'>Doku</a>");
	});
});

describe("buildPrompt", () => {
	it("states token rules only when needed and never spells out a token", () => {
		const none = tr.buildPrompt("vi", {}, "2 days left in your trial.", false);
		expect(none).not.toMatch(/\{[^}]*\}/u);
		expect(none).not.toContain("angle brackets");
		expect(tr.buildPrompt("vi", {}, "Hi {0}", false)).toContain("curly braces");
		expect(tr.buildPrompt("vi", {}, "Hi <0>x</0>", false)).toContain("angle brackets");
		expect(tr.buildPrompt("de", {}, "a ⏎ b", false)).toContain("⏎ marker");
	});

	it("pins glossary terms without their emoji", () => {
		const p = tr.buildPrompt("de", { "🔄 Sync Center": "🔄 Sync-Zentrale" }, "Open it", false);
		expect(p).toContain("Sync Center = Sync-Zentrale");
		expect(p).not.toContain("🔄");
		expect(p).toContain("localizing the user interface of Engram.");
	});
});

describe("fingerprintSource", () => {
	it("moves when the tone, brands or glossary change, not otherwise", () => {
		const base = tr.fingerprintSource("de");
		expect(translator(profile).fingerprintSource("de")).toBe(base);
		const tone = translator({
			...profile,
			specs: { ...profile.specs, de: { ...profile.specs.de, tone: "Sie" } },
		});
		expect(tone.fingerprintSource("de")).not.toBe(base);
		expect(translator({ ...profile, brands: ["Engram"] }).fingerprintSource("de")).not.toBe(base);
		expect(translator({ ...profile, glossary: ["Vault"] }).fingerprintSource("de")).not.toBe(base);
	});
});

describe("batchText / parseBatch", () => {
	it("numbers each string and marks newlines", () => {
		expect(batchText(["One", "a\nb"])).toBe("[1] One\n[2] a ⏎ b");
	});

	it("reads [n] and n. numbering, ignoring chatter and out-of-range lines", () => {
		expect(parseBatch("Here you go:\n[1] Eins\n2. Zwei\n[7] Sieben", 2)).toEqual(["Eins", "Zwei"]);
		expect(parseBatch("[2] Zwei", 2)).toEqual([undefined, "Zwei"]);
	});
});

describe("pluralSamples / fromSample", () => {
	it("gives one integer per category, a decimal for a fraction-only one", () => {
		expect(pluralSamples("de")).toEqual([
			{ category: "one", sample: "1" },
			{ category: "other", sample: "2" },
		]);
		expect(pluralSamples("ru").find((s) => s.category === "other")?.sample).toBe("1.5");
		expect(pluralSamples("ja")).toEqual([{ category: "other", sample: "2" }]);
	});

	it("samples `many` with a million where only big numbers use it (pt, fr)", () => {
		expect(pluralSamples("pt").find((s) => s.category === "many")?.sample).toBe("1000000");
		expect(pluralSamples("fr").find((s) => s.category === "many")?.sample).toBe("1000000");
	});

	it("samples `one` with 21 where it covers more than 1, so the number must stay", () => {
		expect(pluralSamples("ru").find((s) => s.category === "one")?.sample).toBe("21");
		expect(pluralSamples("de").find((s) => s.category === "one")?.sample).toBe("1");
	});

	it("puts {count} back where the one sample number landed", () => {
		expect(fromSample("5 файлов", "5")).toBe("{count} файлов");
		expect(fromSample("1,5 файла", "1.5")).toBe("{count} файла");
		expect(fromSample("1. 5 файла", "1.5")).toBe("{count} файла");
		expect(fromSample("1.000.000 de arquivos", "1000000")).toBe("{count} de arquivos");
		expect(fromSample("1 000 000 fichiers", "1000000")).toBe("{count} fichiers");
		expect(fromSample("файлов", "5")).toBeNull();
		expect(fromSample("5 из 5", "5")).toBeNull();
	});
});

describe("exactOne", () => {
	it("is true where `one` means only the number 1", () => {
		expect(exactOne("de")).toBe(true);
		expect(exactOne("ru")).toBe(false);
		// pt `one` is 0 and 1.
		expect(exactOne("pt")).toBe(false);
		expect(exactOne("ja")).toBe(false);
	});
});

describe("sourceProblems", () => {
	it("flags a plural whose key has no {count}, since no form can be sampled", () => {
		expect(sourceProblems([{ key: "{n} notes", plural: { one: "{n} note" } }])).toHaveLength(1);
		expect(sourceProblems([{ key: "{count} notes", plural: { one: "{count} note" } }])).toEqual([]);
	});
});

describe("state", () => {
	const entries = [{ key: "A" }, { key: "B" }, { key: "C" }, { key: "A" }];
	const current = { translator: "fp", failed: {} };

	it("todoKeys: only missing keys, deduplicated, plus failed ones", () => {
		expect(todoKeys(entries, { A: "a", C: "c" }, false, current, "fp")).toEqual(["B"]);
		expect(
			todoKeys(
				entries,
				{ A: "a", B: "b", C: "c" },
				false,
				{ ...current, failed: { C: "d" } },
				"fp",
			),
		).toEqual(["C"]);
	});

	it("todoKeys: every key when the fingerprint moved, there is no state, or --all", () => {
		const all = ["A", "B", "C"];
		expect(todoKeys(entries, { A: "a", B: "b", C: "c" }, false, current, "other")).toEqual(all);
		expect(todoKeys(entries, { A: "a" }, false, undefined, "fp")).toEqual(all);
		expect(todoKeys(entries, { A: "a" }, true, current, "fp")).toEqual(all);
	});

	it("todoKeys: a plural whose English `one` form changed", () => {
		const plural = [{ key: "{count} files", plural: { one: "{count} file" } }];
		const catalog = { "{count} files": { one: "x", other: "y" } };
		expect(
			todoKeys(
				plural,
				catalog,
				false,
				{ ...current, one: { "{count} files": "{count} file" } },
				"fp",
			),
		).toEqual([]);
		expect(
			todoKeys(plural, catalog, false, { ...current, one: { "{count} files": "one file" } }, "fp"),
		).toEqual(["{count} files"]);
	});

	it("nextLocaleState keeps the day a key first failed", () => {
		const prev = { translator: "old", failed: { A: "2026-09-01" } };
		expect(nextLocaleState(["B", "A"], [], prev, "fp", { Vault: "Tresor" }, "2026-10-12")).toEqual({
			translator: "fp",
			failed: { A: "2026-09-01", B: "2026-10-12" },
			one: {},
			glossary: { Vault: "Tresor" },
		});
	});

	it("stuckKeys lists failures older than the limit", () => {
		const s = { translator: "fp", failed: { A: "2026-09-01", B: "2026-10-10" } };
		expect(stuckKeys(s, "2026-10-12", 14)).toEqual(["A"]);
	});

	it("upgradeState adopts the repo's last numbered version once, else marks it stale", () => {
		const legacy = { version: 3, failed: ["X"] };
		expect(upgradeState(legacy, "fp", 3, "2026-10-12")).toEqual({
			translator: "fp",
			failed: { X: "2026-10-12" },
			one: undefined,
			glossary: undefined,
		});
		expect(upgradeState(legacy, "fp", 4, "2026-10-12")?.translator).toBe("legacy");
		expect(upgradeState(undefined, "fp", 3, "2026-10-12")).toBeUndefined();
	});

	it("glossaryStale lists sentences that use a term whose translation changed", () => {
		const e = [{ key: "Vault" }, { key: "Open the vault" }, { key: "Vaulting" }, { key: "Sync" }];
		expect(glossaryStale(e, { Vault: "Tresor" }, { Vault: "Vault" })).toEqual(["Open the vault"]);
		expect(glossaryStale(e, { Vault: "Tresor" }, { Vault: "Tresor" })).toEqual([]);
		expect(glossaryStale(e, undefined, { Vault: "Vault" })).toEqual([]);
	});

	it("mergeCatalog prefers fresh, falls back to old, drops orphans, follows source order", () => {
		const merged = mergeCatalog(
			[{ key: "B" }, { key: "A" }, { key: "C" }],
			{ A: "old-a", Gone: "x" },
			{ B: "new-b" },
		);
		expect(Object.entries(merged)).toEqual([
			["B", "new-b"],
			["A", "old-a"],
		]);
	});
});

describe("richLines", () => {
	it("splits headline copy into plain lines and rebuilds the markup", () => {
		const split = richLines("Yours to own.<br /><primary>Yours to leave.</primary>");
		expect(split?.inner).toEqual(["Yours to own.", "Yours to leave."]);
		expect(split?.join(["A.", "B."])).toBe("A.<br /><primary>B.</primary>");
		expect(richLines("Plain")).toBeNull();
		expect(richLines("Mid <b>tag</b> line")).toBeNull();
	});
});

describe("coreHeaderOk / hash", () => {
	it("accepts a header that hashes the rest of the file, rejects an edited copy", () => {
		const body = "const a = 1;\n";
		expect(coreHeaderOk(`// i18n-core ${hash(body)}\n${body}`)).toBe(true);
		expect(coreHeaderOk(`// i18n-core ${hash(body)}\nconst a = 2;\n`)).toBe(false);
		expect(coreHeaderOk(body)).toBe(false);
	});
});

describe("withRetry", () => {
	const noSleep = () => Promise.resolve();

	it("retries a transient failure, then returns", async () => {
		let calls = 0;
		const fn = () => {
			calls += 1;
			return calls < 3 ? Promise.reject(new TypeError("fetch failed")) : Promise.resolve("ok");
		};
		await expect(withRetry(fn, [1, 1, 1], noSleep)).resolves.toBe("ok");
		expect(calls).toBe(3);
	});

	it("gives up after the last delay, and never retries a 4xx", async () => {
		let calls = 0;
		await expect(
			withRetry(
				() => {
					calls += 1;
					return Promise.reject(new TypeError("fetch failed"));
				},
				[1, 1],
				noSleep,
			),
		).rejects.toThrow("fetch failed");
		expect(calls).toBe(3);
		calls = 0;
		await expect(
			withRetry(
				() => {
					calls += 1;
					return Promise.reject(new HttpError(404, "model not found"));
				},
				[1, 1],
				noSleep,
			),
		).rejects.toThrow("model not found");
		expect(calls).toBe(1);
	});
});
