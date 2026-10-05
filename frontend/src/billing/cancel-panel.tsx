import { Loader2 } from "lucide-react";
import { toast } from "sonner";
import { Button } from "@/components/ui/button";
import { useT } from "@/i18n/locale-provider";
import { msg } from "@/i18n/msg";
import { Trans } from "@/i18n/trans";
import type { SubscriptionDetail } from "../api/queries";
import { type BillingStatus, useCancelSubscription } from "../api/queries";

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
	const { t } = useT();
	const cancel = useCancelSubscription();

	// next_billed_at is the natural cancel-effective date when canceling
	// at-period-end. Falls back to a generic line if the backend has not yet
	// populated it (newly-subscribed user mid-webhook-sync).
	const effective = detail.next_billed_at
		? new Date(detail.next_billed_at).toLocaleDateString()
		: null;

	// Use the user's actual tier label in copy instead of hardcoding 'Pro' —
	// a Starter subscriber clicking cancel was reading 'You'll keep Pro
	// access' which looks like a tier-mismatch bug.
	const tierKey = TIER_LABELS[tier];
	const tierLabel = tierKey ? t(tierKey) : t("paid");

	async function confirm() {
		try {
			await cancel.mutateAsync();
			toast.success(t("Subscription scheduled to cancel."));
			onClose();
		} catch {
			toast.error(t("Could not cancel subscription. Please try again."));
		}
	}

	return (
		<section aria-label={t("Cancel subscription")} className="space-y-4 pt-2">
			<header>
				<h2 className="font-semibold text-base text-foreground">{t("Cancel subscription")}</h2>
				<p className="mt-2 text-muted-foreground text-sm">
					{effective ? (
						<Trans
							text="You'll keep your {tier} plan until {date}, then drop to Free."
							slots={{ tier: tierLabel, date: <strong>{effective}</strong> }}
						/>
					) : (
						t("You'll keep paid access through the end of your current billing period.")
					)}
				</p>
			</header>
			<ul className="list-disc space-y-1 pl-5 text-muted-foreground text-sm">
				<li>{t("Your notes stay. Sync still works for vaults within Free limits.")}</li>
				<li>{t("Vaults or notes that exceed Free limits become read-only.")}</li>
				<li>{t("You can reverse this any time before the effective date.")}</li>
			</ul>
			<div className="flex gap-2">
				<Button variant="destructive" onClick={confirm} disabled={cancel.isPending}>
					{Boolean(cancel.isPending) && <Loader2 aria-hidden className="size-4 animate-spin" />}
					{cancel.isPending ? t("Canceling…") : t("Cancel at period end")}
				</Button>
				<Button variant="ghost" onClick={onClose} disabled={cancel.isPending}>
					{t("Keep my subscription")}
				</Button>
			</div>
		</section>
	);
}
