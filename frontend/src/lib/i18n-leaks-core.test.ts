import { describe, expect, it } from "vitest";
import {
	buildMatchers,
	findKeyLeaks,
	findSuspectStrings,
	isAllowed,
	normalizeText,
	translatedKeys,
} from "../../e2e/support/i18n-leaks-core";

describe("translatedKeys", () => {
	it("keeps only keys whose translation differs, plurals included", () => {
		const keys = translatedKeys({
			Save: "Speichern",
			Name: "Name",
			"{count} files": { one: "{count} Datei", other: "{count} Dateien" },
			"{count} items": { other: "{count} items" },
		});
		expect(keys).toEqual(["Save", "{count} files"]);
	});
});

describe("findKeyLeaks", () => {
	const matchers = buildMatchers(["Save changes", "Hello {name}", "{count} files", "{n}"]);

	it("flags an English key shown as is", () => {
		expect(findKeyLeaks(["Save changes"], matchers)).toEqual([
			{ text: "Save changes", key: "Save changes" },
		]);
	});

	it("matches placeholder keys with a wildcard", () => {
		expect(findKeyLeaks(["Hello Ada", "12 files"], matchers).map((l) => l.key)).toEqual([
			"Hello {name}",
			"{count} files",
		]);
	});

	it("does not flag a translated string or a partial match", () => {
		expect(
			findKeyLeaks(["Änderungen speichern", "Save changes now", "Hallo Ada"], matchers),
		).toEqual([]);
	});

	it("ignores a key made only of placeholders", () => {
		expect(findKeyLeaks(["anything at all"], matchers)).toEqual([]);
	});

	it("never flags allow-listed tokens", () => {
		const m = buildMatchers(["Engram", "MCP"]);
		expect(findKeyLeaks(["Engram", "MCP", "a@b.co", "https://x.io/p", "2026-10-06"], m)).toEqual(
			[],
		);
	});

	it("escapes regex specials in keys", () => {
		const m = buildMatchers(["Done (1) {x}"]);
		expect(findKeyLeaks(["Done (1) ok", "Done 1 ok"], m).map((l) => l.text)).toEqual([
			"Done (1) ok",
		]);
	});
});

describe("findSuspectStrings", () => {
	it("flags ASCII sentences longer than 3 words", () => {
		expect(findSuspectStrings(["Pick a vault to sync", "Sign in"])).toEqual([
			"Pick a vault to sync",
		]);
	});

	it("does not count brands, urls, emails or numbers as words", () => {
		expect(
			findSuspectStrings([
				"Engram Obsidian MCP API Claude Code",
				"mail a@b.co or https://x.io now",
			]),
		).toEqual([]);
	});

	it("ignores strings with non-ASCII text", () => {
		expect(findSuspectStrings(["Engram にサインイン please do it now"])).toEqual([]);
	});
});

describe("helpers", () => {
	it("normalizes whitespace", () => {
		expect(normalizeText("  a \n\t b  ")).toBe("a b");
	});

	it("isAllowed is true only when no language-bearing text is left", () => {
		expect(isAllowed("Engram 3")).toBe(true);
		expect(isAllowed("Engram home")).toBe(false);
	});
});
