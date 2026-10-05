import { Loader2 } from "lucide-react";
import { toast } from "sonner";
import { Button } from "@/components/ui/button";
import { useT } from "@/i18n/locale-provider";
import { msg } from "@/i18n/msg";
import { type SubscriptionDetail, useReverseCancel } from "../api/queries";

const ACTION_LABELS: Record<string, string> = {
	cancel: msg("Your plan cancels on {date}"),
	pause: msg("Your plan pauses on {date}"),
	resume: msg("Your plan resumes on {date}"),
};

// Hook isolated to its own component so the mutation state isn't allocated
// for non-cancel scheduled changes (pause/resume) where the button never
// renders. Tiny gain alone — pattern matters when the parent is in the
// always-mounted billing surface.
function ReverseCancelButton() {
	const { t } = useT();
	const reverseCancel = useReverseCancel();

	async function onReverse() {
		try {
			await reverseCancel.mutateAsync();
			toast.success(t("Cancellation reversed. Your subscription will keep renewing."));
		} catch {
			toast.error(t("Could not reverse the cancellation. Please try again."));
		}
	}

	return (
		<Button size="sm" onClick={onReverse} disabled={reverseCancel.isPending}>
			{Boolean(reverseCancel.isPending) && (
				<Loader2 aria-hidden className="size-3.5 animate-spin" />
			)}
			{reverseCancel.isPending ? t("Reversing…") : t("Keep my subscription")}
		</Button>
	);
}

export default function PendingChangeBanner({
	scheduledChange,
}: {
	scheduledChange: SubscriptionDetail["scheduled_change"];
}) {
	const { t } = useT();
	if (!scheduledChange) {
		return null;
	}

	const label = ACTION_LABELS[scheduledChange.action];
	const date = new Date(scheduledChange.effective_at).toLocaleDateString();

	return (
		<aside
			role="status"
			className="flex flex-wrap items-center justify-between gap-3 rounded-lg border border-border bg-secondary/50 p-4 text-sm"
		>
			<p className="font-medium text-foreground">
				{label ? t(label, { date }) : t("Your plan changes on {date}", { date })}
			</p>
			{scheduledChange.action === "cancel" && <ReverseCancelButton />}
		</aside>
	);
}
