import { describe, expect, it } from "vitest";
import {
	batchText,
	buildPrompt,
	cleanOutput,
	fromSample,
	HttpError,
	isValid,
	maskPlaceholders,
	mergeCatalog,
	nextLocaleState,
	parseBatch,
	pluralSamples,
	problems,
	TRANSLATOR_VERSION,
	todoKeys,
	unmaskPlaceholders,
	withRetry,
} from "./auto-translate";

describe("cleanOutput", () => {
	it("drops a period the source lacks", () => {
		expect(cleanOutput("All vaults", "Alle Vaults.", "de")).toBe("Alle Vaults");
		expect(cleanOutput("Sync", "同期。", "ja")).toBe("同期");
	});

	it("keeps a period the source has", () => {
		expect(cleanOutput("No matches.", "Keine Treffer.", "de")).toBe("Keine Treffer.");
	});

	it("strips wrapping quotes the source lacks", () => {
		expect(cleanOutput("Revoke", '"Widerrufen"', "de")).toBe("Widerrufen");
	});

	it("removes the space after CJK sentence ends", () => {
		expect(cleanOutput("A. B.", "あ。 い。", "ja")).toBe("あ。い。");
	});

	it("restores newline markers and drops stray ones", () => {
		expect(cleanOutput("a\n\nb", "x ⏎ ⏎ y", "de")).toBe("x\n\ny");
		expect(cleanOutput("Done.", "Fertig. ⏎", "de")).toBe("Fertig.");
	});
});

describe("isValid", () => {
	it("accepts a clean translation", () => {
		expect(isValid("API keys ({total})", "API-Schlüssel ({total})", "de")).toBe(true);
	});

	it("rejects an empty result", () => {
		expect(isValid("Revoke", "", "de")).toBe(false);
	});

	it("allows a placeholder the translation repeats", () => {
		expect(isValid("Disconnect {name}", "Ngắt {name}, {name} sẽ dừng", "vi")).toBe(true);
	});

	it("rejects dropped or invented placeholders", () => {
		expect(isValid("Your {plan} plan", "Ihr Tarif", "de")).toBe(false);
		expect(isValid("Plan", "Tarif {plan}", "de")).toBe(false);
	});

	it("rejects a lost newline", () => {
		expect(isValid("a\nb", "a b", "de")).toBe(false);
	});

	it("rejects a lost URL, code span or brand", () => {
		expect(isValid("See https://engram.page", "Siehe die Seite", "de")).toBe(false);
		expect(isValid("Run `npx x`", "Führe x aus", "de")).toBe(false);
		expect(isValid("Open Obsidian", "Öffne die App", "de")).toBe(false);
	});

	it("rejects a runaway answer", () => {
		expect(isValid("Sync", "Synchronisieren ".repeat(5), "de")).toBe(false);
	});

	it("rejects the wrong register unless the old catalog already used it", () => {
		expect(isValid("Try again.", "Bitte versuchen Sie es erneut.", "de")).toBe(false);
		expect(isValid("Try again.", "Réessayez, vous.", "fr")).toBe(false);
		expect(isValid("Try again.", "Réessayez, vous.", "fr", "Réessayez, vous.")).toBe(true);
		expect(isValid("Your notes", "Твои заметки", "ru")).toBe(false);
	});

	it("rejects output in the wrong script", () => {
		expect(
			isValid("Open a note to insert", "Open the note to insert", "ja", "挿入するノートを開く"),
		).toBe(false);
	});

	it("rejects untranslated English when the old catalog had a translation", () => {
		expect(isValid("Unnamed", "Unnamed", "de", "Ohne Namen")).toBe(false);
		expect(isValid("YouTube", "YouTube", "de", "YouTube")).toBe(true);
	});
});

describe("batchText / parseBatch", () => {
	it("numbers each string and marks newlines", () => {
		expect(batchText(["One", "a\nb"])).toBe("[1] One\n[2] a ⏎ b");
	});

	it("reads [n] and n. numbering, ignoring chatter and out-of-range lines", () => {
		const out = parseBatch("Here you go:\n[1] Eins\n2. Zwei\n[7] Sieben", 2);
		expect(out).toEqual(["Eins", "Zwei"]);
	});

	it("leaves a missing line undefined", () => {
		expect(parseBatch("[2] Zwei", 2)).toEqual([undefined, "Zwei"]);
	});
});

