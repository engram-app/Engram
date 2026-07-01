import { mapPreviewToPlanChangeData } from "@/lib/plan-change-preview-utils";
import { PlanChangePreview, type PlanChangePreviewProps } from "./plan-change-preview";

type PaddleSubscription = Parameters<typeof mapPreviewToPlanChangeData>[0];
type PreviewResponse = Parameters<typeof mapPreviewToPlanChangeData>[1];
type PaddleDiscount = Parameters<typeof mapPreviewToPlanChangeData>[2];

export type PaddlePlanChangePreviewProps = {
	/** Current Paddle Subscription (before the change) */
	subscription: PaddleSubscription;
	/** Subscription update preview response with the proposed changes */
	previewResponse: PreviewResponse;
	/** Paddle Discount for enriched discount display */
	discount?: PaddleDiscount;
} & Omit<PlanChangePreviewProps, "preview">;

/**
 * Paddle-aware wrapper for `PlanChangePreview`.
 *
 * Accepts the current subscription entity and the Paddle preview update response,
 * maps them to `PlanChangePreviewData`, and renders the UI component.
 *
 * Pass `prorationBillingMode` through to control which billing row and label
 * the component displays.
 *
 * `subscription.items[].price.unit_price` must be present for the current plan
 * price to display correctly — fetch with full price details, not a list response.
 *
 * @example
 * <PaddlePlanChangePreview
 *   subscription={subscription}
 *   previewResponse={previewResponse}
 *   discount={discount}
 *   prorationBillingMode="prorated_immediately"
 * />
 */
export function PaddlePlanChangePreview({
	subscription,
	previewResponse,
	discount,
	...uiProps
}: PaddlePlanChangePreviewProps) {
	const preview = mapPreviewToPlanChangeData(subscription, previewResponse, discount);
	return <PlanChangePreview preview={preview} {...uiProps} />;
}
