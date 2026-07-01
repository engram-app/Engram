"use client";

import { mapSubscriptionToAlertData } from "@/lib/subscription-alert-utils";
import { SubscriptionAlert, type SubscriptionAlertProps } from "./subscription-alert";

type PaddleSubscription = Parameters<typeof mapSubscriptionToAlertData>[0];

export type PaddleSubscriptionAlertProps = {
	subscription: PaddleSubscription;
} & Omit<SubscriptionAlertProps, "subscription">;

/**
 * Paddle-aware wrapper for `SubscriptionAlert`.
 *
 * Accepts the raw Paddle subscription entity, maps it to `SubscriptionAlertData`,
 * and renders the UI component. All display-only props are passed through directly.
 *
 * @example
 * <PaddleSubscriptionAlert
 *   subscription={subscription}
 *   className="mb-4"
 * />
 */
export function PaddleSubscriptionAlert({
	subscription,
	...uiProps
}: PaddleSubscriptionAlertProps) {
	const data = mapSubscriptionToAlertData(subscription);
	return <SubscriptionAlert subscription={data} {...uiProps} />;
}