describe("buildPrompt", () => {
	it("states the placeholder rule only when there is one, and never spells out a token", () => {
		// The model copied the rule's own "{placeholder}" into "2 days left" answers.
		const none = buildPrompt("vi", {}, "2 days left in your trial.", false);
		expect(none).not.toMatch(/\{[^}]*\}/u);
		const some = buildPrompt("vi", {}, "Hi {0}", false);
		expect(some).toContain("curly braces");
		expect(some.replace("Hi {0}", "")).not.toMatch(/\{[^}]*\}/u);
	});

	it("pins glossary terms without their emoji, so the model does not paste it into sentences", () => {
		const p = buildPrompt("de", { "🔄 Sync Center": "🔄 Sync-Zentrale" }, "Open it", false);
		expect(p).toContain("Sync Center = Sync-Zentrale");
		expect(p).not.toContain("🔄");
	});

	it("carries glossary, tone and the newline rule only when needed", () => {
		const p = buildPrompt("de", { Vaults: "Vaults" }, "[1] Sync", true);
		expect(p).toContain("German");
		expect(p).toContain("Vaults = Vaults");
		expect(p).toContain("du");
		expect(p).toContain("numbered line");
		expect(p).not.toContain("⏎ marker");
		expect(p.endsWith("[1] Sync")).toBe(true);
		expect(buildPrompt("de", {}, "a ⏎ b", false)).toContain("⏎ marker");
	});
});

describe("pluralSamples / fromSample", () => {
	it("gives one integer per category where one exists", () => {
		expect(pluralSamples("de")).toEqual([
			{ category: "one", sample: "1" },
			{ category: "other", sample: "2" },
		]);
		expect(
			pluralSamples("ru")
				.map((s) => s.category)
				.sort(),
		).toEqual(["few", "many", "one", "other"]);
		expect(pluralSamples("ja")).toEqual([{ category: "other", sample: "2" }]);
		expect(pluralSamples("vi")).toEqual([{ category: "other", sample: "2" }]);
	});

	it("uses a decimal sample for a fraction-only category", () => {
		expect(pluralSamples("ru").find((s) => s.category === "other")?.sample).toBe("1.5");
	});

	it("puts {count} back where the sample number landed", () => {
		expect(fromSample("5 файлов", "5")).toBe("{count} файлов");
		expect(fromSample("1,5 файла", "1.5")).toBe("{count} файла");
	});

	it("refuses when the number is missing or repeated", () => {
		expect(fromSample("файлов", "5")).toBeNull();
		expect(fromSample("5 из 5", "5")).toBeNull();
	});
});

describe("todoKeys", () => {
	const entries = [{ key: "A" }, { key: "B" }, { key: "C" }, { key: "A" }];
	const current = { version: TRANSLATOR_VERSION, failed: [] };

	it("returns only keys the catalog lacks, deduplicated", () => {
		expect(todoKeys(entries, { A: "a", C: "c" }, false, current)).toEqual(["B"]);
	});

	it("retries keys that failed last run", () => {
		expect(
			todoKeys(entries, { A: "a", B: "b", C: "c" }, false, { ...current, failed: ["C"] }),
		).toEqual(["C"]);
	});

	it("ignores a failed key the source no longer uses", () => {
		expect(
			todoKeys(entries, { A: "a", B: "b", C: "c" }, false, { ...current, failed: ["Gone"] }),
		).toEqual([]);
	});

	it("returns every key when the catalog was built by an older translator", () => {
		const stale = { version: TRANSLATOR_VERSION - 1, failed: [] };
		expect(todoKeys(entries, { A: "a", B: "b", C: "c" }, false, stale)).toEqual(["A", "B", "C"]);
		expect(todoKeys(entries, { A: "a", B: "b", C: "c" }, false, undefined)).toEqual([
			"A",
			"B",
			"C",
		]);
	});

	it("retranslates a plural whose English `one` form changed", () => {
		const plural = [
			{ key: "{count} files", plural: { one: "{count} file", other: "{count} files" } },
		];
		const catalog = { "{count} files": { one: "x", other: "y" } };
		const seen = { ...current, one: { "{count} files": "{count} file" } };
		expect(todoKeys(plural, catalog, false, seen)).toEqual([]);
		const edited = { ...current, one: { "{count} files": "one file" } };
		expect(todoKeys(plural, catalog, false, edited)).toEqual(["{count} files"]);
	});

	it("returns every key in --all mode", () => {
		expect(todoKeys(entries, { A: "a" }, true, current)).toEqual(["A", "B", "C"]);
	});
});

