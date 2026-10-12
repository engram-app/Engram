import { Loader2 } from "lucide-react";
import { useState } from "react";
import { toast } from "sonner";
import { Button } from "@/components/ui/button";
import {
	Dialog,
	DialogContent,
	DialogDescription,
	DialogFooter,
	DialogHeader,
	DialogTitle,
} from "@/components/ui/dialog";
import { EMPTY_REASON, ReasonFields, reasonComplete } from "@/feedback/reason-fields";
import { useT } from "@/i18n/locale-provider";
import { msg } from "@/i18n/msg";
import { Trans } from "@/i18n/trans";
import { intlLocale } from "@/lib/intl-locale";
import type { SubscriptionDetail } from "../api/queries";
import { type BillingStatus, useCancelSubscription, useSubmitFeedback } from "../api/queries";

const TIER_LABELS: Partial<Record<BillingStatus["tier"], string>> = {
	starter: msg("Starter"),
	pro: msg("Pro"),
};

interface CancelPanelProps {
	detail: SubscriptionDetail;
	tier: BillingStatus["tier"];
	onClose: () => void;
}

export default function CancelPanel({ detail, tier, onClose }: CancelPanelProps) {
	const { t, renderedLocale } = useT();
	const localeTag = intlLocale(renderedLocale);
	const cancel = useCancelSubscription();
	const submitFeedback = useSubmitFeedback();
	const [answer, setAnswer] = useState(EMPTY_REASON);

	// next_billed_at is the natural cancel-effective date when canceling
	// at-period-end. Falls back to a generic line if the backend has not yet
	// populated it (newly-subscribed user mid-webhook-sync).
	const effective = detail.next_billed_at
		? new Date(detail.next_billed_at).toLocaleDateString(localeTag)
		: null;

	// Use the user's actual tier label in copy instead of hardcoding 'Pro' —
	// a Starter subscriber clicking cancel was reading 'You'll keep Pro
	// access' which looks like a tier-mismatch bug.
	const tierKey = TIER_LABELS[tier];
	const tierLabel = tierKey ? t(tierKey) : t("paid");

	const canCancel = reasonComplete(answer);

	async function confirm() {
		if (!reasonComplete(answer)) {
			return;
		}
		try {
			await cancel.mutateAsync();
			// Only once the cancel landed, so a failed or retried cancel never
			// files a reason. Fire-and-forget: a React Query mutation outlives
			// the panel unmounting below.
			submitFeedback.mutate({
				kind: "cancel",
				reason: answer.reason,
				detail: answer.detail.trim(),
			});
			toast.success(t("Subscription scheduled to cancel."));
			onClose();
		} catch {
			toast.error(t("Could not cancel subscription. Please try again."));
		}
	}

	return (
		<Dialog
			open
			onOpenChange={(open) => {
				if (!(open || cancel.isPending)) {
					onClose();
				}
			}}
		>
			<DialogContent className="max-h-[90dvh] overflow-y-auto sm:max-w-2xl">
				<DialogHeader>
					<DialogTitle>{t("Cancel subscription")}</DialogTitle>
					<DialogDescription>
						{effective ? (
							<Trans
								text="You'll keep your {tier} plan until {date}, then drop to Free."
								slots={{ tier: tierLabel, date: <strong>{effective}</strong> }}
							/>
						) : (
							t("You'll keep paid access through the end of your current billing period.")
						)}
					</DialogDescription>
				</DialogHeader>
				<ul className="list-disc space-y-1 pl-5 text-muted-foreground text-sm">
					<li>{t("Your notes stay. Sync still works for vaults within Free limits.")}</li>
					<li>{t("Vaults or notes that exceed Free limits become read-only.")}</li>
					<li>{t("You can reverse this any time before the effective date.")}</li>
				</ul>
				<ReasonFields legend={t("Why are you canceling?")} value={answer} onChange={setAnswer} />
				<DialogFooter>
					<Button variant="outline" onClick={onClose} disabled={cancel.isPending}>
						{t("Keep my subscription")}
					</Button>
					<Button variant="destructive" onClick={confirm} disabled={!canCancel || cancel.isPending}>
						{Boolean(cancel.isPending) && (
							<Loader2 data-icon="inline-start" aria-hidden className="animate-spin" />
						)}
						{cancel.isPending ? t("Canceling…") : t("Cancel at period end")}
					</Button>
				</DialogFooter>
			</DialogContent>
		</Dialog>
	);
}
