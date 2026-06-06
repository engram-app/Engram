export type {
  Paddle,
  Environments,
  PaddleEventData,
  PricePreviewParams,
  PricePreviewResponse,
  CheckoutEventsData,
  CheckoutCustomer,
  TimePeriod,
  CheckoutOpenLineItem,
} from "@paddle/paddle-js"

export { CheckoutEventNames } from "@paddle/paddle-js"

// CheckoutSettings from the SDK, widened to include "express" in the variant
// union. The express variant is a valid Paddle.js variant not yet reflected in
// the SDK's Variant type ('multi-page' | 'one-page').
import type { CheckoutSettings as SDKCheckoutSettings, CheckoutCustomer } from "@paddle/paddle-js"
export type CheckoutSettings = Omit<SDKCheckoutSettings, "variant"> & {
  variant?: SDKCheckoutSettings["variant"] | "express"
}

// ---
// Hook API types
// Used by the hooks in this library. You generally won't need to use these
// directly unless you're building a custom integration on top of the hooks.
// ---

/**
 * Options for opening a Paddle inline checkout.
 *
 * Passed to `openCheckout()` returned by `useCheckout`. Accepts either a
 * `priceId` (legacy, mapped to a single-item checkout) or an `items` array
 * for multi-item checkouts. When both are provided, `items` takes precedence.
 *
 * Note: this is a simplified wrapper over the raw Paddle SDK `CheckoutOpenOptions`.
 * For full control over the checkout, use `paddle.Checkout.open()` directly.
 */
export type OpenCheckoutOptions = {
  priceId: string
  items?: Array<{ priceId: string; quantity?: number }>
  customer?: CheckoutCustomer
  customerAuthToken?: string
  discountCode?: string
  discountId?: string
  customData?: Record<string, unknown>
  /** Must be an absolute URL (starting with `https://` or `http://`) */
  successUrl?: string
}
