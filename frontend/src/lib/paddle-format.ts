import { msg } from "@/i18n/msg";
import type { Tn, Translate } from "@/i18n/translate";
import { formatDate as formatShortDate } from "./format-date";

// Structural alias — accepts both CheckoutEventsTimePeriod and TimePeriod
interface TimePeriodLike {
	frequency: number;
	interval: string;
}

// Paddle-supported zero-decimal currencies — amounts are already whole units.
// https://developer.paddle.com/concepts/payment-methods/currencies
const ZERO_DECIMAL_CURRENCIES = new Set(["JPY", "KRW", "VND", "CLP"]);

const INTERVAL_LABELS: Record<string, { noun: string; adjective: string }> = {
	day: { noun: msg("Daily"), adjective: msg("daily") },
	week: { noun: msg("Weekly"), adjective: msg("weekly") },
	month: { noun: msg("Monthly"), adjective: msg("monthly") },
	year: { noun: msg("Annually"), adjective: msg("annual") },
};

const PRORATION_LABELS: Record<string, string> = {
	prorated_immediately: msg("Charge prorated amount now"),
	full_immediately: msg("Charge full amount now"),
	prorated_next_billing_period: msg("Prorated at next billing"),
	full_next_billing_period: msg("Full charge at next billing"),
	do_not_bill: msg("No charge"),
};

export function formatDate(isoString: string, locale = "en-US"): string {
	return formatShortDate(isoString, locale);
}

/**
 * Formats a billing cycle for display.
 * @param billingCycle - The billing cycle to format
 * @returns Formatted string like "month", "year", or "3 months", or undefined if no billing cycle
 *
 * @example
 * formatBillingCycle({ frequency: 1, interval: "month" }) // "month"
 * formatBillingCycle({ frequency: 3, interval: "month" }) // "3 months"
 */
export function formatBillingCycle(
	billingCycle: TimePeriodLike | null | undefined,
	t: Translate,
	tn: Tn,
): string | undefined {
	if (!billingCycle) {
		return;
	}

	const { frequency, interval } = billingCycle;
	switch (interval) {
		case "day":
			return frequency === 1
				? t("day")
				: tn({ one: "{count} day", other: "{count} days" }, frequency);
		case "week":
			return frequency === 1
				? t("week")
				: tn({ one: "{count} week", other: "{count} weeks" }, frequency);
		case "month":
			return frequency === 1
				? t("month")
				: tn({ one: "{count} month", other: "{count} months" }, frequency);
		case "year":
			return frequency === 1
				? t("year")
				: tn({ one: "{count} year", other: "{count} years" }, frequency);
		default:
			// Unknown Paddle interval: show the raw value rather than guess a translation.
			return frequency === 1 ? interval : `${frequency} ${interval}s`;
	}
}

/**
 * Formats a trial period for display.
 * @param trialPeriod - The trial period to format
 * @param tn - Plural translator from `useT()`
 * @returns Formatted string like "7 days" or "1 month"
 *
 * @example
 * formatTrialPeriod({ frequency: 7, interval: "day" }, tn) // "7 days"
 * formatTrialPeriod({ frequency: 1, interval: "month" }, tn) // "1 month"
 */
export function formatTrialPeriod(trialPeriod: TimePeriodLike, tn: Tn): string {
	const { frequency, interval } = trialPeriod;
	switch (interval) {
		case "day":
			return tn({ one: "{count} day", other: "{count} days" }, frequency);
		case "week":
			return tn({ one: "{count} week", other: "{count} weeks" }, frequency);
		case "month":
			return tn({ one: "{count} month", other: "{count} months" }, frequency);
		case "year":
			return tn({ one: "{count} year", other: "{count} years" }, frequency);
		default:
			// Unknown Paddle interval: show the raw value rather than guess a translation.
			return `${frequency} ${frequency === 1 ? interval : `${interval}s`}`;
	}
}

/**
 * Formats a numeric monetary amount as a localised currency string.
 *
 * @param amount - Raw numeric amount (e.g. from Paddle checkout event totals)
 * @param currencyCode - ISO 4217 currency code (e.g. "USD", "GBP")
 * @param locale - Optional BCP 47 locale tag (e.g. "en-GB"). Defaults to "en-US" so SSR
 *   and client produce identical output (required for React hydration).
 * @returns Formatted currency string, e.g. "$29.99" or "£12.00"
 *
 * @example
 * formatMoney(29.99, "USD") // "$29.99"
 * formatMoney(12, "GBP", "en-GB") // "£12.00"
 */
export function formatMoney(amount: number, currencyCode: string, locale = "en-US"): string {
	return new Intl.NumberFormat(locale, {
		style: "currency",
		currency: currencyCode,
	}).format(amount);
}

/**
 * Parses a Paddle API monetary amount string (lowest denomination, e.g. "1500")
 * to a decimal number suitable for `formatMoney` (e.g. 15.00).
 *
 * Paddle returns amounts as strings in the lowest denomination of the currency.
 * Standard currencies (USD, EUR, GBP, etc.) use cents — divide by 100.
 * Zero-decimal currencies (JPY, KRW, VND, CLP) are already whole units — no division.
 *
 * @param raw - Amount string in lowest denomination (e.g. "1500" for $15.00 USD or ¥1500 JPY)
 * @param currencyCode - ISO 4217 currency code used to determine decimal handling
 * @returns Decimal number ready for `formatMoney`
 *
 * @example
 * parseAmount("1500", "USD") // 15
 * parseAmount("999", "USD")  // 9.99
 * parseAmount("1500", "JPY") // 1500
 */
export function parseAmount(raw: string, currencyCode: string): number {
	const value = Number.parseInt(raw, 10);
	if (ZERO_DECIMAL_CURRENCIES.has(currencyCode.toUpperCase())) {
		return value;
	}
	return value / 100;
}

/**
 * Returns a human-readable label for a Paddle proration billing mode.
 *
 * @param mode - Paddle `proration_billing_mode` value
 * @returns Display label, e.g. "Charge prorated amount now"
 *
 * @example
 * formatProrationMode("prorated_immediately") // "Charge prorated amount now"
 * formatProrationMode("full_next_billing_period") // "Full charge at next billing"
 */
export function formatProrationMode(mode: string, t: Translate): string {
	const label = PRORATION_LABELS[mode];
	return label ? t(label) : mode;
}

/**
 * Returns a human-readable label for a Paddle billing interval.
 *
 * @param interval - Paddle interval key, e.g. "month", "year"
 * @param style - "noun" for toggle labels ("Monthly"), "adjective" for inline labels ("monthly")
 * @returns Display label, e.g. "Monthly" or "monthly"
 *
 * @example
 * formatIntervalLabel("month")             // "Monthly"
 * formatIntervalLabel("year", "adjective") // "annual"
 * formatIntervalLabel("month", "noun")     // "Monthly"
 */
export function formatIntervalLabel(
	interval: string,
	t: Translate,
	style: "noun" | "adjective" = "noun",
): string {
	const entry = INTERVAL_LABELS[interval];
	if (entry) {
		return t(entry[style]);
	}
	return interval.charAt(0).toUpperCase() + interval.slice(1);
}
