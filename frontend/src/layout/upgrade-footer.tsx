import { Sparkles } from "lucide-react";
import { Button } from "@/components/ui/button";
import { useT } from "@/i18n/locale-provider";
import { useOpenBilling } from "../billing/use-open-billing";
import { usePlan } from "../billing/use-plan";
import { useChecklistActive } from "../onboarding/checklist-widget";

/**
 * Free-only Upgrade row under the vault picker. It replaces the old text link
 * (#2009 removed it as too easy to miss and a second nudge beside the setup
 * checklist): a full-width button is easy to spot without shouting, and it
 * waits until the checklist, which carries its own "See paid plans" line,
 * has retired, so a screen never shows two upgrade nudges.
 */
export default function UpgradeFooter({ className }: { className?: string }) {
	const { t } = useT();
	const plan = usePlan();
	const checklistActive = useChecklistActive();
	const openBilling = useOpenBilling("sidebar_footer");

	if (plan?.tier !== "free" || checklistActive) {
		return null;
	}

	return (
		<div className={className}>
			<Button type="button" variant="outline" className="w-full gap-2" onClick={openBilling}>
				<Sparkles aria-hidden />
				{t("Upgrade")}
			</Button>
		</div>
	);
}
