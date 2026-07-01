import { useNavigate } from "react-router";

import { Button } from "@/components/ui/button";
import {
	Dialog,
	DialogContent,
	DialogDescription,
	DialogFooter,
	DialogHeader,
	DialogTitle,
} from "@/components/ui/dialog";

import { ExistingConnectionsPanel } from "./existing-connections-panel";
import { copyFor } from "./limit-copy";

export interface UpgradeRequiredDialogProps {
	reason: string;
	open: boolean;
	onOpenChange: (open: boolean) => void;
}

function isConnectionCap(reason: string): "mcp" | "obsidian" | null {
	if (reason === "mcp_connections_exceeded") return "mcp";
	// concurrent_devices_exceeded (device-flow) and obsidian_connections_exceeded
	// (OAuth consent) both bottom out on Obsidian-kind grants — the user wants
	// to swap whichever one is occupying the slot.
	if (reason === "obsidian_connections_exceeded") return "obsidian";
	if (reason === "concurrent_devices_exceeded") return "obsidian";
	return null;
}

export function UpgradeRequiredDialog({ reason, open, onOpenChange }: UpgradeRequiredDialogProps) {
	const navigate = useNavigate();
	const { title, body } = copyFor(reason);
	const connKind = isConnectionCap(reason);

	return (
		<Dialog open={open} onOpenChange={onOpenChange}>
			<DialogContent>
				<DialogHeader>
					<DialogTitle>{title}</DialogTitle>
					<DialogDescription>{body}</DialogDescription>
				</DialogHeader>

				{connKind ? (
					<ExistingConnectionsPanel kind={connKind} onChanged={() => onOpenChange(false)} />
				) : null}

				<DialogFooter>
					<Button
						onClick={() => {
							onOpenChange(false);
							navigate("/settings/billing");
						}}
					>
						Upgrade
					</Button>
				</DialogFooter>
			</DialogContent>
		</Dialog>
	);
}
