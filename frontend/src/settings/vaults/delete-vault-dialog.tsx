import { Trash2 } from "lucide-react";
import { useEffect, useState } from "react";
import { toast } from "sonner";
import { useDeleteVault, type Vault } from "@/api/queries";
import { Button } from "@/components/ui/button";
import {
	Dialog,
	DialogContent,
	DialogDescription,
	DialogFooter,
	DialogHeader,
	DialogTitle,
} from "@/components/ui/dialog";

const inputClass =
	"mt-1 block w-full rounded-md border border-input bg-card px-3 py-2 text-sm text-foreground focus:border-ring focus:outline-none focus:ring-1 focus:ring-ring";

export function DeleteVaultDialog({
	vault,
	open,
	onOpenChange,
}: {
	vault: Vault;
	open: boolean;
	onOpenChange: (open: boolean) => void;
}) {
	const del = useDeleteVault();
	const [phrase, setPhrase] = useState("");

	useEffect(() => {
		if (!open) setPhrase("");
	}, [open]);

	const noteCount = vault.note_count ?? 0;
	const attachmentCount = vault.attachment_count ?? 0;

	function confirmDelete() {
		del.mutate(vault.id, {
			onSuccess: () => {
				toast.success("Vault moved to trash");
				onOpenChange(false);
			},
			onError: () => toast.error("Delete failed"),
		});
	}

	return (
		<Dialog open={open} onOpenChange={onOpenChange}>
			<DialogContent>
				<DialogHeader>
					<DialogTitle>Delete "{vault.name}"?</DialogTitle>
					<DialogDescription>
						This vault holds {noteCount} {noteCount === 1 ? "note" : "notes"} and {attachmentCount}{" "}
						{attachmentCount === 1 ? "attachment" : "attachments"}.
					</DialogDescription>
				</DialogHeader>

				<ul className="space-y-2 text-sm text-muted-foreground">
					<li>
						It moves to trash and is{" "}
						<strong className="text-foreground">recoverable for 30 days</strong>, then permanently
						deleted.
					</li>
					<li>
						This only deletes the copy stored on Engram. Files already{" "}
						<strong className="text-foreground">synced to your devices</strong> stay where they are.
					</li>
				</ul>

				<form
					onSubmit={(e) => {
						e.preventDefault();
						confirmDelete();
					}}
				>
					<label className="block text-sm text-foreground">
						Type "{vault.name}" to confirm
						<input
							autoFocus
							className={inputClass}
							value={phrase}
							onChange={(e) => setPhrase(e.target.value)}
						/>
					</label>
					<DialogFooter className="mt-4">
						<Button type="button" variant="ghost" size="sm" onClick={() => onOpenChange(false)}>
							Cancel
						</Button>
						<Button
							type="submit"
							variant="destructive"
							size="sm"
							disabled={phrase !== vault.name || del.isPending}
						>
							<Trash2 />
							Delete vault
						</Button>
					</DialogFooter>
				</form>
			</DialogContent>
		</Dialog>
	);
}
