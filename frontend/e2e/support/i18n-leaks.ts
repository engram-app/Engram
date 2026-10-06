import { expect, type Page, type TestInfo } from "@playwright/test";
import de from "../../src/i18n/locale/de";
import es from "../../src/i18n/locale/es";
import fr from "../../src/i18n/locale/fr";
import it from "../../src/i18n/locale/it";
import ja from "../../src/i18n/locale/ja";
import ko from "../../src/i18n/locale/ko";
import ptBR from "../../src/i18n/locale/pt-BR";
import ru from "../../src/i18n/locale/ru";
import zhCN from "../../src/i18n/locale/zh-CN";
import zhTW from "../../src/i18n/locale/zh-TW";
import {
	buildMatchers,
	type CatalogLike,
	findKeyLeaks,
	findSuspectStrings,
	type KeyMatcher,
	type Leak,
	NON_LATIN_LOCALES,
	normalizeText,
	translatedKeys,
} from "./i18n-leaks-core";

interface VisibleTextOptions {
	// CSS selector of subtrees to skip (text and attributes inside are ignored).
	excludeSelector?: string;
}

interface StepOptions {
	// Skip Clerk's own subtree: Clerk localizes it, not us.
	skipClerk?: boolean;
}

// Clerk renders (and localizes) its own components; the SPA's catalogs do not cover them.
const CLERK_ROOT = ".cl-rootBox";

const CATALOGS: Record<string, CatalogLike> = {
	de,
	es,
	fr,
	it,
	ja,
	ko,
	"pt-BR": ptBR,
	ru,
	"zh-CN": zhCN,
	"zh-TW": zhTW,
};

// Browser locale tag -> the app locale code it must resolve to.
const BROWSER_LOCALES = [
	{ tag: "de-DE", code: "de" },
	{ tag: "es-ES", code: "es" },
	{ tag: "fr-FR", code: "fr" },
	{ tag: "it-IT", code: "it" },
	{ tag: "ja-JP", code: "ja" },
	{ tag: "ko-KR", code: "ko" },
	{ tag: "pt-BR", code: "pt-BR" },
	{ tag: "ru-RU", code: "ru" },
	{ tag: "zh-CN", code: "zh-CN" },
	{ tag: "zh-TW", code: "zh-TW" },
] as const;

// The catalog's string for an English key; throws when the locale has none, so a
// renamed key fails the spec loudly instead of asserting on English.
function translationOf(locale: string, key: string): string {
	const entry = CATALOGS[locale]?.[key];
	if (typeof entry !== "string") {
		throw new Error(`no string translation of ${JSON.stringify(key)} in ${locale}`);
	}
	return entry;
}

const matcherCache = new Map<string, KeyMatcher[]>();

function matchersFor(locale: string): KeyMatcher[] {
	const cached = matcherCache.get(locale);
	if (cached) {
		return cached;
	}
	const built = buildMatchers(translatedKeys(CATALOGS[locale] ?? {}));
	matcherCache.set(locale, built);
	return built;
}

// Every visible leaf text node plus the placeholder / aria-label / title / alt
// values of visible elements, whitespace-normalized and de-duplicated.
export async function collectVisibleText(
	page: Page,
	options: VisibleTextOptions = {},
): Promise<string[]> {
	const raw = await page.evaluate((exclude) => {
		const SKIPPED_TAGS = new Set(["SCRIPT", "STYLE", "NOSCRIPT"]);
		const ATTRIBUTES = ["placeholder", "aria-label", "title", "alt"];
		const out: string[] = [];

		const shown = (el: Element): boolean => {
			if (!el.checkVisibility({ checkVisibilityCSS: true })) {
				return false;
			}
			const rect = el.getBoundingClientRect();
			return rect.width > 0 && rect.height > 0;
		};
		const skipped = (el: Element): boolean =>
			SKIPPED_TAGS.has(el.tagName) || (exclude !== "" && el.closest(exclude) !== null);

		const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
		for (let node = walker.nextNode(); node; node = walker.nextNode()) {
			const parent = node.parentElement;
			if (parent && !skipped(parent) && !parent.closest("script,style,noscript") && shown(parent)) {
				out.push(node.textContent ?? "");
			}
		}
		for (const el of document.body.querySelectorAll("[placeholder],[aria-label],[title],[alt]")) {
			if (skipped(el) || !shown(el)) {
				continue;
			}
			for (const name of ATTRIBUTES) {
				const value = el.getAttribute(name);
				if (value) {
					out.push(value);
				}
			}
		}
		return out;
	}, options.excludeSelector ?? "");
	return [...new Set(raw.map(normalizeText).filter((text) => text !== ""))];
}

// Visible strings equal to an English key that `locale`'s catalog translates.
export async function findLeaks(
	page: Page,
	locale: string,
	options: VisibleTextOptions = {},
): Promise<Leak[]> {
	return findKeyLeaks(await collectVisibleText(page, options), matchersFor(locale));
}

// Plain-ASCII sentences visible in a non-Latin locale: unwrapped English. Empty for
// Latin-script locales, where English cannot be told apart by script.
export async function findSuspectEnglish(
	page: Page,
	locale: string,
	options: VisibleTextOptions = {},
): Promise<string[]> {
	if (!NON_LATIN_LOCALES.some((code) => code === locale)) {
		return [];
	}
	return findSuspectStrings(await collectVisibleText(page, options));
}

// One onboarding step: `<html lang>` is the locale, no leaks, suspects reported,
// full-page screenshot attached as `<locale>-<step>`. Callers wait for the step's
// own heading first so the page is settled.
export async function checkStep(
	page: Page,
	testInfo: TestInfo,
	locale: string,
	step: string,
	options: StepOptions = {},
): Promise<void> {
	await expect(page.locator("html")).toHaveAttribute("lang", locale);
	const scope = options.skipClerk ? { excludeSelector: CLERK_ROOT } : {};
	const leaks = await findLeaks(page, locale, scope);
	const suspects = await findSuspectEnglish(page, locale, scope);
	const name = `${locale}-${step}`;

	await testInfo.attach(name, {
		body: await page.screenshot({ fullPage: true }),
		contentType: "image/png",
	});
	await testInfo.attach(`${name}-findings`, {
		body: JSON.stringify({ locale, step, url: page.url(), leaks, suspects }, null, 2),
		contentType: "application/json",
	});
	if (suspects.length > 0) {
		testInfo.annotations.push({ type: `i18n-suspects ${name}`, description: suspects.join(" | ") });
	}
	// Soft: one leaking step must not hide the leaks on the steps after it.
	expect.soft(leaks, `untranslated wrapped strings on ${name} (${page.url()})`).toEqual([]);
}

export type { StepOptions, VisibleTextOptions };
export { BROWSER_LOCALES, CATALOGS, translationOf };
