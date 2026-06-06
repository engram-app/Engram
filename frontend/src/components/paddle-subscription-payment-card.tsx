import * as React from "react"
import {
  mapSubscriptionToNextPayment,
  mapTransactionToPaymentMethod,
  getUpdatePaymentMethodUrl,
} from "@/lib/subscription-payment-card-utils"
import {
  SubscriptionPaymentCard,
  type SubscriptionPaymentCardProps,
} from "./subscription-payment-card"

type SubscriptionInput = Parameters<typeof mapSubscriptionToNextPayment>[0]
type NextTransactionInput = Parameters<typeof mapSubscriptionToNextPayment>[1]

export type PaddleSubscriptionPaymentCardProps = {
  /** Paddle Subscription */
  subscription: SubscriptionInput
  /**
   * `next_transaction` include from the subscription fetch.
   * Required for accurate next-bill amount. Fetch with:
   * `paddle.subscriptions.get(id, { include: ["next_transaction"] })`
   */
  nextTransaction?: NextTransactionInput
  /**
   * Most recent completed transaction for the subscription.
   * Used to determine the stored payment method. Fetch with:
   * `paddle.transactions.list({ subscriptionId, status: ["completed"], perPage: 1 })`
   */
  lastTransaction?: NextTransactionInput
} & Omit<SubscriptionPaymentCardProps, "nextPayment" | "paymentMethod" | "updatePaymentMethodUrl">

/**
 * Paddle-aware wrapper for `SubscriptionPaymentCard`.
 *
 * Accepts raw Paddle subscription and transaction entities, maps them to
 * `NextPaymentData` and `PaymentMethodData`, and renders the UI component.
 *
 * @example
 * <PaddleSubscriptionPaymentCard
 *   subscription={subscription}
 *   nextTransaction={subscription.nextTransaction}
 *   lastTransaction={transactions.data[0]}
 * />
 */
export function PaddleSubscriptionPaymentCard({
  subscription,
  nextTransaction,
  lastTransaction,
  ...uiProps
}: PaddleSubscriptionPaymentCardProps) {
  const nextPayment = mapSubscriptionToNextPayment(subscription, nextTransaction)
  const paymentMethod = mapTransactionToPaymentMethod(lastTransaction)
  const updatePaymentMethodUrl = getUpdatePaymentMethodUrl(subscription)

  return (
    <SubscriptionPaymentCard
      nextPayment={nextPayment}
      paymentMethod={paymentMethod}
      updatePaymentMethodUrl={updatePaymentMethodUrl}
      {...uiProps}
    />
  )
}
