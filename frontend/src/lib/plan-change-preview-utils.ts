import { parseAmount } from "@/lib/paddle-format";
import type { PlanChangePreviewData } from "@/lib/paddle-types";

// ---
// Input shapes — minimal types matching the Paddle Node SDK / API response.
// The preview endpoint (PATCH /subscriptions/{id}/preview) returns a full
// subscription snapshot plus update_summary and transaction previews.
// ---

interface AmountWithCurrency {
	amount: string;
	currencyCode: string;
}

interface UpdateSummary {
	credit: AmountWithCurrency;
	charge: AmountWithCurrency;
	result: {
		action: "credit" | "charge";
		amount: string;
		currencyCode: string;
	};
}

type TransactionPreview = {
	billingPeriod?: { startsAt?: string | null } | null;
	details?: {
		totals?: {
			grandTotal?: string | null;
		} | null;
	} | null;
} | null;

interface RecurringDetails {
	totals: { total: string; currencyCode: string };
	lineItems?: Array<{ totals: { total: string } }> | null;
}

interface PlanItem {
	product: { name: string };
	price: {
		unitPrice?: { amount: string; currencyCode: string } | null;
		billingCycle?: { interval: string; frequency: number } | null;
	};
}

interface SubscriptionPreviewResponse {
	currencyCode: string;
	billingCycle: { interval: string; frequency: number };
	updateSummary: UpdateSummary;
	immediateTransaction?: TransactionPreview;
	nextTransaction?: TransactionPreview;
	recurringTransactionDetails: RecurringDetails;
	items: PlanItem[];
}

// Matches SDK SubscriptionDiscount — subscription.discount only has id + dates
type SubscriptionDiscountField = {
	id: string;
	startsAt?: string | null;
	endsAt?: string | null;
} | null;

interface PaddleSubscription {
	currencyCode: string;
	billingCycle: { interval: string; frequency: number };
	items: PlanItem[];
	status?: "active" | "canceled" | "past_due" | "paused" | "trialing";
	collectionMode?: "automatic" | "manual";
	scheduledChange?: {
		action: "cancel" | "pause" | "resume";
		effectiveAt: string;
	} | null;
	discount?: SubscriptionDiscountField;
}

// Full Discount catalog entity — fetched separately via paddle.discounts.get(id)
interface PaddleDiscount {
	id: string;
	description: string;
	code?: string | null;
	type: "flat" | "flat_per_seat" | "percentage";
	amount: string;
}

/**
 * Maps a Paddle subscription preview API response to the `PlanChangePreviewData`
 * display contract consumed by `PlanChangePreview`.
 *
 * Pass `prorationBillingMode` directly to the `<PlanChangePreview>` component as a prop.
 * Optionally pass a Paddle `Discount` to enrich the discount display.
 *
 * @param subscription - Current Paddle Subscription (before the change)
 * @param preview - Subscription update preview response
 * @param discount - Paddle Discount for enriched discount display
 * @returns Mapped preview data for `<PlanChangePreview />`
 *
 * @example
 * const subscription = await paddle.subscriptions.get(subscriptionId)
 * const preview = await paddle.subscriptions.previewUpdate(subscriptionId, {
 *   items: [{ priceId: newPriceId, quantity: 1 }],
 *   prorationBillingMode: "prorated_immediately",
 * })
 * const data = mapPreviewToPlanChangeData(subscription, preview)
 */
export function mapPreviewToPlanChangeData(
	subscription: PaddleSubscription,
	preview: SubscriptionPreviewResponse,
	discount?: PaddleDiscount | null,
): PlanChangePreviewData {
	const currencyCode = preview.currencyCode;
	const { updateSummary, immediateTransaction, nextTransaction, recurringTransactionDetails } =
		preview;

	const resultAmount = parseAmount(updateSummary.result.amount, currencyCode);
	const creditAmount = parseAmount(updateSummary.credit.amount, currencyCode);
	const chargeAmount = parseAmount(updateSummary.charge.amount, currencyCode);

	const resultDirection: PlanChangePreviewData["costImpact"]["resultDirection"] =
		resultAmount === 0 ? "none" : updateSummary.result.action;

	const immediateAmount = immediateTransaction?.details?.totals?.grandTotal
		? parseAmount(immediateTransaction.details.totals.grandTotal, currencyCode)
		: undefined;

	const nextBillAmount = nextTransaction?.details?.totals?.grandTotal
		? parseAmount(nextTransaction.details.totals.grandTotal, currencyCode)
		: undefined;

	const nextBillDate = nextTransaction?.billingPeriod?.startsAt ?? undefined;

	const currentItem = subscription.items[0]!;
	const newItem = preview.items[0]!;

	// description is required by PlanChangePreviewData.discount — only set when full entity provided
	const discountOutput: PlanChangePreviewData["discount"] = discount
		? {
				description: discount.description,
				endsAt: subscription.discount?.endsAt ?? undefined,
			}
		: undefined;

	const scheduledChange: PlanChangePreviewData["scheduledChange"] = subscription.scheduledChange
		? {
				action: subscription.scheduledChange.action,
				effectiveAt: subscription.scheduledChange.effectiveAt,
			}
		: undefined;

	return {
		currency: currencyCode,
		currentPlan: {
			productName: currentItem.product.name,
			price: currentItem.price.unitPrice
				? parseAmount(currentItem.price.unitPrice.amount, currencyCode)
				: 0,
			interval: subscription.billingCycle.interval,
			billingFrequency: subscription.billingCycle.frequency,
		},
		newPlan: {
			productName: newItem.product.name,
			price: parseAmount(recurringTransactionDetails.totals.total, currencyCode),
			interval: preview.billingCycle.interval,
			billingFrequency: preview.billingCycle.frequency,
		},
		costImpact: {
			resultDirection,
			resultAmount,
			credit: creditAmount > 0 ? creditAmount : undefined,
			charge: chargeAmount > 0 ? chargeAmount : undefined,
			immediateAmount,
			nextBillAmount,
			nextBillDate,
			newRecurringTotal: parseAmount(recurringTransactionDetails.totals.total, currencyCode),
			newBillingInterval: preview.billingCycle.interval,
			newBillingFrequency: preview.billingCycle.frequency,
		},
		discount: discountOutput,
		scheduledChange,
		subscriptionStatus: subscription.status,
		collectionMode: subscription.collectionMode,
	};
}
