import { useQueryClient } from "@tanstack/react-query";
import { ChevronDown, Plus } from "lucide-react";
import { useState } from "react";
import { useNavigate } from "react-router";
import {
	Dialog,
	DialogContent,
	DialogDescription,
	DialogHeader,
	DialogTitle,
} from "@/components/ui/dialog";
import {
	DropdownMenu,
	DropdownMenuContent,
	DropdownMenuItem,
	DropdownMenuRadioGroup,
	DropdownMenuRadioItem,
	DropdownMenuSeparator,
	DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu";
import { VaultCreateForm } from "@/components/vault-create-form";
import { useActiveVaultId } from "../api/active-vault";
import { useVaults } from "../api/queries";

function VaultSwitcher() {
	const { data: vaults, isLoading } = useVaults();
	const activeId = useActiveVaultId();
	const qc = useQueryClient();
	const navigate = useNavigate();
	const [createOpen, setCreateOpen] = useState(false);

	if (isLoading) {
		return <p className="px-3 py-2 text-muted-foreground text-xs">Loading vaults…</p>;
	}
	if (!vaults || vaults.length === 0) {
		return <p className="px-3 py-2 text-muted-foreground text-xs">No vaults yet</p>;
	}

	const active = vaults.find((v) => v.id === activeId) ?? vaults[0]!;

	// Navigate; VaultRoute writes the active-vault store. Land on the vault
	// root, not the current note, whose id does not exist in the new vault.
	function openVault(slug: string) {
		navigate(`/${slug}`);
		qc.invalidateQueries();
	}

	return (
		<section className="border-border border-t">
			<DropdownMenu>
				<DropdownMenuTrigger className="flex w-full items-center justify-between gap-2 px-3 py-2 text-left outline-none hover:bg-muted aria-expanded:bg-muted">
					<span className="min-w-0 flex-1">
						<span className="block font-medium text-[10px] text-muted-foreground uppercase tracking-wide">
							Vault
						</span>
						<span className="block truncate font-medium text-foreground text-sm">
							{active.name}
						</span>
					</span>
					<ChevronDown className="size-4 shrink-0 text-muted-foreground transition-transform group-aria-expanded/dropdown-trigger:rotate-180" />
				</DropdownMenuTrigger>
				<DropdownMenuContent
					align="start"
					className="w-[var(--radix-dropdown-menu-trigger-width)] min-w-56"
				>
					<DropdownMenuRadioGroup
						value={active.id}
						onValueChange={(next) => {
							if (next === active.id) {
								return;
							}
							const target = vaults.find((v) => v.id === next);
							if (target) {
								openVault(target.slug);
							}
						}}
					>
						{vaults.map((v) => (
							<DropdownMenuRadioItem key={v.id} value={v.id}>
								<span className="truncate">{v.name}</span>
							</DropdownMenuRadioItem>
						))}
					</DropdownMenuRadioGroup>
					<DropdownMenuSeparator />
					<DropdownMenuItem onSelect={() => setCreateOpen(true)}>
						<Plus className="size-4" />
						New vault
					</DropdownMenuItem>
				</DropdownMenuContent>
			</DropdownMenu>

			<Dialog open={createOpen} onOpenChange={setCreateOpen}>
				<DialogContent className="sm:max-w-md">
					<DialogHeader>
						<DialogTitle>New vault</DialogTitle>
						<DialogDescription>
							A vault holds its own notes and folders, separate from your other vaults.
						</DialogDescription>
					</DialogHeader>
					<VaultCreateForm
						autoFocus
						showCancel
						submitLabel="Create vault"
						onCancel={() => setCreateOpen(false)}
						onCreated={(vault) => {
							setCreateOpen(false);
							openVault(vault.slug);
						}}
					/>
				</DialogContent>
			</Dialog>
		</section>
	);
}

export default VaultSwitcher;
