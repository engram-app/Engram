export type PriceData = {
  /** Formatted price string, e.g. "$9.99" or "£12.00" */
  total: string
  /** Pre-discount price, e.g. "$12.99". Present only when a discount is applied. */
  originalTotal?: string
  /** Billing frequency, e.g. "month", "year", "3 months" */
  interval?: string
  /** Trial period length, e.g. "7 days", "1 month" */
  trialPeriod?: string
}

/**
 * Normalized payload delivered to the `onComplete` callback when a Paddle
 * checkout transaction completes successfully.
 *
 * This is a subset of the full Paddle checkout event data, containing the
 * fields most commonly needed for post-purchase handling (e.g. sending to
 * your backend, showing a confirmation screen).
 */
export type CheckoutCompleteData = {
  transactionId: string
  customerId: string
  customerEmail: string
}

/**
 * A single line item in the checkout order summary.
 *
 * Monetary values are raw decimal numbers — the component formats them using
 * the parent `CheckoutSummaryData.currency`.
 * Produced by `mapCheckoutEventsToSummary` from `CheckoutEventsData`.
 */
export type CheckoutSummaryItem = {
  name: string
  priceName?: string
  quantity: number
  lineTotal: number
}

/**
 * Display contract for the `CheckoutSummary` component.
 *
 * Monetary amounts are raw decimal numbers — the component formats them using `currency`.
 * Produced by `mapCheckoutEventsToSummary` from the `CheckoutEventsData` payload
 * emitted by Paddle.js checkout events.
 */
export type CheckoutSummaryData = {
  items: CheckoutSummaryItem[]
  subtotal: number
  tax: number
  total: number
  discount?: number
  /** ISO 4217 currency code, e.g. "USD" */
  currency: string
  /** Recurring total amount as a decimal number */
  recurringTotal?: number
  /** Recurring billing interval, e.g. "month" */
  recurringInterval?: string
  /** Recurring billing frequency, e.g. 1 */
  recurringFrequency?: number
  /** Trial period label, e.g. "7 days" or "1 month" */
  trialPeriod?: string
}

// ---
// Subscription display types
// Display contracts for subscription management components. Monetary amounts
// are raw decimal numbers; date values are ISO 8601 strings. Populate from
// Paddle's subscription API responses combined with formatting utilities.
// ---

/** Paddle subscription statuses. From `subscription.status`. */
export type SubscriptionStatus = "active" | "canceled" | "past_due" | "paused" | "trialing"

/**
 * A single line item within a subscription.
 *
 * Represents one product/price combination in the subscription.
 * `lineTotal` should come from `recurring_transaction_details.line_items[n].totals.subtotal`
 * as a decimal number (e.g. 29.99).
 */
export type SubscriptionStatusItemData = {
  /** Product name, e.g. "Pro Plan" */
  productName: string
  /** Optional product description */
  productDescription?: string
  /** Optional product image URL */
  productImageUrl?: string
  /** Price/tier name, e.g. "Monthly" or "Annual". From `items[n].price.name`. */
  priceName?: string
  quantity: number
  /**
   * Unit price as a decimal number, e.g. 99.99.
   * From `items[n].price.unit_price.amount`. Only rendered when quantity > 1.
   */
  unitPrice?: number
  /**
   * Line item subtotal as a decimal number (before discount, before tax), e.g. 29.99.
   * From `recurring_transaction_details.line_items[n].totals.subtotal`.
   * Discounts are shown as a separate summary line — this field should NOT include them.
   */
  lineTotal: number
}

/**
 * Display contract for the `SubscriptionStatusCard` component.
 *
 * Pass `undefined` to render a skeleton loading state.
 * Monetary amounts are raw decimal numbers — the component formats them using `currency`.
 * Date values are ISO 8601 strings — the component formats them for display.
 *
 * `totalAmount` should come from `recurring_transaction_details.totals.total` —
 * this is the steady-state recurring amount (after discounts and tax).
 */
