import { mapPreviewToBreakdownData } from "@/lib/plan-change-breakdown-utils";
import { PlanChangeBreakdown, type PlanChangeBreakdownProps } from "./plan-change-breakdown";

type BreakdownPreviewResponse = Parameters<typeof mapPreviewToBreakdownData>[0];

export type PaddlePlanChangeBreakdownProps = {
	/** Subscription update preview response with the proposed changes */
	previewResponse: BreakdownPreviewResponse;
} & Omit<PlanChangeBreakdownProps, "breakdown">;

/**
 * Paddle-aware wrapper for `PlanChangeBreakdown`.
 *
 * Accepts the response from the Paddle preview update endpoint, maps it to
 * `PlanChangeBreakdownData`, and renders the detailed financial breakdown UI.
 *
 * Pass `collectionMode` from the subscription to control billing terminology
 * (e.g. "Invoice created" vs "Charged today").
 *
 * @example
 * <PaddlePlanChangeBreakdown
 *   previewResponse={previewResponse}
 *   prorationBillingMode="prorated_immediately"
 *   collectionMode={subscription.collectionMode}
 * />
 */
export function PaddlePlanChangeBreakdown({
	previewResponse,
	...uiProps
}: PaddlePlanChangeBreakdownProps) {
	const breakdown = mapPreviewToBreakdownData(previewResponse);
	return <PlanChangeBreakdown breakdown={breakdown} {...uiProps} />;
}
