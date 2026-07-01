import { formatDate } from "@/lib/paddle-format";
import type { SubscriptionAlertData } from "@/lib/paddle-types";

export type AlertVariant = "destructive" | "warning" | "info";

/**
 * Machine-readable reason identifier for the derived alert.
 *
 * Use this to key i18n translations, apply custom rendering logic, or
 * conditionally render additional UI without parsing the default English message.
 *
 * @example
 * const alert = deriveSubscriptionAlert(data)
 * if (alert) {
 *   const translated = t(`subscription.alert.${alert.reason}`, { date: ... })
 * }
 */
export type AlertReason =
	| "past_due" // P1: status === "past_due"
	| "canceled" // P2: status === "canceled"
	| "scheduled_cancel" // P3: scheduledChange.action === "cancel"
	| "scheduled_pause" // P4: scheduledChange.action === "pause"
	| "paused_resuming" // P5: status === "paused" + scheduledChange.action === "resume"
	| "paused" // P6: status === "paused", no scheduled resume
	| "trialing"; // P7: status === "trialing" + trialEndsAt present

export type DerivedAlert = {
	variant: AlertVariant;
	/**
	 * Machine-readable reason for this alert. Stable across versions — use to
	 * key i18n translations or apply custom logic without parsing `message`.
	 */
	reason: AlertReason;
	/** Default English message. Sufficient for most consumers out of the box. */
	message: string;
	actionLabel?: string;
	actionUrl?: string;
} | null;

/**
 * Derives the contextual alert for a subscription state.
 *
 * Evaluated in priority order; first match wins.
 * Returns `null` for healthy active subscriptions.
 *
 * @param data - Subscription alert data
 * @returns Alert descriptor with `reason` + default `message`, or null
 *
 * @example
 * deriveSubscriptionAlert({ status: "past_due", updatePaymentMethodUrl: "https://..." })
 * // { reason: "past_due", variant: "destructive", message: "Payment failed...", ... }
 *
 * @example i18n usage
 * const alert = deriveSubscriptionAlert(data)
 * if (alert) {
 *   const message = t(`subscription.alert.${alert.reason}`, { effectiveAt: data.scheduledChange?.effectiveAt })
 * }
 */
export function deriveSubscriptionAlert(data: SubscriptionAlertData | undefined): DerivedAlert {
	if (!data) return null;

	const { status, canceledAt, scheduledChange, trialEndsAt, updatePaymentMethodUrl } = data;

	// Priority 1: past_due
	if (status === "past_due") {
		return {
			reason: "past_due",
			variant: "destructive",
			message: updatePaymentMethodUrl
				? "Payment failed. Please update your payment method to avoid losing access."
				: "Payment failed. Please contact support to resolve your billing issue.",
			actionLabel: updatePaymentMethodUrl ? "Update payment method" : undefined,
			actionUrl: updatePaymentMethodUrl,
		};
	}

	// Priority 2: canceled
	if (status === "canceled") {
		return {
			reason: "canceled",
			variant: "destructive",
			message: canceledAt
				? `This subscription was canceled on ${formatDate(canceledAt)}.`
				: "This subscription has been canceled.",
		};
	}

	// Priority 3: scheduled_cancel
	if (scheduledChange?.action === "cancel") {
		return {
			reason: "scheduled_cancel",
			variant: "warning",
			message: `This subscription is scheduled to cancel on ${formatDate(scheduledChange.effectiveAt)}.`,
		};
	}

	// Priority 4: scheduled_pause
	if (scheduledChange?.action === "pause") {
		const message = scheduledChange.resumeAt
			? `This subscription will pause on ${formatDate(scheduledChange.effectiveAt)} and resume on ${formatDate(scheduledChange.resumeAt)}.`
			: `This subscription will pause on ${formatDate(scheduledChange.effectiveAt)}.`;
		return { reason: "scheduled_pause", variant: "warning", message };
	}

	// Priority 5: paused_resuming
	if (status === "paused" && scheduledChange?.action === "resume") {
		return {
			reason: "paused_resuming",
			variant: "info",
			message: `This subscription is paused. It will resume on ${formatDate(scheduledChange.effectiveAt)}.`,
		};
	}

	// Priority 6: paused
	if (status === "paused") {
		return {
			reason: "paused",
			variant: "info",
			message: "This subscription is paused.",
		};
	}

	// Priority 7: trialing
	if (status === "trialing" && trialEndsAt) {
		return {
			reason: "trialing",
			variant: "info",
			message: `Your trial ends on ${formatDate(trialEndsAt)}.`,
		};
	}

	// Priority 8: active — no alert
	return null;
}

// ---
// Mapping utility — Paddle API → SubscriptionAlertData display contract
// ---

type PaddleSubscription = {
	status: "active" | "canceled" | "past_due" | "paused" | "trialing";
	canceledAt?: string | null;
	scheduledChange?: {
		action: "cancel" | "pause" | "resume";
		effectiveAt: string;
		resumeAt?: string | null;
	} | null;
	items?: Array<{
		trialDates?: { endsAt?: string | null } | null;
	}>;
	managementUrls?: {
		updatePaymentMethod?: string | null;
	} | null;
};

/**
 * Maps a Paddle subscription API response to the `SubscriptionAlertData`
 * display contract consumed by `SubscriptionAlert`.
 *
 * @param subscription - Paddle Subscription
 * @returns Mapped alert data for `<SubscriptionAlert />`
 *
 * @example
 * const data = await paddle.subscriptions.get(subscriptionId)
 * const alertData = mapSubscriptionToAlertData(data)
 */
export function mapSubscriptionToAlertData(
	subscription: PaddleSubscription,
): SubscriptionAlertData {
	return {
		status: subscription.status,
		canceledAt: subscription.canceledAt ?? undefined,
		scheduledChange: subscription.scheduledChange
			? {
					action: subscription.scheduledChange.action,
					effectiveAt: subscription.scheduledChange.effectiveAt,
					resumeAt: subscription.scheduledChange.resumeAt ?? undefined,
				}
			: undefined,
		// Trial end date comes from the first item's trial dates
		trialEndsAt: subscription.items?.[0]?.trialDates?.endsAt ?? undefined,
		updatePaymentMethodUrl: subscription.managementUrls?.updatePaymentMethod ?? undefined,
	};
}