export type SubscriptionStatusData = {
  /** Paddle subscription ID, e.g. "sub_01abc..." */
  id?: string
  /** Subscription line items — auto-adapts layout for single vs multi-item */
  items: SubscriptionStatusItemData[]
  /** Recurring total as a decimal number, e.g. 49.99 */
  totalAmount: number
  /** ISO 4217 currency code, e.g. "USD" */
  currency: string
  /** Billing interval, e.g. "month" or "year" */
  interval: string
  /** Billing frequency. Defaults to 1. E.g. 3 for "every 3 months". */
  billingFrequency?: number
  status: SubscriptionStatus
  /** ISO 8601 subscription start date */
  startedAt: string
  /** ISO 8601 next billing date. Absent when paused or canceled. */
  nextBilledAt?: string
  /** ISO 8601 cancellation date. Present only when status is "canceled". */
  canceledAt?: string
  /**
   * Payment collection mode. From `subscription.collection_mode`.
   * "automatic" = auto-renew via saved payment method, "manual" = invoiced.
   */
  collectionMode?: "automatic" | "manual"
  scheduledChange?: {
    /** Type of scheduled change */
    action: "cancel" | "pause" | "resume"
    /** ISO 8601 date when the change takes effect */
    effectiveAt: string
    /** ISO 8601 date when the subscription resumes, only for pause actions with a set resume date */
    resumeAt?: string
  }
  /** Active discount, if any */
  discount?: {
    /** Discount savings amount as a decimal number, e.g. 5.00 */
    savingsAmount: number
    /** ISO 8601 date when the discount expires. Absent if discount recurs forever. */
    endsAt?: string
    /** Discount code, e.g. "SAVE20". From `discount.code`. */
    code?: string
    /** Discount description for billing summary, e.g. "-15%" or "-$5.00". API-provided or derived. */
    description?: string
  }
}

/**
 * Display contract for the `SubscriptionAlert` component.
 *
 * The component derives which alert to render from these fields.
 * Date values are ISO 8601 strings — the component formats them for display.
 * Pass `undefined` to render nothing.
 *
 * `updatePaymentMethodUrl` comes from `subscription.management_urls.update_payment_method`.
 * `trialEndsAt` comes from `subscription.items[0].trial_dates.ends_at`.
 */
export type SubscriptionAlertData = {
  status: SubscriptionStatus
  /** ISO 8601 cancellation date. Present when status is "canceled". */
  canceledAt?: string
  scheduledChange?: {
    /** Type of scheduled change */
    action: "cancel" | "pause" | "resume"
    /** ISO 8601 date when the change takes effect */
    effectiveAt: string
    /** ISO 8601 date when the subscription resumes, only for pause with a set resume date */
    resumeAt?: string
  }
  /** ISO 8601 trial end date. Present when status is "trialing". */
  trialEndsAt?: string
  /** Portal deep link to update payment method. Null for manual collection. */
  updatePaymentMethodUrl?: string
}

/**
 * Next payment details for the `SubscriptionPaymentCard` component.
 *
 * `amount` should come from `next_transaction.details.totals.grand_total`
 * (accounts for credits and adjustments) — pass as a decimal number (e.g. 29.99).
 * `currency` should come from `subscription.currency_code`.
 * `date` should come from `subscription.next_billed_at` as an ISO 8601 string.
 */
export type NextPaymentData = {
  /** Payment amount as a decimal number, e.g. 29.99 */
  amount: number
  /** ISO 4217 currency code, e.g. "USD" */
  currency: string
  /** ISO 8601 date string for the next billing date, e.g. "2025-02-01T00:00:00Z" */
  date: string
}

/**
 * Payment method details for the `SubscriptionPaymentCard` component.
 *
 * Pass the raw fields from `transaction.payments[0].method_details` directly —
 * the component resolves the display label automatically via `getPaymentMethodDisplay`.
 *
 * Sourced from the most recent completed transaction for the subscription
 * (not the saved payment methods API — see spec for sourcing details).
 *
 * @example
 * // From a completed Paddle transaction:
 * const payment = transaction.payments[0].methodDetails
 * paymentMethod={payment ? {
 *   type: payment.type,
 *   cardBrand: payment.card?.type,
 *   last4: payment.card?.last4,
 * } : undefined}
 */
