import { describe, expect, it } from "vitest";
import { LOCALES } from "@/i18n/locales";
import { intlLocale } from "./intl-locale";

describe("intlLocale", () => {
	it("returns the fallback for English", () => {
		expect(intlLocale("en")).toBeUndefined();
		expect(intlLocale("en", "en-US")).toBe("en-US");
	});
	it("returns the locale tag for every other language, ignoring the fallback", () => {
		expect(intlLocale("de", "en-US")).toBe("de");
		expect(intlLocale("pt-BR")).toBe("pt-BR");
		expect(intlLocale("zh-TW", "en-US")).toBe("zh-TW");
	});
	it("yields a tag Intl accepts for every locale", () => {
		for (const locale of LOCALES) {
			const tag = intlLocale(locale, "en-US");
			expect(Intl.DateTimeFormat.supportedLocalesOf(tag ?? "en-US")).toHaveLength(1);
		}
	});
});
