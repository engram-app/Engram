import { parseAmount } from "@/lib/paddle-format";
import type {
	PlanChangeBreakdownData,
	PlanChangeLineItemData,
	PlanChangeTransactionSectionData,
	PlanChangeTransactionTotalsData,
} from "@/lib/paddle-types";

// ---
// Input shapes — matching Paddle Node SDK / API response structures.
// `immediate_transaction` and `next_transaction` share a shape with
// `details.line_items` and `details.totals`. `recurring_transaction_details`
// has `line_items` and `totals` at the top level (no `details` wrapper)
// and omits `billing_period`.
// ---

type AmountWithCurrency = {
	amount: string;
	currencyCode: string;
};

type LineItemTotals = {
	subtotal: string;
	total: string;
	tax: string;
	discount: string;
};

type Proration = {
	rate: string;
	billingPeriod: {
		startsAt: string;
		endsAt: string;
	};
} | null;

type LineItem = {
	product: { name: string };
	quantity: number;
	unitTotals: { subtotal: string };
	totals: LineItemTotals;
	proration?: Proration;
};

type TransactionTotals = {
	subtotal: string;
	discount: string;
	tax: string;
	total: string;
	grandTotal: string;
	credit: string;
	creditToBalance?: string;
};

type TransactionPreview = {
	billingPeriod?: { startsAt?: string | null; endsAt?: string | null } | null;
	details: {
		totals: TransactionTotals;
		lineItems: LineItem[];
	};
};

type RecurringTransactionDetails = {
	totals: TransactionTotals & { currencyCode: string };
	lineItems: LineItem[];
};

type UpdateSummary = {
	credit: AmountWithCurrency;
	charge: AmountWithCurrency;
	result: {
		action: "credit" | "charge";
		amount: string;
		currencyCode: string;
	};
};

type BreakdownPreviewResponse = {
	currencyCode: string;
	updateSummary: UpdateSummary;
	immediateTransaction?: TransactionPreview | null;
	nextTransaction?: TransactionPreview | null;
	recurringTransactionDetails?: RecurringTransactionDetails | null;
};

function mapLineItems(items: LineItem[], currencyCode: string): PlanChangeLineItemData[] {
	return items.map((item) => {
		const hasProration = item.proration != null;
		let prorationPeriod: string | undefined;

		if (hasProration && item.proration) {
			const rate = Number.parseFloat(item.proration.rate);
			if (!isNaN(rate) && rate > 0 && rate < 1) {
				const start = new Date(item.proration.billingPeriod.startsAt);
				const end = new Date(item.proration.billingPeriod.endsAt);
				const totalDays = Math.round((end.getTime() - start.getTime()) / (1000 * 60 * 60 * 24));
				const proratedDays = Math.round(totalDays * rate);
				prorationPeriod = `${proratedDays} of ${totalDays} days`;
			}
		}

		return {
			productName: item.product.name,
			quantity: item.quantity,
			unitPrice: parseAmount(item.unitTotals.subtotal, currencyCode),
			total: parseAmount(item.totals.total, currencyCode),
			isProrated: hasProration || undefined,
			prorationPeriod,
		};
	});
}

function mapTotals(
	totals: TransactionTotals,
	currencyCode: string,
): PlanChangeTransactionTotalsData {
	const discount = parseAmount(totals.discount, currencyCode);
	const credit = parseAmount(totals.credit, currencyCode);
	const creditToBalance = totals.creditToBalance
		? parseAmount(totals.creditToBalance, currencyCode)
		: 0;

	return {
		subtotal: parseAmount(totals.subtotal, currencyCode),
		discount: discount > 0 ? discount : undefined,
		tax: parseAmount(totals.tax, currencyCode),
		credit: credit > 0 ? credit : undefined,
		creditToBalance: creditToBalance > 0 ? creditToBalance : undefined,
		total: parseAmount(totals.grandTotal, currencyCode),
	};
}

/**
 * Maps a Paddle subscription preview API response to the `PlanChangeBreakdownData`
 * display contract consumed by `PlanChangeBreakdown`.
 *
 * Provides full financial detail — line items, tax, proration periods, and totals.
 * Pass `collectionMode` directly to `<PlanChangeBreakdown>` as a prop.
 *
 * @param preview - Subscription update preview response
 * @returns Mapped breakdown data for `<PlanChangeBreakdown />`
 *
 * @example
 * const preview = await paddle.subscriptions.previewUpdate(subscriptionId, {
 *   items: [{ priceId: newPriceId, quantity: 1 }],
 *   prorationBillingMode: "prorated_immediately",
 * })
 * const data = mapPreviewToBreakdownData(preview)
 */
export function mapPreviewToBreakdownData(
	preview: BreakdownPreviewResponse,
): PlanChangeBreakdownData {
	const {
		currencyCode,
		updateSummary,
		immediateTransaction,
		nextTransaction,
		recurringTransactionDetails,
	} = preview;

	const resultAmount = parseAmount(updateSummary.result.amount, currencyCode);
	const creditAmount = parseAmount(updateSummary.credit.amount, currencyCode);
	const chargeAmount = parseAmount(updateSummary.charge.amount, currencyCode);
	const isNone = resultAmount === 0;

	const result: PlanChangeBreakdownData["result"] = {
		direction: isNone ? "none" : updateSummary.result.action,
		amount: resultAmount,
	};

	const breakdown: PlanChangeBreakdownData["breakdown"] =
		creditAmount > 0 || chargeAmount > 0
			? {
					credit: creditAmount > 0 ? creditAmount : undefined,
					charge: chargeAmount > 0 ? chargeAmount : undefined,
				}
			: undefined;

	let immediateSectionData: PlanChangeTransactionSectionData | undefined;
	if (immediateTransaction) {
		immediateSectionData = {
			lineItems: mapLineItems(immediateTransaction.details.lineItems, currencyCode),
			totals: mapTotals(immediateTransaction.details.totals, currencyCode),
		};
	}

	let nextSectionData: PlanChangeTransactionSectionData | undefined;
	if (nextTransaction) {
		nextSectionData = {
			billingDate: nextTransaction.billingPeriod?.startsAt ?? undefined,
			lineItems: mapLineItems(nextTransaction.details.lineItems, currencyCode),
			totals: mapTotals(nextTransaction.details.totals, currencyCode),
		};
	}

	let recurringSectionData: PlanChangeTransactionSectionData | undefined;
	if (recurringTransactionDetails) {
		recurringSectionData = {
			lineItems: mapLineItems(recurringTransactionDetails.lineItems, currencyCode),
			totals: mapTotals(recurringTransactionDetails.totals, currencyCode),
		};
	}

	return {
		currency: currencyCode,
		result,
		breakdown,
		immediateTransaction: immediateSectionData,
		nextTransaction: nextSectionData,
		recurringTransaction: recurringSectionData,
	};
}
