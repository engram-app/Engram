import { parseAmount } from "@/lib/paddle-format";
import type { SubscriptionStatusData } from "@/lib/paddle-types";

// ---
// Input shapes — minimal types matching the Paddle Node SDK / API response.
// Field names use camelCase (Node SDK convention). Pass the raw API response
// or destructure these fields from your own subscription fetch.
// ---

type SubscriptionItem = {
	product: {
		name: string;
		description?: string | null;
		imageUrl?: string | null;
	};
	price?: {
		name?: string | null;
		unitPrice?: { amount: string; currencyCode: string } | null;
	} | null;
	quantity: number;
};

type RecurringLineItem = {
	totals: { subtotal: string; total: string };
};

type ScheduledChange = {
	action: "cancel" | "pause" | "resume";
	effectiveAt: string;
	resumeAt?: string | null;
} | null;

// Matches SDK SubscriptionDiscount — subscription.discount only has id + dates
type SubscriptionDiscountField = {
	id: string;
	startsAt?: string | null;
	endsAt?: string | null;
} | null;

// Full Discount catalog entity — fetched separately via paddle.discounts.get(id)
type PaddleDiscount = {
	id: string;
	description: string;
	code?: string | null;
	type: "flat" | "flat_per_seat" | "percentage";
	amount: string;
};

type PaddleSubscription = {
	id: string;
	status: "active" | "canceled" | "past_due" | "paused" | "trialing";
	currencyCode: string;
	billingCycle: { interval: string; frequency: number };
	collectionMode?: "automatic" | "manual";
	startedAt: string;
	nextBilledAt?: string | null;
	canceledAt?: string | null;
	scheduledChange?: ScheduledChange;
	discount?: SubscriptionDiscountField;
	items: SubscriptionItem[];
};

type RecurringTransactionDetails = {
	totals: { total: string; discount?: string };
	lineItems: RecurringLineItem[];
};

/**
 * Maps a Paddle subscription API response to the `SubscriptionStatusData`
 * display contract consumed by `SubscriptionStatusCard`.
 *
 * Pass the raw Paddle subscription and the
 * `recurring_transaction_details` include (required for accurate totals).
 * Optionally pass a Paddle `Discount` to enrich the discount display
 * with `code` and a derived description label.
 *
 * @param subscription - Paddle Subscription
 * @param recurringTransactionDetails - `subscription.recurringTransactionDetails` from the same response
 * @param discount - Paddle Discount for enriched discount display
 * @returns Mapped status data for `<SubscriptionStatusCard />`
 *
 * @example
 * const data = await paddle.subscriptions.get(subscriptionId, {
 *   include: ["recurring_transaction_details"],
 * })
 * const statusData = mapSubscriptionToStatusData(data, data.recurringTransactionDetails)
 */
export function mapSubscriptionToStatusData(
	subscription: PaddleSubscription,
	recurringTransactionDetails: RecurringTransactionDetails,
	discount?: PaddleDiscount | null,
): SubscriptionStatusData {
	const { currencyCode } = subscription;

	const items = subscription.items.map((item, i) => ({
		productName: item.product.name,
		productDescription: item.product.description ?? undefined,
		productImageUrl: item.product.imageUrl ?? undefined,
		priceName: item.price?.name ?? undefined,
		quantity: item.quantity,
		unitPrice: item.price?.unitPrice
			? parseAmount(item.price.unitPrice.amount, currencyCode)
			: undefined,
		lineTotal: parseAmount(
			recurringTransactionDetails.lineItems[i]?.totals.subtotal ?? "0",
			currencyCode,
		),
	}));

	const discountAmount = recurringTransactionDetails.totals.discount
		? parseAmount(recurringTransactionDetails.totals.discount, currencyCode)
		: 0;

	// Percentage discounts produce e.g. "-15%"; flat discounts leave description
	// undefined so the component formats it from savingsAmount + currency.
	const discountDescription =
		discount?.type === "percentage" ? `-${discount.description}` : undefined;

	const discountOutput: SubscriptionStatusData["discount"] =
		subscription.discount && discountAmount > 0
			? {
					savingsAmount: discountAmount,
					endsAt: subscription.discount.endsAt ?? undefined,
					code: discount?.code ?? undefined,
					description: discountDescription,
				}
			: undefined;

	const scheduledChange: SubscriptionStatusData["scheduledChange"] = subscription.scheduledChange
		? {
				action: subscription.scheduledChange.action,
				effectiveAt: subscription.scheduledChange.effectiveAt,
				resumeAt: subscription.scheduledChange.resumeAt ?? undefined,
			}
		: undefined;

	return {
		id: subscription.id,
		items,
		totalAmount: parseAmount(recurringTransactionDetails.totals.total, currencyCode),
		currency: currencyCode,
		interval: subscription.billingCycle.interval,
		billingFrequency: subscription.billingCycle.frequency,
		status: subscription.status,
		collectionMode: subscription.collectionMode,
		startedAt: subscription.startedAt,
		nextBilledAt: subscription.nextBilledAt ?? undefined,
		canceledAt: subscription.canceledAt ?? undefined,
		scheduledChange,
		discount: discountOutput,
	};
}