describe("nextLocaleState", () => {
	it("stamps the current version and lists what is still untranslated, sorted", () => {
		expect(nextLocaleState(["B", "A", "C"], { C: "c" }, [])).toEqual({
			version: TRANSLATOR_VERSION,
			failed: ["A", "B"],
			one: {},
		});
	});

	it("records the English `one` form of every plural that did not fail", () => {
		const entries = [
			{ key: "{count} files", plural: { one: "{count} file", other: "{count} files" } },
			{ key: "{count} notes", plural: { one: "{count} note", other: "{count} notes" } },
			{ key: "Save" },
		];
		expect(nextLocaleState(["{count} notes"], {}, entries).one).toEqual({
			"{count} files": "{count} file",
		});
	});
});

describe("mergeCatalog", () => {
	it("prefers fresh, falls back to old, drops orphans, follows source order", () => {
		const merged = mergeCatalog(
			[{ key: "B" }, { key: "A" }, { key: "C" }],
			{ A: "old-a", Gone: "x" },
			{ B: "new-b" },
		);
		expect(merged).toEqual({ B: "new-b", A: "old-a" });
		expect(Object.keys(merged)).toEqual(["B", "A"]);
	});
});

describe("problems", () => {
	it("names every failed check", () => {
		expect(problems("Your {plan} plan", "Ihr Tarif", "de")).toEqual(["placeholders", "register"]);
		expect(problems("Open Obsidian", "Öffne die App", "de")).toEqual(["brand"]);
		expect(problems("API keys", "API-Schlüssel", "de")).toEqual([]);
	});

	it("keeps a label's emoji or mark, and adds none to a sentence", () => {
		expect(problems("🔄 Sync Center", "Sync-Zentrale", "de")).toEqual(["symbols"]);
		expect(problems("✓ {count} synced", "{count} synchronisiert", "de")).toEqual(["symbols"]);
		expect(problems("Open sync center", "Buka 🔄 Pusat Sync", "ms")).toEqual(["symbols"]);
		expect(problems("✓ Saved", "✓ Gespeichert", "de")).toEqual([]);
	});

	it("requires the locale's script even with no old entry", () => {
		expect(problems("Open a note to insert", "Open a note to insert it", "ja")).toEqual(["script"]);
		expect(problems("Identity:", "ID:", "ja")).toEqual([]);
		expect(problems("{status}: {message}", "{status}：{message}", "zh-CN")).toEqual([]);
	});
});

describe("maskPlaceholders / unmaskPlaceholders", () => {
	it("swaps names for numbered tokens the model will not translate", () => {
		expect(maskPlaceholders("Vaults ({used} / {cap})")).toEqual({
			masked: "Vaults ({0} / {1})",
			names: ["{used}", "{cap}"],
		});
	});

	it("reuses one token for a repeated name", () => {
		expect(maskPlaceholders("{a} and {a}").masked).toBe("{0} and {0}");
	});

	it("restores names even when the translation reorders them", () => {
		expect(unmaskPlaceholders("{1} / {0}", ["{used}", "{cap}"])).toBe("{cap} / {used}");
	});

	it("leaves a string without placeholders alone", () => {
		expect(maskPlaceholders("Sync")).toEqual({ masked: "Sync", names: [] });
	});
});

describe("withRetry", () => {
	const noSleep = () => Promise.resolve();

	it("retries a transient failure, then returns", async () => {
		let calls = 0;
		const fn = () => {
			calls += 1;
			return calls < 3
				? Promise.reject(new DOMException("timed out", "TimeoutError"))
				: Promise.resolve("ok");
		};
		await expect(withRetry(fn, [1, 1, 1], noSleep)).resolves.toBe("ok");
		expect(calls).toBe(3);
	});

	it("gives up after the last delay and rethrows", async () => {
		let calls = 0;
		const fn = () => {
			calls += 1;
			return Promise.reject(new TypeError("fetch failed"));
		};
		await expect(withRetry(fn, [1, 1], noSleep)).rejects.toThrow("fetch failed");
		expect(calls).toBe(3);
	});

	it("does not retry a permanent failure", async () => {
		let calls = 0;
		const fn = () => {
			calls += 1;
			return Promise.reject(new HttpError(404, "model not found"));
		};
		await expect(withRetry(fn, [1, 1], noSleep)).rejects.toThrow("model not found");
		expect(calls).toBe(1);
	});

	it("retries a server error", async () => {
		let calls = 0;
		const fn = () => {
			calls += 1;
			return calls === 1 ? Promise.reject(new HttpError(503, "busy")) : Promise.resolve("ok");
		};
		await expect(withRetry(fn, [1], noSleep)).resolves.toBe("ok");
	});
});
