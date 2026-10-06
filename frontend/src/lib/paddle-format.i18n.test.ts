import { describe, expect, it } from "vitest";
import type { Tn, Translate } from "@/i18n/translate";
import { translate, translatePlural } from "@/i18n/translate";
import { intlLocale } from "./intl-locale";
import {
	formatBillingCycle,
	formatDate,
	formatIntervalLabel,
	formatMoney,
	formatProrationMode,
} from "./paddle-format";
import { getPaymentMethodDisplay } from "./paddle-payment-method-display";

const t: Translate = (en, vars) => translate({}, en, vars);
const tn: Tn = (en, count, vars) => translatePlural({}, "en", en, count, vars);

describe("paddle display helpers take t", () => {
	it("formats billing cycles singular and plural", () => {
		expect(formatBillingCycle({ frequency: 1, interval: "month" }, t, tn)).toBe("month");
		expect(formatBillingCycle({ frequency: 3, interval: "month" }, t, tn)).toBe("3 months");
		expect(formatBillingCycle({ frequency: 2, interval: "fortnight" }, t, tn)).toBe("2 fortnights");
		expect(formatBillingCycle(null, t, tn)).toBeUndefined();
	});

	it("routes interval and proration labels through the translator", () => {
		const shout: Translate = (en) => en.toUpperCase();
		expect(formatIntervalLabel("year", shout, "adjective")).toBe("ANNUAL");
		expect(formatProrationMode("do_not_bill", shout)).toBe("NO CHARGE");
		expect(formatProrationMode("mystery", shout)).toBe("mystery");
	});

	it("keeps brand names untranslated and translates generic labels", () => {
		const shout: Translate = (en, vars) => translate({}, en.toUpperCase(), vars);
		expect(getPaymentMethodDisplay(shout, "paypal")).toBe("PayPal");
		expect(getPaymentMethodDisplay(shout, "wire_transfer")).toBe("WIRE TRANSFER");
		expect(getPaymentMethodDisplay(t, "card", "visa", "4242")).toBe("Visa ending 4242");
		expect(getPaymentMethodDisplay(t, "card")).toBe("Card");
	});
});

describe("dates and money follow the app language", () => {
	const iso = "2026-10-06T12:00:00Z";
	it("formats a date in German and Japanese", () => {
		expect(formatDate(iso, intlLocale("de", "en-US"))).toBe("6. Okt. 2026");
		expect(formatDate(iso, intlLocale("ja", "en-US"))).toBe("2026年10月6日");
	});
	it("keeps the English output exactly as before", () => {
		expect(formatDate(iso)).toBe("Oct 6, 2026");
		expect(formatDate(iso, intlLocale("en", "en-US"))).toBe("Oct 6, 2026");
	});
	it("formats money in German and Japanese", () => {
		expect(formatMoney(1234.5, "EUR", intlLocale("de", "en-US"))).toMatch(/^1\.234,50\s€$/u);
		expect(formatMoney(1234, "JPY", intlLocale("ja", "en-US"))).toMatch(/1,234$/u);
	});
	it("keeps English money exactly as before", () => {
		expect(formatMoney(29.99, "USD")).toBe("$29.99");
		expect(formatMoney(29.99, "USD", intlLocale("en", "en-US"))).toBe("$29.99");
	});
});
