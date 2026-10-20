import type { PostHog } from "posthog-js";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { setAnalyticsClient } from "../analytics/client";
import {
	reportLanguageDemand,
	setDocumentLang,
	unsupportedLanguages,
	watchTranslation,
} from "./browser-language";

vi.mock("../sentry", () => ({ captureError: vi.fn(() => Promise.resolve(undefined)) }));
const posthog = { capture: vi.fn() };

describe("unsupportedLanguages", () => {
	it("keeps only tags no app locale serves, canonicalized and deduped", () => {
		expect(unsupportedLanguages(["ar-eg", "en-US", "AR-EG", "he", "zh-HK", "pt"])).toEqual([
			"ar-EG",
			"he",
		]);
	});

	it("drops tags that are not language tags", () => {
		expect(unsupportedLanguages(["", "not a tag", "x-private"])).toEqual([]);
	});

	it("strips extensions, which are preferences rather than languages", () => {
		expect(unsupportedLanguages(["ar-u-nu-latn", "he-IL-x-work"])).toEqual(["ar", "he-IL"]);
	});
});

// The product wants to know which languages users need that the app cannot
// serve yet: navigator.languages is what the user configured, before any
// browser translation or stored pick.
describe("reportLanguageDemand", () => {
	beforeEach(() => {
		window.localStorage.clear();
		posthog.capture.mockClear();
		setAnalyticsClient(posthog as unknown as PostHog);
	});
	afterEach(() => setAnalyticsClient(null));

	it("sends the unsupported languages once per device", () => {
		reportLanguageDemand(["ar-EG", "en"]);
		reportLanguageDemand(["ar-EG", "en"]);

		expect(posthog.capture).toHaveBeenCalledOnce();
		expect(posthog.capture).toHaveBeenCalledWith("browser_languages_unsupported", {
			languages: ["ar-EG"],
		});
	});

	it("sends again when the set of unsupported languages changes", () => {
		reportLanguageDemand(["ar"]);
		reportLanguageDemand(["ar", "he"]);

		expect(posthog.capture).toHaveBeenCalledTimes(2);
	});

	it("sends nothing when every language is supported", () => {
		reportLanguageDemand(["de-AT", "en-GB"]);
		expect(posthog.capture).not.toHaveBeenCalled();
	});

	// GPC, self-host, or posthog not loaded yet: nothing is sent, so nothing
	// may be marked sent either, or the one report is lost for good.
	it("waits for analytics instead of marking an unsent report", () => {
		setAnalyticsClient(null);
		reportLanguageDemand(["ar"]);
		expect(posthog.capture).not.toHaveBeenCalled();

		setAnalyticsClient(posthog as unknown as PostHog);
		expect(posthog.capture).toHaveBeenCalledOnce();
	});
});

// Browser page translation rewrites the text React owns (the removeChild /
// insertBefore crashes). Chrome marks it on <html>: class translated-ltr/rtl
// and lang set to the target language.
describe("watchTranslation", () => {
	const root = document.documentElement;
	let stop: () => void = () => undefined;
	const onTranslated = vi.fn();

	beforeEach(() => {
		window.sessionStorage.clear();
		posthog.capture.mockClear();
		onTranslated.mockClear();
		setAnalyticsClient(posthog as unknown as PostHog);
		root.className = "";
		setDocumentLang("en");
		stop = watchTranslation(() => "en", onTranslated);
	});
	afterEach(() => {
		stop();
		setAnalyticsClient(null);
	});

	const settle = () => new Promise((r) => setTimeout(r, 0));

	it("detects Chrome's translated class and target lang", async () => {
		root.className = "translated-ltr";
		root.lang = "zh-CN";
		await settle();

		expect(posthog.capture).toHaveBeenCalledOnce();
		expect(posthog.capture).toHaveBeenCalledWith("browser_translation_detected", {
			to: "zh-CN",
			app_locale: "en",
		});
		expect(onTranslated).toHaveBeenCalledWith("zh-CN");
	});

	it("detects a foreign lang write without the class", async () => {
		root.lang = "ar";
		await settle();
		expect(posthog.capture).toHaveBeenCalledWith("browser_translation_detected", {
			to: "ar",
			app_locale: "en",
		});
	});

	it("ignores our own lang writes", async () => {
		setDocumentLang("fr");
		setDocumentLang("de");
		await settle();
		expect(posthog.capture).not.toHaveBeenCalled();
		expect(onTranslated).not.toHaveBeenCalled();
	});

	it("reports each target once per session", async () => {
		root.lang = "ar";
		await settle();
		root.lang = "en";
		setDocumentLang("en");
		await settle();
		root.lang = "ar";
		await settle();
		root.lang = "he";
		await settle();

		expect(posthog.capture.mock.calls.map((c) => c[1].to)).toEqual(["ar", "he"]);
		expect(onTranslated.mock.calls.map((c) => c[0])).toEqual(["ar", "he"]);
	});
});
