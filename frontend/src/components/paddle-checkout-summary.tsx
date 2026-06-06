import { mapCheckoutEventsToSummary } from "@/lib/checkout-summary-utils"
import { CheckoutSummary, type CheckoutSummaryProps } from "./checkout-summary"

type CheckoutEventsInput = Parameters<typeof mapCheckoutEventsToSummary>[0]

export type PaddleCheckoutSummaryProps = {
  /**
   * Raw `CheckoutEventsData` from a Paddle.js checkout event callback
   * (e.g. `checkout.loaded`, `checkout.updated`).
   */
  checkoutData?: CheckoutEventsInput
} & Omit<CheckoutSummaryProps, "summary">

/**
 * Paddle-aware wrapper for `CheckoutSummary`.
 *
 * Accepts raw `CheckoutEventsData` from Paddle.js checkout event callbacks,
 * maps it to `CheckoutSummaryData`, and renders the order summary UI.
 *
 * Pass `undefined` to render the skeleton loading state.
 *
 * @example
 * const [checkoutData, setCheckoutData] = useState<CheckoutEventsData>()
 *
 * <PaddleCheckoutSummary
 *   checkoutData={checkoutData}
 *   policyUrl="/legal/refunds"
 * />
 */
export function PaddleCheckoutSummary({ checkoutData, ...uiProps }: PaddleCheckoutSummaryProps) {
  const summary = checkoutData ? mapCheckoutEventsToSummary(checkoutData) : undefined
  return <CheckoutSummary summary={summary} {...uiProps} />
}
