import { formatTrialPeriod } from "@/lib/paddle-format";
import type { CheckoutSummaryData } from "@/lib/paddle-types";

// ---
// Input shapes — minimal types matching the Paddle.js CheckoutEventsData shape.
// Field names use snake_case (Paddle.js convention). Pass the raw checkout event
// payload or any object matching this shape.
// ---

interface TimePeriodLike {
	interval: string;
	frequency: number;
}

interface CheckoutEventItem {
	product?: { name?: string | null } | null;
	price_name?: string | null;
	quantity?: number | null;
	totals?: { subtotal?: number | null } | null;
	billing_cycle?: TimePeriodLike | null;
	trial_period?: TimePeriodLike | null;
}

interface CheckoutEventsInput {
	currency_code?: string | null;
	items?: CheckoutEventItem[] | null;
	totals?: {
		subtotal?: number | null;
		tax?: number | null;
		total?: number | null;
		discount?: number | null;
	} | null;
	recurring_totals?: {
		total?: number | null;
	} | null;
}

/**
 * Maps a Paddle.js checkout event payload to the `CheckoutSummaryData`
 * display contract consumed by `CheckoutSummary`.
 *
 * Paddle.js checkout event totals are already decimal numbers (not lowest-denomination),
 * so no cents-to-decimal conversion is needed here. For Paddle API amounts, use
 * `parseAmount()` from `paddle-format` — those are returned in lowest denomination.
 *
 * @param data - Paddle.js checkout event data (e.g. from `checkout.loaded` / `checkout.updated`)
 * @returns Mapped summary data for `<CheckoutSummary />`
 *
 * @example
 * paddle.Update({ eventCallback: (event) => {
 *   const summary = mapCheckoutEventsToSummary(event.data)
 * }})
 */
export function mapCheckoutEventsToSummary(data: CheckoutEventsInput): CheckoutSummaryData {
	const currency = data.currency_code ?? "";

	const items = (data.items ?? []).map((item) => ({
		name: item.product?.name ?? "",
		priceName: item.price_name ?? undefined,
		quantity: item.quantity ?? 1,
		lineTotal: item.totals?.subtotal ?? 0,
	}));

	const totals = data.totals;
	const recurringTotals = data.recurring_totals;

	const discount = totals?.discount && totals.discount > 0 ? totals.discount : undefined;

	// Build recurring billing info from the first item that has a billing cycle.
	// Using find() rather than [0] handles mixed carts (e.g. one-time setup fee
	// followed by a recurring subscription) where the first item may not recur.
	let recurringTotal: number | undefined;
	let recurringInterval: string | undefined;
	let recurringFrequency: number | undefined;
	const firstRecurringItem = data.items?.find((item) => item.billing_cycle != null);
	const billingCycle = firstRecurringItem?.billing_cycle;
	if (billingCycle && recurringTotals?.total != null) {
		recurringTotal = recurringTotals.total;
		recurringInterval = billingCycle.interval;
		recurringFrequency = billingCycle.frequency;
	}

	// Build trial period label from the first item that has a trial period.
	let trialPeriod: string | undefined;
	const firstTrialItem = data.items?.find((item) => item.trial_period != null);
	if (firstTrialItem?.trial_period) {
		trialPeriod = formatTrialPeriod(firstTrialItem.trial_period);
	}

	return {
		items,
		subtotal: totals?.subtotal ?? 0,
		tax: totals?.tax ?? 0,
		total: totals?.total ?? 0,
		discount,
		currency,
		recurringTotal,
		recurringInterval,
		recurringFrequency,
		trialPeriod,
	};
}
