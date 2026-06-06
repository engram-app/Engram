export function formatDate(isoString: string, locale: string = "en-US"): string {
  return new Intl.DateTimeFormat(locale, {
    year: "numeric",
    month: "short",
    day: "numeric",
  }).format(new Date(isoString))
}

// Structural alias — accepts both CheckoutEventsTimePeriod and TimePeriod
type TimePeriodLike = {
  frequency: number
  interval: string
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
  billingCycle: TimePeriodLike | null | undefined
): string | undefined {
  if (!billingCycle) {
    return undefined
  }

  const { frequency, interval } = billingCycle
  return frequency === 1 ? interval : `${frequency} ${interval}s`
}

/**
 * Formats a trial period for display.
 * @param trialPeriod - The trial period to format
 * @returns Formatted string like "7 days" or "1 month"
 *
 * @example
 * formatTrialPeriod({ frequency: 7, interval: "day" }) // "7 days"
 * formatTrialPeriod({ frequency: 1, interval: "month" }) // "1 month"
 */
export function formatTrialPeriod(trialPeriod: TimePeriodLike): string {
  const interval = trialPeriod.frequency === 1 ? trialPeriod.interval : `${trialPeriod.interval}s`

  return `${trialPeriod.frequency} ${interval}`
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
export function formatMoney(
  amount: number,
  currencyCode: string,
  locale: string = "en-US"
): string {
  return new Intl.NumberFormat(locale, {
    style: "currency",
    currency: currencyCode,
  }).format(amount)
}

// Paddle-supported zero-decimal currencies — amounts are already whole units.
// https://developer.paddle.com/concepts/payment-methods/currencies
const ZERO_DECIMAL_CURRENCIES = new Set(["JPY", "KRW", "VND", "CLP"])

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
  const value = parseInt(raw, 10)
  if (ZERO_DECIMAL_CURRENCIES.has(currencyCode.toUpperCase())) {
    return value
  }
  return value / 100
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
export function formatProrationMode(mode: string): string {
  const labels: Record<string, string> = {
    prorated_immediately: "Charge prorated amount now",
    full_immediately: "Charge full amount now",
    prorated_next_billing_period: "Prorated at next billing",
    full_next_billing_period: "Full charge at next billing",
    do_not_bill: "No charge",
  }
  return labels[mode] ?? mode
}

const INTERVAL_LABELS: Record<string, { noun: string; adjective: string }> = {
  day: { noun: "Daily", adjective: "daily" },
  week: { noun: "Weekly", adjective: "weekly" },
  month: { noun: "Monthly", adjective: "monthly" },
  year: { noun: "Annually", adjective: "annual" },
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
  style: "noun" | "adjective" = "noun"
): string {
  const entry = INTERVAL_LABELS[interval]
  if (entry) return entry[style]
  return interval.charAt(0).toUpperCase() + interval.slice(1)
}
