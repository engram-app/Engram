import type { Locale } from "@/i18n/locales";
import type { Translate } from "@/i18n/translate";
import { intlLocale } from "@/lib/intl-locale";
import { formatDate } from "@/lib/paddle-format";
import type { SubscriptionAlertData } from "@/lib/paddle-types";

// ---
// Mapping utility — Paddle API → SubscriptionAlertData display contract
// ---

interface PaddleSubscription {
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
}

export type AlertVariant = "destructive" | "warning" | "info";

/**
 * Machine-readable reason identifier for the derived alert.
 *
 * Use this to apply custom rendering logic or conditionally render additional
 * UI without parsing the (translated) message.
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
	 * apply custom logic without parsing `message`.
	 */
	reason: AlertReason;
	/** Message already translated through the `t` passed to deriveSubscriptionAlert. */
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
 * @param t - Translator from `useT()`
 * @param locale - `renderedLocale` from `useT()`, so dates read in the app language
 * @returns Alert descriptor with `reason` + translated `message`, or null
 *
 * @example
 * deriveSubscriptionAlert({ status: "past_due", updatePaymentMethodUrl: "https://..." }, t)
 * // { reason: "past_due", variant: "destructive", message: "Payment failed...", ... }
 */
export function deriveSubscriptionAlert(
	data: SubscriptionAlertData | undefined,
	t: Translate,
	locale: Locale = "en",
): DerivedAlert {
	if (!data) {
		return null;
	}
	const dateTag = intlLocale(locale, "en-US");

	const { status, canceledAt, scheduledChange, trialEndsAt, updatePaymentMethodUrl } = data;

	// Priority 1: past_due
	if (status === "past_due") {
		return {
			reason: "past_due",
			variant: "destructive",
			message: updatePaymentMethodUrl
				? t("Payment failed. Please update your payment method to avoid losing access.")
				: t("Payment failed. Please contact support to resolve your billing issue."),
			actionLabel: updatePaymentMethodUrl ? t("Update payment method") : undefined,
			actionUrl: updatePaymentMethodUrl,
		};
	}

	// Priority 2: canceled
	if (status === "canceled") {
		return {
			reason: "canceled",
			variant: "destructive",
			message: canceledAt
				? t("This subscription was canceled on {date}.", { date: formatDate(canceledAt, dateTag) })
				: t("This subscription has been canceled."),
		};
	}

	// Priority 3: scheduled_cancel
	if (scheduledChange?.action === "cancel") {
		return {
			reason: "scheduled_cancel",
			variant: "warning",
			message: t("This subscription is scheduled to cancel on {date}.", {
				date: formatDate(scheduledChange.effectiveAt, dateTag),
			}),
		};
	}

	// Priority 4: scheduled_pause
	if (scheduledChange?.action === "pause") {
		const message = scheduledChange.resumeAt
			? t("This subscription will pause on {date} and resume on {resumeDate}.", {
					date: formatDate(scheduledChange.effectiveAt, dateTag),
					resumeDate: formatDate(scheduledChange.resumeAt, dateTag),
				})
			: t("This subscription will pause on {date}.", {
					date: formatDate(scheduledChange.effectiveAt, dateTag),
				});
		return { reason: "scheduled_pause", variant: "warning", message };
	}

	// Priority 5: paused_resuming
	if (status === "paused" && scheduledChange?.action === "resume") {
		return {
			reason: "paused_resuming",
			variant: "info",
			message: t("This subscription is paused. It will resume on {date}.", {
				date: formatDate(scheduledChange.effectiveAt, dateTag),
			}),
		};
	}

	// Priority 6: paused
	if (status === "paused") {
		return {
			reason: "paused",
			variant: "info",
			message: t("This subscription is paused."),
		};
	}

	// Priority 7: trialing
	if (status === "trialing" && trialEndsAt) {
		return {
			reason: "trialing",
			variant: "info",
			message: t("Your trial ends on {date}.", { date: formatDate(trialEndsAt, dateTag) }),
		};
	}

	// Priority 8: active — no alert
	return null;
}

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
