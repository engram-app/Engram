import type { PostHog } from "posthog-js";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { setAnalyticsClient } from "../analytics/client";
import { reportLanguageDemand, unsupportedLanguages } from "./browser-language";

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
