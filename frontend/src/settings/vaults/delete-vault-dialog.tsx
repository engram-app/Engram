import { Trash2 } from "lucide-react";
import { useState } from "react";
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
import { useT } from "@/i18n/locale-provider";
import { Trans } from "@/i18n/trans";

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
	const { t, tn } = useT();
	const del = useDeleteVault();
	const [phrase, setPhrase] = useState("");

	const noteCount = vault.note_count ?? 0;
	const attachmentCount = vault.attachment_count ?? 0;

	function confirmDelete() {
		del.mutate(vault.id, {
			onSuccess: () => {
				toast.success(t("Vault moved to trash"));
				onOpenChange(false);
			},
			onError: () => toast.error(t("Delete failed")),
		});
	}

	return (
		<Dialog
			open={open}
			onOpenChange={(next) => {
				// Clearing the typed phrase belongs to the close EVENT, not to a
				// synchronization effect watching `open`.
				if (!next) {
					setPhrase("");
				}
				onOpenChange(next);
			}}
		>
			<DialogContent>
				<DialogHeader>
					<DialogTitle>{t('Delete "{name}"?', { name: vault.name })}</DialogTitle>
					<DialogDescription>
						{t("This vault holds {notes} and {attachments}.", {
							notes: tn({ one: "{count} note", other: "{count} notes" }, noteCount),
							attachments: tn(
								{ one: "{count} attachment", other: "{count} attachments" },
								attachmentCount,
							),
						})}
					</DialogDescription>
				</DialogHeader>

				<ul className="space-y-2 text-muted-foreground text-sm">
					<li>
						<Trans
							text="It moves to trash and is {recoverable}, then permanently deleted."
							slots={{
								recoverable: (
									<strong className="text-foreground">{t("recoverable for 30 days")}</strong>
								),
							}}
						/>
					</li>
					<li>
						<Trans
							text="This only deletes the copy stored on Engram. Files already {synced} stay where they are."
							slots={{
								synced: <strong className="text-foreground">{t("synced to your devices")}</strong>,
							}}
						/>
					</li>
				</ul>

				<form
					onSubmit={(e) => {
						e.preventDefault();
						confirmDelete();
					}}
				>
					<label className="block text-foreground text-sm">
						{t('Type "{name}" to confirm', { name: vault.name })}
						<input
							autoFocus
							className={inputClass}
							value={phrase}
							onChange={(e) => setPhrase(e.target.value)}
						/>
					</label>
					<DialogFooter className="mt-4">
						<Button type="button" variant="ghost" size="sm" onClick={() => onOpenChange(false)}>
							{t("Cancel")}
						</Button>
						<Button
							type="submit"
							variant="destructive"
							size="sm"
							disabled={phrase !== vault.name || del.isPending}
						>
							<Trash2 />
							{t("Delete vault")}
						</Button>
					</DialogFooter>
				</form>
			</DialogContent>
		</Dialog>
	);
}
