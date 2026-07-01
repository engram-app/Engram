import { Pencil, Star, Trash2 } from "lucide-react";
import { useState } from "react";
import { toast } from "sonner";
import { useBillingStatus, useUpdateVault, useVaults, type Vault } from "@/api/queries";
import { Button } from "@/components/ui/button";
import { VaultCreateForm } from "@/components/vault-create-form";
import { useAutofocus } from "@/hooks/use-autofocus";
import { SettingsSectionCard } from "@/settings/account/section-card";
import { DeleteVaultDialog } from "./delete-vault-dialog";

const inputClass =
	"block w-full rounded-md border border-input bg-card px-2 py-1 text-sm text-foreground focus:border-ring focus:outline-none focus:ring-1 focus:ring-ring";

export function ActiveVaultsSection() {
	const { data: vaults, isLoading } = useVaults();
	const { data: billing } = useBillingStatus();
	const [deleteTarget, setDeleteTarget] = useState<Vault | null>(null);
	const [createOpen, setCreateOpen] = useState(false);

	const vaultsCap = billing?.caps.vaults ?? null;
	const vaultCount = vaults?.length ?? 0;
	const atCap = typeof vaultsCap === "number" && vaultsCap > 0 && vaultCount >= vaultsCap;
	const titleSuffix = vaultsCap == null ? "" : ` (${vaultCount} / ${vaultsCap})`;

	return (
		<SettingsSectionCard
			title={`Vaults${titleSuffix}`}
			description="Rename, set a default, or delete your vaults."
			headerAction={
				atCap ? undefined : (
					<Button onClick={() => setCreateOpen((o) => !o)}>
						{createOpen ? "Cancel" : "New vault"}
					</Button>
				)
			}
		>
			{atCap && (
				<aside className="mb-4 flex items-center justify-between gap-4 rounded-lg border border-amber-500/30 bg-amber-500/10 px-4 py-3">
					<p className="text-foreground text-sm">
						Your Free plan allows {vaultsCap} vault. Upgrade to Starter for more vaults.
					</p>
					<a
						href="/settings/billing"
						className="shrink-0 rounded-md bg-primary px-3 py-1.5 font-medium text-primary-foreground text-sm hover:bg-primary/90"
					>
						Upgrade
					</a>
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
			{isLoading && <p className="text-muted-foreground text-sm">Loading…</p>}
			<table className="w-full text-sm">
				<thead>
					<tr className="border-border border-b text-left text-muted-foreground text-xs">
						<th className="py-2 font-medium">Name</th>
						<th className="py-2 text-right font-medium">Files</th>
						<th className="py-2 text-right font-medium">Attachments</th>
						<th className="py-2" aria-label="Actions" />
					</tr>
				</thead>
				<tbody className="divide-y divide-border">
					{(vaults ?? []).map((v) => (
						<VaultRow key={v.id} vault={v} onDelete={() => setDeleteTarget(v)} />
					))}
					{!isLoading && (vaults ?? []).length === 0 && (
						<tr>
							<td colSpan={4} className="py-3 text-muted-foreground">
								No vaults yet.
							</td>
						</tr>
					)}
				</tbody>
			</table>

			{deleteTarget && (
				<DeleteVaultDialog
					vault={deleteTarget}
					open={deleteTarget !== null}
					onOpenChange={(open) => !open && setDeleteTarget(null)}
				/>
			)}
		</SettingsSectionCard>
	);
}

function VaultRow({ vault, onDelete }: { vault: Vault; onDelete: () => void }) {
	const update = useUpdateVault();
	const [renaming, setRenaming] = useState(false);
	const [name, setName] = useState(vault.name);
	const nameRef = useAutofocus<HTMLInputElement>(renaming);

	function saveName() {
		const next = name.trim();
		if (next && next !== vault.name) {
			update.mutate({ id: vault.id, name: next }, { onError: () => toast.error("Rename failed") });
		}
		setRenaming(false);
	}

	return (
		<tr>
			<td className="py-3">
				{renaming ? (
					<input
						ref={nameRef}
						className={inputClass}
						value={name}
						aria-label={`Rename ${vault.name}`}
						onChange={(e) => setName(e.target.value)}
						onBlur={saveName}
						onKeyDown={(e) => e.key === "Enter" && saveName()}
					/>
				) : (
					<span className="flex items-center gap-2">
						<span className="font-medium text-foreground">{vault.name}</span>
						{vault.is_default && (
							<span className="rounded bg-muted px-2 py-0.5 text-muted-foreground text-xs">
								Default
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
							title={`Set ${vault.name} as default`}
							aria-label={`Set ${vault.name} as default`}
							onClick={() =>
								update.mutate(
									{ id: vault.id, is_default: true },
									{ onError: () => toast.error("Could not set default") },
								)
							}
						>
							<Star />
						</Button>
					)}
					<Button
						variant="ghost"
						size="icon-sm"
						title={`Rename ${vault.name}`}
						aria-label={`Rename ${vault.name}`}
						onClick={() => setRenaming(true)}
					>
						<Pencil />
					</Button>
					<Button
						variant="destructive"
						size="icon-sm"
						title={`Delete ${vault.name}`}
						aria-label={`Delete ${vault.name}`}
						onClick={onDelete}
					>
						<Trash2 />
					</Button>
				</span>
			</td>
		</tr>
	);
}
