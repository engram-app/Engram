import type {
  NextPaymentData,
  PaymentMethodData,
} from "@/lib/paddle-types"
import { parseAmount } from "@/lib/paddle-format"

// ---
// Input shapes — minimal types matching the Paddle Node SDK / API response.
// ---

type MethodDetails = {
  type: string
  card?: {
    type?: string | null
    last4?: string | null
    expiryMonth?: number | null
    expiryYear?: number | null
  } | null
}

type PaymentEntry = {
  methodDetails?: MethodDetails | null
}

type PaddleTransaction = {
  payments?: PaymentEntry[] | null
  details?: {
    totals?: {
      grandTotal?: string | null
    } | null
  } | null
}

type PaddleSubscription = {
  currencyCode: string
  nextBilledAt?: string | null
  managementUrls?: {
    updatePaymentMethod?: string | null
  } | null
}

/**
 * Extracts the `NextPaymentData` display contract from a Paddle subscription.
 *
 * Requires the `next_transaction` include on the subscription fetch for the
 * accurate next-bill amount (which may differ from the recurring total if
 * there are prorations or one-time charges). Falls back to the subscription's
 * `next_billed_at` for the date. Returns `undefined` when `next_billed_at`
 * is absent (paused or canceled subscriptions).
 *
 * @param subscription - Paddle Subscription
 * @param nextTransaction - `subscription.nextTransaction` from the `next_transaction` include
 * @returns Next payment display data, or `undefined` if no upcoming payment
 *
 * @example
 * const data = await paddle.subscriptions.get(subscriptionId, {
 *   include: ["next_transaction"],
 * })
 * const nextPayment = mapSubscriptionToNextPayment(data, data.nextTransaction)
 */
export function mapSubscriptionToNextPayment(
  subscription: PaddleSubscription,
  nextTransaction?: PaddleTransaction | null
): NextPaymentData | undefined {
  if (!subscription.nextBilledAt) return undefined

  const amount = nextTransaction?.details?.totals?.grandTotal
    ? parseAmount(nextTransaction.details.totals.grandTotal, subscription.currencyCode)
    : 0

  return {
    amount,
    currency: subscription.currencyCode,
    date: subscription.nextBilledAt,
  }
}

/**
 * Extracts the `PaymentMethodData` display contract from the most recent
 * completed Paddle transaction for a subscription.
 *
 * Sourced from `transaction.payments[0].method_details` — the last recorded
 * payment method. Returns `undefined` if no payment entry is present.
 *
 * @param transaction - Most recent completed Paddle Transaction for the subscription
 * @returns Payment method display data, or `undefined` if unavailable
 *
 * @example
 * // Fetch the most recent completed transaction for the subscription
 * const transactions = await paddle.transactions.list({
 *   subscriptionId,
 *   status: ["completed"],
 *   perPage: 1,
 * })
 * const paymentMethod = mapTransactionToPaymentMethod(transactions.data[0])
 */
export function mapTransactionToPaymentMethod(
  transaction?: PaddleTransaction | null
): PaymentMethodData | undefined {
  const methodDetails = transaction?.payments?.[0]?.methodDetails
  if (!methodDetails) return undefined

  return {
    type: methodDetails.type,
    cardBrand: methodDetails.card?.type ?? undefined,
    last4: methodDetails.card?.last4 ?? undefined,
    expiryMonth: methodDetails.card?.expiryMonth ?? undefined,
    expiryYear: methodDetails.card?.expiryYear ?? undefined,
  }
}

/**
 * Returns the `updatePaymentMethodUrl` prop value from a subscription's
 * management URLs.
 *
 * Returns `undefined` for manually-collected subscriptions (where the portal
 * URL is `null`) so the update link is hidden.
 *
 * @param subscription - Paddle Subscription
 * @returns Portal URL, or `undefined` if unavailable
 */
export function getUpdatePaymentMethodUrl(subscription: PaddleSubscription): string | undefined {
  return subscription.managementUrls?.updatePaymentMethod ?? undefined
}
