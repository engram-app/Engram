import { RotateCcw, Trash2 } from "lucide-react";
import { useSearchParams } from "react-router";
import { toast } from "sonner";
import {
	useBillingConfig,
	useDeletedVaults,
	usePurgeVault,
	useRestoreVault,
	useVaults,
	type Vault,
} from "@/api/queries";
import { Button } from "@/components/ui/button";
import { SettingsSectionCard } from "@/settings/account/section-card";

export function DeletedVaultsSection() {
	const { data: deleted } = useDeletedVaults();
	if (!deleted || deleted.length === 0) {
		return null;
	}

	return (
		<SettingsSectionCard
			title="Recently deleted"
			description="Deleted vaults are kept for 30 days. Restore them, or remove them permanently."
		>
			<table className="w-full text-sm">
				<thead>
					<tr className="border-border border-b text-left text-muted-foreground text-xs">
						<th className="py-2 font-medium">Name</th>
						<th className="py-2 text-right font-medium">Files</th>
						<th className="py-2 text-right font-medium">Attachments</th>
						<th className="py-2 font-medium">Purges</th>
						<th className="py-2" aria-label="Actions" />
					</tr>
				</thead>
				<tbody className="divide-y divide-border">
					{deleted.map((v) => (
						<DeletedRow key={v.id} vault={v} />
					))}
				</tbody>
			</table>
		</SettingsSectionCard>
	);
}

function DeletedRow({ vault }: { vault: Vault }) {
	const { data: active } = useVaults();
	const { data: billing } = useBillingConfig();
	const restore = useRestoreVault();
	const purge = usePurgeVault();

	const cap = billing?.vaults_cap ?? Number.POSITIVE_INFINITY;
	const activeCount = active?.length ?? 0;
	const overCap = activeCount >= cap;
	const purgeDate = vault.purge_at ? new Date(vault.purge_at).toLocaleDateString() : "—";

	const [searchParams] = useSearchParams();
	const highlighted = searchParams.get("highlight") === String(vault.id);

	return (
		<tr
			data-highlighted={highlighted || undefined}
			className={highlighted ? "bg-accent/40 ring-1 ring-ring" : ""}
		>
			<td className="py-3 font-medium text-foreground">{vault.name}</td>
			<td className="py-3 text-right text-muted-foreground tabular-nums">
				{vault.note_count ?? 0}
			</td>
			<td className="py-3 text-right text-muted-foreground tabular-nums">
				{vault.attachment_count ?? 0}
			</td>
			<td className="py-3 text-muted-foreground">{purgeDate}</td>
			<td className="py-3">
				<span className="flex items-center justify-end gap-1">
					<Button
						variant="outline"
						size="sm"
						disabled={overCap || restore.isPending}
						title={
							overCap
								? "Restoring would exceed your vault limit. Upgrade or delete another vault first."
								: undefined
						}
						onClick={() =>
							restore.mutate(vault.id, {
								onSuccess: () => toast.success("Vault restored"),
								onError: () => toast.error("Could not restore (vault limit reached?)"),
							})
						}
					>
						<RotateCcw />
						Restore
					</Button>
					<Button
						variant="destructive"
						size="icon-sm"
						title={`Permanently delete ${vault.name}`}
						aria-label={`Permanently delete ${vault.name}`}
						disabled={purge.isPending}
						onClick={() => {
							if (window.confirm(`Permanently delete "${vault.name}"? This cannot be undone.`)) {
								purge.mutate(vault.id, {
									onSuccess: () => toast.success("Vault permanently deleted"),
									onError: () => toast.error("Could not delete"),
								});
							}
						}}
					>
						<Trash2 />
					</Button>
				</span>
			</td>
		</tr>
	);
}
