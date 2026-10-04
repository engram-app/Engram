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
import { useT } from "@/i18n/locale-provider";
import { SettingsSectionCard } from "@/settings/account/section-card";

function DeletedRow({ vault }: { vault: Vault }) {
	const { t } = useT();
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
								? t(
										"Restoring would exceed your vault limit. Upgrade or delete another vault first.",
									)
								: undefined
						}
						onClick={() =>
							restore.mutate(vault.id, {
								onSuccess: () => toast.success(t("Vault restored")),
								onError: () => toast.error(t("Could not restore (vault limit reached?)")),
							})
						}
					>
						<RotateCcw />
						{t("Restore")}
					</Button>
					<Button
						variant="destructive"
						size="icon-sm"
						title={t("Permanently delete {name}", { name: vault.name })}
						aria-label={t("Permanently delete {name}", { name: vault.name })}
						disabled={purge.isPending}
						onClick={() => {
							if (
								window.confirm(
									t('Permanently delete "{name}"? This cannot be undone.', { name: vault.name }),
								)
							) {
								purge.mutate(vault.id, {
									onSuccess: () => toast.success(t("Vault permanently deleted")),
									onError: () => toast.error(t("Could not delete")),
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

export function DeletedVaultsSection() {
	const { t } = useT();
	const { data: deleted } = useDeletedVaults();
	if (!deleted || deleted.length === 0) {
		return null;
	}

	return (
		<SettingsSectionCard
			title={t("Recently deleted")}
			description={t(
				"Deleted vaults are kept for 30 days. Restore them, or remove them permanently.",
			)}
		>
			<table className="w-full text-sm">
				<thead>
					<tr className="border-border border-b text-left text-muted-foreground text-xs">
						<th className="py-2 font-medium">{t("Name")}</th>
						<th className="py-2 text-right font-medium">{t("Files")}</th>
						<th className="py-2 text-right font-medium">{t("Attachments")}</th>
						<th className="py-2 font-medium">{t("Purges")}</th>
						<th className="py-2" aria-label={t("Actions")} />
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
