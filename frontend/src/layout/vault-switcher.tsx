import { useQueryClient } from "@tanstack/react-query";
import { ChevronDown, Lock } from "lucide-react";
import { useEffect } from "react";
import {
	DropdownMenu,
	DropdownMenuContent,
	DropdownMenuRadioGroup,
	DropdownMenuRadioItem,
	DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu";
import { setActiveVaultId, useActiveVaultId } from "../api/active-vault";
import { type Vault, useVaults } from "../api/queries";

export default function VaultSwitcher() {
	const { data: vaults, isLoading } = useVaults();
	const activeId = useActiveVaultId();
	const qc = useQueryClient();

	useEffect(() => {
		if (!vaults || vaults.length === 0) return;
		const stillValid = activeId != null && vaults.some((v) => v.id === activeId);
		if (stillValid) return;
		const fallback = vaults.find((v) => v.is_default) ?? vaults[0];
		if (fallback) setActiveVaultId(fallback.id);
	}, [vaults, activeId]);

	if (isLoading) {
		return <p className="px-3 py-2 text-xs text-muted-foreground">Loading vaults…</p>;
	}
	if (!vaults || vaults.length === 0) {
		return <p className="px-3 py-2 text-xs text-muted-foreground">No vaults yet</p>;
	}

	const active = vaults.find((v) => v.id === activeId) ?? vaults[0]!;

	if (vaults.length === 1) return <VaultLabel vault={active} />;

	return (
		<section className="border-t border-border">
			<DropdownMenu>
				<DropdownMenuTrigger className="flex w-full items-center justify-between gap-2 px-3 py-2 text-left outline-none hover:bg-muted aria-expanded:bg-muted">
					<span className="min-w-0 flex-1">
						<span className="block text-[10px] font-medium uppercase tracking-wide text-muted-foreground">
							Vault
						</span>
						<span className="flex items-center gap-1.5 truncate text-sm font-medium text-foreground">
							{active.encrypted && <Lock className="size-3 shrink-0 text-muted-foreground" />}
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
						onValueChange={(v) => {
							const next = v;
							if (next === active.id) return;
							setActiveVaultId(next);
							qc.invalidateQueries();
							// Onboarding tour gates step 0 on a real switch; emit a DOM
							// event the controller can listen for without coupling layers.
							window.dispatchEvent(
								new CustomEvent("engram:vault-switched", {
									detail: { from: active.id, to: next },
								}),
							);
						}}
					>
						{vaults.map((v) => (
							<DropdownMenuRadioItem key={v.id} value={v.id}>
								{v.encrypted && <Lock className="mr-1 size-3 text-muted-foreground" />}
								<span className="truncate">{v.name}</span>
							</DropdownMenuRadioItem>
						))}
					</DropdownMenuRadioGroup>
				</DropdownMenuContent>
			</DropdownMenu>
		</section>
	);
}

function VaultLabel({ vault }: { vault: Vault }) {
	return (
		<section className="border-t border-border px-3 py-2">
			<p className="text-[10px] font-medium uppercase tracking-wide text-muted-foreground">Vault</p>
			<p className="flex items-center gap-1.5 truncate text-sm font-medium text-foreground">
				{vault.encrypted && <Lock className="size-3 shrink-0 text-muted-foreground" />}
				{vault.name}
			</p>
		</section>
	);
}
