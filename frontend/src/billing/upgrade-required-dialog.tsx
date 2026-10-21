import { Button } from "@/components/ui/button";
import {
	Dialog,
	DialogContent,
	DialogDescription,
	DialogFooter,
	DialogHeader,
	DialogTitle,
} from "@/components/ui/dialog";
import { useT } from "@/i18n/locale-provider";

import { ExistingConnectionsPanel } from "./existing-connections-panel";
import { copyFor } from "./limit-copy";
import { useOpenBilling } from "./use-open-billing";

function isConnectionCap(reason: string): "obsidian" | null {
	// concurrent_devices_exceeded (device-flow) and obsidian_connections_exceeded
	// (OAuth consent) both bottom out on Obsidian-kind grants — the user wants
	// to swap whichever one is occupying the slot.
	if (reason === "obsidian_connections_exceeded") {
		return "obsidian";
	}
	if (reason === "concurrent_devices_exceeded") {
		return "obsidian";
	}
	return null;
}

export interface UpgradeRequiredDialogProps {
	reason: string;
	open: boolean;
	onOpenChange: (open: boolean) => void;
}

export function UpgradeRequiredDialog({ reason, open, onOpenChange }: UpgradeRequiredDialogProps) {
	const { t } = useT();
	const openBilling = useOpenBilling("paywall");
	const { title, body } = copyFor(reason);
	const connKind = isConnectionCap(reason);

	return (
		<Dialog open={open} onOpenChange={onOpenChange}>
			<DialogContent>
				<DialogHeader>
					<DialogTitle>{t(title)}</DialogTitle>
					<DialogDescription>{t(body)}</DialogDescription>
				</DialogHeader>

				{connKind ? (
					<ExistingConnectionsPanel kind={connKind} onChanged={() => onOpenChange(false)} />
				) : null}

				<DialogFooter>
					<Button
						onClick={() => {
							onOpenChange(false);
							openBilling();
						}}
					>
						{t("Upgrade")}
					</Button>
				</DialogFooter>
			</DialogContent>
		</Dialog>
	);
}
