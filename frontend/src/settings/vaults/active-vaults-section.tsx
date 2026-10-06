import { Pencil, Star, Trash2 } from "lucide-react";
import { useState } from "react";
import { Link, useLocation } from "react-router";
import { toast } from "sonner";
import { useBillingStatus, useUpdateVault, useVaults, type Vault } from "@/api/queries";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { VaultCreateForm } from "@/components/vault-create-form";
import { useAutofocus } from "@/hooks/use-autofocus";
import { useT } from "@/i18n/locale-provider";
import { SettingsSectionCard } from "@/settings/account/section-card";
import { settingsTo } from "../settings-hash";
import { DeleteVaultDialog } from "./delete-vault-dialog";

function VaultRow({ vault, onDelete }: { vault: Vault; onDelete: () => void }) {
	const { t } = useT();
	const update = useUpdateVault();
	const [renaming, setRenaming] = useState(false);
	const [name, setName] = useState(vault.name);
	const nameRef = useAutofocus<HTMLInputElement>(renaming);

	function saveName() {
		const next = name.trim();
		if (next && next !== vault.name) {
			update.mutate(
				{ id: vault.id, name: next },
				{ onError: () => toast.error(t("Rename failed")) },
			);
		}
		setRenaming(false);
	}

	return (
		<tr>
			<td className="py-3">
				{renaming ? (
					<Input
						ref={nameRef}
						className="block"
						value={name}
						aria-label={t("Rename {name}", { name: vault.name })}
						onChange={(e) => setName(e.target.value)}
						onBlur={saveName}
						onKeyDown={(e) => e.key === "Enter" && saveName()}
					/>
				) : (
					<span className="flex items-center gap-2">
						<span className="font-medium text-foreground">{vault.name}</span>
						{Boolean(vault.is_default) && (
							<span className="rounded bg-muted px-2 py-0.5 text-muted-foreground text-xs">
								{t("Default")}
							</span>
						)}
					</span>
				)}
			</td>
			<td className="py-3 text-right text-muted-foreground tabular-nums">
				{vault.note_count ?? 0}
			</td>
			<td className="py-3 text-right text-muted-foreground tabular-nums">
				{vault.attachment_count ?? 0}
			</td>
			<td className="py-3">
				<span className="flex items-center justify-end gap-1">
					{!vault.is_default && (
						<Button
							variant="ghost"
							size="icon-sm"
							title={t("Set {name} as default", { name: vault.name })}
							aria-label={t("Set {name} as default", { name: vault.name })}
							onClick={() =>
								update.mutate(
									{ id: vault.id, is_default: true },
									{ onError: () => toast.error(t("Could not set default")) },
								)
							}
						>
							<Star />
						</Button>
					)}
					<Button
						variant="ghost"
						size="icon-sm"
						title={t("Rename {name}", { name: vault.name })}
						aria-label={t("Rename {name}", { name: vault.name })}
						onClick={() => setRenaming(true)}
					>
						<Pencil />
					</Button>
					<Button
						variant="destructive"
						size="icon-sm"
						title={t("Delete {name}", { name: vault.name })}
						aria-label={t("Delete {name}", { name: vault.name })}
						onClick={onDelete}
					>
						<Trash2 />
					</Button>
				</span>
			</td>
		</tr>
	);
}

export function ActiveVaultsSection() {
	const { t, tn } = useT();
	const { data: vaults, isLoading } = useVaults();
	const { data: billing } = useBillingStatus();
	const [deleteTarget, setDeleteTarget] = useState<Vault | null>(null);
	const [createOpen, setCreateOpen] = useState(false);
	const location = useLocation();

	const vaultsCap = billing?.caps.vaults ?? null;
	const vaultCount = vaults?.length ?? 0;
	const atCap = typeof vaultsCap === "number" && vaultsCap > 0 && vaultCount >= vaultsCap;
	const planLabel =
		billing?.tier === "pro" ? t("Pro") : billing?.tier === "starter" ? t("Starter") : t("Free");
	const title =
		vaultsCap === null
			? t("Vaults")
			: t("Vaults ({used} / {cap})", { used: vaultCount, cap: vaultsCap });

	return (
		<SettingsSectionCard
			title={title}
			description={t("Rename, set a default, or delete your vaults.")}
			headerAction={
				atCap ? undefined : (
					<Button
						variant={createOpen ? "outline" : "default"}
						onClick={() => setCreateOpen((o) => !o)}
					>
						{createOpen ? t("Cancel") : t("New vault")}
					</Button>
				)
			}
		>
			{Boolean(atCap) && (
				<aside className="mb-4 flex items-center justify-between gap-4 rounded-lg border border-amber-500/30 bg-amber-500/10 px-4 py-3">
					<p className="text-foreground text-sm">
						{/* Cap is per-tier (Free 1, Starter 10, Pro unlimited), so the
						    banner names the user's actual plan — it hardcoded "Free" and
						    told a Starter user at their cap that Free allowed that many.
						    An unlimited cap arrives as null, which `atCap` rejects via its
						    `typeof === "number"` guard, so this never renders for Pro. */}
						{tn(
							{
								one: "Your {plan} plan allows {count} vault. Upgrade for more vaults.",
								other: "Your {plan} plan allows {count} vaults. Upgrade for more vaults.",
							},
							vaultsCap ?? 0,
							{ plan: planLabel },
						)}
					</p>
					<Button asChild className="shrink-0">
						<Link to={settingsTo("billing", location.search)}>{t("Upgrade")}</Link>
					</Button>
				</aside>
			)}
			{createOpen && !atCap && (
				<section className="mb-4 rounded-lg border border-border bg-muted/30 p-4">
					<VaultCreateForm
						autoFocus
						showCancel
						onCancel={() => setCreateOpen(false)}
						onCreated={() => setCreateOpen(false)}
					/>
				</section>
			)}
			{Boolean(isLoading) && <p className="text-muted-foreground text-sm">{t("Loading…")}</p>}
			<table className="w-full text-sm">
				<thead>
					<tr className="border-border border-b text-left text-muted-foreground text-xs">
						<th className="py-2 font-medium">{t("Name")}</th>
						<th className="py-2 text-right font-medium">{t("Files")}</th>
						<th className="py-2 text-right font-medium">{t("Attachments")}</th>
						<th className="py-2" aria-label={t("Actions")} />
					</tr>
				</thead>
				<tbody className="divide-y divide-border">
					{(vaults ?? []).map((v) => (
						<VaultRow key={v.id} vault={v} onDelete={() => setDeleteTarget(v)} />
					))}
					{!isLoading && (vaults ?? []).length === 0 && (
						<tr>
							<td colSpan={4} className="py-3 text-muted-foreground">
								{t("No vaults yet.")}
							</td>
						</tr>
					)}
				</tbody>
			</table>

			{deleteTarget ? (
				<DeleteVaultDialog
					vault={deleteTarget}
					open={deleteTarget !== null}
					onOpenChange={(open) => !open && setDeleteTarget(null)}
				/>
			) : null}
		</SettingsSectionCard>
	);
}
