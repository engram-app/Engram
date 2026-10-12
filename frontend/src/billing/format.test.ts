import { describe, expect, it } from "vitest";
import type { Translate } from "@/i18n/translate";
import { untranslated } from "@/i18n/ui-text";
import { formatMoney, statusLabel } from "./format";

describe("formatMoney", () => {
	it("formats two-decimal currencies from minor units", () => {
		expect(formatMoney("2000", "USD", "en-US")).toBe("$20.00");
		expect(formatMoney("1234", "USD", "en-US")).toBe("$12.34");
	});

	it("formats zero-decimal currencies without dividing", () => {
		// JPY has no minor unit — 2000 minor units is ¥2,000, not ¥20.
		expect(formatMoney("2000", "JPY", "en-US")).toBe("¥2,000");
	});

	it("returns null for a missing amount", () => {
		expect(formatMoney(null, "USD")).toBeNull();
		expect(formatMoney(undefined, "USD")).toBeNull();
	});

	it("returns null when currency is missing", () => {
		expect(formatMoney("2000", null)).toBeNull();
	});
});

describe("statusLabel", () => {
	const shout: Translate = (en) => untranslated(en.toUpperCase());
	it("translates a known status", () => {
		expect(statusLabel("past_due", shout)).toBe("PAST DUE");
	});
	it("shows a translated generic label, never the wire value, for an unknown status", () => {
		expect(statusLabel("on_hold", shout)).toBe("UNKNOWN");
	});
});
