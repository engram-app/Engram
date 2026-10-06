import { Lock } from "lucide-react";

import { useUpgradeDialog } from "@/billing/upgrade-dialog-provider";
import { Button } from "@/components/ui/button";
import { useT } from "@/i18n/locale-provider";

// Free tier: rendered in place of `<img>` / `<embed>` for attachment embeds
// (`![[image.png]]`). Click surfaces the global UpgradeRequiredDialog so the
// reason → copy mapping in `limit-copy.ts` stays the single source of truth.
export function AttachmentFallback({ filename }: { filename: string }) {
	const { t } = useT();
	const { showUpgrade } = useUpgradeDialog();
	return (
		<Button
			type="button"
			variant="outline"
			data-testid="attachment-fallback-lock"
			onClick={() => showUpgrade("attachments_disabled")}
			title={t("Upgrade to view attachments")}
			className="my-2"
		>
			<Lock data-icon="inline-start" aria-hidden="true" />
			<span>{filename}</span>
		</Button>
	);
}
