import { mapSubscriptionToStatusData } from "@/lib/subscription-status-card-utils"
import {
  SubscriptionStatusCard,
  type SubscriptionStatusCardProps,
} from "./subscription-status-card"

type PaddleSubscription = Parameters<typeof mapSubscriptionToStatusData>[0]
type RecurringTransactionDetails = Parameters<typeof mapSubscriptionToStatusData>[1]
type PaddleDiscount = Parameters<typeof mapSubscriptionToStatusData>[2]

export type PaddleSubscriptionStatusCardProps = {
  subscription: PaddleSubscription
  recurringTransactionDetails: RecurringTransactionDetails
  discount?: PaddleDiscount
} & Omit<SubscriptionStatusCardProps, "subscription">

/**
 * Paddle-aware wrapper for `SubscriptionStatusCard`.
 *
 * Accepts the raw Paddle subscription entity and `recurringTransactionDetails`
 * (from `GET /subscriptions/{id}?include=recurring_transaction_details`),
 * maps them to `SubscriptionStatusData`, and renders the UI component.
 *
 * Optionally pass a Paddle `Discount` to
 * enrich the discount display with a code and derived description label.
 *
 * All display-only props (`onChangePlan`, `onManageSubscription`, etc.) are
 * passed through directly.
 *
 * @example
 * <PaddleSubscriptionStatusCard
 *   subscription={subscription}
 *   recurringTransactionDetails={subscription.recurringTransactionDetails}
 *   onChangePlan={() => setShowPlanChange(true)}
 * />
 */
export function PaddleSubscriptionStatusCard({
  subscription,
  recurringTransactionDetails,
  discount,
  ...uiProps
}: PaddleSubscriptionStatusCardProps) {
  const data = mapSubscriptionToStatusData(subscription, recurringTransactionDetails, discount)
  return <SubscriptionStatusCard subscription={data} {...uiProps} />
}
