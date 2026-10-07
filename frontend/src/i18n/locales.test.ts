import { describe, expect, it } from "vitest";
import { matchLocale, resolveLocale } from "./locales";

describe("matchLocale", () => {
	it.each([
		["de-DE", "de"],
		["DE", "de"],
		["pt-br", "pt-BR"],
		["pt-PT", "pt-BR"],
		["pt", "pt-BR"],
		["zh", "zh-CN"],
		["zh-Hans", "zh-CN"],
		["zh-SG", "zh-CN"],
		["zh-TW", "zh-TW"],
		["zh-HK", "zh-TW"],
		["zh-Hant-HK", "zh-TW"],
		["en-GB", "en"],
		["ja-JP", "ja"],
	])("%s -> %s", (tag, expected) => {
		expect(matchLocale(tag)).toBe(expected);
	});

	it.each(["xx", "", "-", "klingon"])("rejects %j", (tag) => {
		expect(matchLocale(tag)).toBeNull();
	});
});

describe("resolveLocale", () => {
	it("takes the first supported tag", () => {
		expect(resolveLocale(["xx", "fr-CA", "de"])).toBe("fr");
	});
	it("falls back to en for an empty list", () => {
		expect(resolveLocale([])).toBe("en");
	});
	it("falls back to en when nothing matches", () => {
		expect(resolveLocale(["", "xx"])).toBe("en");
	});
});
