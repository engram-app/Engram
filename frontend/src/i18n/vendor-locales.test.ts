import { describe, expect, it } from "vitest";
import { LOCALES } from "./locales";
import { clerkLocalizationLoaders, localizationLoader, paddleLocale } from "./vendor-locales";

// Paddle.Checkout.open settings.locale values, from the Paddle.js docs.
const PADDLE_SUPPORTED = [
	"ar",
	"zh-Hans",
	"zh-TW",
	"da",
	"nl",
	"en",
	"fr",
	"de",
	"it",
	"ja",
	"ko",
	"no",
	"pl",
	"pt",
	"pt-BR",
	"tr",
	"ru",
	"es",
	"sv",
];

describe("paddleLocale", () => {
	it.each(LOCALES)("maps %s into Paddle's supported set", (locale) => {
		expect(PADDLE_SUPPORTED).toContain(paddleLocale(locale));
	});

	it("maps zh-CN to zh-Hans and leaves zh-TW and pt-BR alone", () => {
		expect(paddleLocale("zh-CN")).toBe("zh-Hans");
		expect(paddleLocale("zh-TW")).toBe("zh-TW");
		expect(paddleLocale("pt-BR")).toBe("pt-BR");
	});
});

describe("clerkLocalizationLoaders", () => {
	const nonEnglish = LOCALES.filter((l) => l !== "en");

	it("has no loader for English (Clerk's default)", () => {
		expect(clerkLocalizationLoaders.en).toBeUndefined();
	});

	it.each(nonEnglish)("%s loads a real Clerk catalog", async (locale) => {
		const load = clerkLocalizationLoaders[locale];
		expect(load).toBeDefined();
		const catalog = await load?.();
		expect(Object.keys(catalog ?? {}).length).toBeGreaterThan(0);
	});
});

describe("localizationLoader", () => {
	// vite:preloadError's preventDefault() makes the dynamic import resolve undefined.
	it("resolves undefined, without throwing, when the import resolves nothing", async () => {
		const load = localizationLoader(() => Promise.resolve(undefined), "deDE");
		await expect(load()).resolves.toBeUndefined();
	});

	it("reads the named export from a real module", async () => {
		const catalog = { locale: "de-DE" };
		const load = localizationLoader(() => Promise.resolve({ deDE: catalog }), "deDE");
		await expect(load()).resolves.toBe(catalog);
	});
});