export type PaymentMethodData = {
  /** Paddle payment method type from `method_details.type`, e.g. "card", "paypal", "apple_pay" */
  type: string
  /** Card brand from `method_details.card.type`, e.g. "visa", "mastercard". Card payments only. */
  cardBrand?: string
  /** Last 4 digits from `method_details.card.last4`, e.g. "4242". Card payments only. */
  last4?: string
  /** Card expiry month (1–12) from `method_details.card.expiry_month`. Card payments only. */
  expiryMonth?: number
  /** Card expiry year (4-digit) from `method_details.card.expiry_year`. Card payments only. */
  expiryYear?: number
  /**
   * Optional display label override. When provided, renders as-is instead of
   * auto-resolving from `type`/`cardBrand`/`last4`. Use for custom formats
   * (e.g. "Visa •••• 4242") or when you've already formatted the label upstream.
   */
  label?: string
}

/**
 * Display contract for the `PlanChangePreview` component.
 *
 * Sourced from the current subscription entity and the response from
 * `PATCH /subscriptions/{id}/preview`. Pass `undefined` to render a skeleton.
 *
 * Monetary amounts are raw decimal numbers — the component formats them using `currency`.
 * Date values are ISO 8601 strings — the component formats them for display.
 * UI labels and contextual messages belong on component props, not here.
 */
export type PlanChangePreviewData = {
  /** ISO 4217 currency code, e.g. "USD" */
  currency: string
  /** The plan being replaced */
  currentPlan: {
    /** Product name of the current plan */
    productName: string
    /** Current recurring total as a decimal number, e.g. 9.99 */
    price: number
    /** Current billing interval, e.g. "month" */
    interval: string
    /** Current billing frequency, defaults to 1 */
    billingFrequency?: number
  }
  /** The plan being switched to */
  newPlan: {
    /** Product name of the new plan */
    productName: string
    /** New recurring total as a decimal number, e.g. 29.99 */
    price: number
    /** New billing interval, e.g. "month" */
    interval: string
    /** New billing frequency, defaults to 1 */
    billingFrequency?: number
  }
  /** Financial impact of the plan change */
  costImpact: {
    /**
     * Direction of the net financial impact.
     * - `"charge"` — customer owes money (upgrade)
     * - `"credit"` — customer receives credit (downgrade)
     * - `"none"` — no financial movement (e.g. `do_not_bill` proration mode,
     *   trial upgrade, or paused subscription change)
     */
    resultDirection: "credit" | "charge" | "none"
    /** Net financial impact as a decimal number, e.g. 20.00. From `update_summary.result.amount`. */
    resultAmount: number
    /** Prorated credit for unused time on old plan as a decimal number. From `update_summary.credit.amount`. */
    credit?: number
    /** Prorated charge for new plan as a decimal number. From `update_summary.charge.amount`. */
    charge?: number
    /**
     * Amount charged immediately as a decimal number.
     * Present for `*_immediately` proration modes. From `immediate_transaction.details.totals.grand_total`.
     */
    immediateAmount?: number
    /**
     * Next bill total as a decimal number.
     * Present for `*_next_billing_period` proration modes. From `next_transaction.details.totals.grand_total`.
     */
    nextBillAmount?: number
    /** ISO 8601 next bill date. From `next_transaction.billing_period.starts_at`. */
    nextBillDate?: string
    /**
     * New steady-state recurring total as a decimal number after the change settles.
     * From `recurring_transaction_details.totals.total`.
     */
    newRecurringTotal: number
    /** New billing interval. From `billing_cycle.interval`. */
    newBillingInterval: string
    /** New billing frequency. From `billing_cycle.frequency`. Defaults to 1. */
    newBillingFrequency?: number
  }
  /** Active discount on the subscription. From `subscription.discount`. */
  discount?: {
    /** Discount description, e.g. "20% off" or "-$5.00". From `subscription.discount.description`. */
    description: string
    /** ISO 8601 expiry date. Absent if discount recurs forever. From `subscription.discount.ends_at`. */
    endsAt?: string
  }
  /** Pending scheduled change. From `subscription.scheduled_change`. */
  scheduledChange?: {
    /** Type of scheduled change */
    action: "cancel" | "pause" | "resume"
    /** ISO 8601 date when the change takes effect */
    effectiveAt: string
  }
  /**
   * Subscription status. From `subscription.status`.
   * Used by the component to render contextual messaging — e.g. a trial notice
   * when `status === "trialing"` and there is no immediate charge.
   */
  subscriptionStatus?: SubscriptionStatus
  /**
   * Payment collection mode. From `subscription.collection_mode`.
   * Used by the component to adapt labels — e.g. "Invoice amount" instead of
   * "Amount due now" when `collectionMode === "manual"`.
   */
  collectionMode?: "automatic" | "manual"
}

