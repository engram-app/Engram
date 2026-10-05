import { describe, expect, it } from "vitest";
import { translate, translatePlural } from "@/i18n/translate";
import type { Tn, Translate } from "@/lib/translator";
import { formatBillingCycle, formatIntervalLabel, formatProrationMode } from "./paddle-format";
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
