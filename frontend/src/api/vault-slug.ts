import { useActiveVaultId } from "./active-vault";
import type { Vault } from "./queries";
import { useVaults } from "./queries";

// Lives in active-vault (the store it feeds) so `reconcileActiveVault` can use
// it without an import cycle through this module. Re-exported here because the
// redirect components have always read it from vault-slug.
export { preferredVault } from "./active-vault";

export function vaultBySlug(vaults: Vault[] | undefined, slug: string | undefined): Vault | null {
	if (!(vaults && slug)) {
		return null;
	}
	return vaults.find((v) => v.slug === slug) ?? null;
}

// Slug of the vault currently in the store, for building note hrefs. Returns
// null only before the vault list lands, which in practice does not happen
// inside AppLayout (useAppBootstrap seeds it above).
export function useActiveVaultSlug(): string | null {
	const vaults = useVaults().data;
	const activeId = useActiveVaultId();
	return vaults?.find((v) => v.id === activeId)?.slug ?? null;
}