// ---
// Plan change breakdown types
// Display contract for the detailed financial breakdown component.
// Shows per-transaction line items, tax, proration, and totals.
// ---

/**
 * A single line item within a transaction preview.
 * Monetary amounts are raw decimal numbers — the component formats them
 * using the parent `PlanChangeBreakdownData.currency`.
 *
 * Maps to `details.line_items[]` (immediate/next transaction) or
 * `line_items[]` (recurring_transaction_details) in the preview response.
 */
export type PlanChangeLineItemData = {
  /** Product name, e.g. "Pro Plan". From `line_items[].product.name`. */
  productName: string
  /** Item quantity. From `line_items[].quantity`. */
  quantity: number
  /** Unit price as a decimal number, e.g. 49.00. From `line_items[].unit_totals.subtotal`. */
  unitPrice: number
  /** Line total as a decimal number, e.g. 26.95. From `line_items[].totals.total`. */
  total: number
  /** Whether this line item is prorated. Derived from `line_items[].proration !== null`. */
  isProrated?: boolean
  /** Proration period label, e.g. "15 of 31 days". Derived from `proration.rate` and `proration.billing_period`. */
  prorationPeriod?: string
}

/**
 * Totals breakdown for a single transaction section.
 * All values are raw decimal numbers — the component formats them using
 * the parent `PlanChangeBreakdownData.currency`.
 *
 * Maps to `details.totals` (immediate/next) or `totals` (recurring) in the preview response.
 */
export type PlanChangeTransactionTotalsData = {
  /** Subtotal as a decimal number (before discount, tax, and deductions). From `totals.subtotal`. */
  subtotal: number
  /** Discount amount as a decimal number. Present when a discount is active. From `totals.discount`. */
  discount?: number
  /** Tax amount as a decimal number. From `totals.tax`. */
  tax: number
  /** Credit applied to this transaction as a decimal number. From `totals.credit`. */
  credit?: number
  /** Surplus credit added to customer balance as a decimal number. From `totals.credit_to_balance`. */
  creditToBalance?: number
  /** Total due as a decimal number (after credits). From `totals.grand_total`. */
  total: number
}

/**
 * A complete transaction section (immediate, next, or recurring).
 * The section's position within `PlanChangeBreakdownData` determines its
 * role — the component derives titles and descriptions from that context.
 */
export type PlanChangeTransactionSectionData = {
  /**
   * ISO 8601 billing date for this transaction period.
   * Only relevant for `nextTransaction` — sourced from `billing_period.starts_at`.
   * Omitted for immediate and recurring sections.
   */
  billingDate?: string
  lineItems: PlanChangeLineItemData[]
  totals: PlanChangeTransactionTotalsData
}

/**
 * Display contract for the `PlanChangeBreakdown` component.
 *
 * Sourced from `PATCH /subscriptions/{id}/preview`. Pass `undefined` to render a skeleton.
 * Shows the full financial detail: per-transaction line items, tax, proration, and totals.
 */
export type PlanChangeBreakdownData = {
  /** ISO 4217 currency code, e.g. "USD" */
  currency: string
  /** Net financial result of the change. From `update_summary.result`. */
  result: {
    /**
     * Direction of the net result.
     * - `"charge"` — customer owes money (upgrade)
     * - `"credit"` — customer receives credit (downgrade)
     * - `"none"` — no financial movement
     */
    direction: "charge" | "credit" | "none"
    /** Net amount as a decimal number, e.g. 17.45. From `update_summary.result.amount`. */
    amount: number
  }
  /** Credit/charge breakdown from `update_summary` */
  breakdown?: {
    /** Credit from current plan as a decimal number. From `update_summary.credit`. */
    credit?: number
    /** Charge for new plan as a decimal number. From `update_summary.charge`. */
    charge?: number
  }
  /**
   * Immediate transaction details.
   * Present for `*_immediately` proration modes. From `immediate_transaction`.
   */
  immediateTransaction?: PlanChangeTransactionSectionData
  /** Next billing period transaction details. From `next_transaction`. */
  nextTransaction?: PlanChangeTransactionSectionData
  /** Recurring (steady-state) billing details. From `recurring_transaction_details`. */
  recurringTransaction?: PlanChangeTransactionSectionData
}
