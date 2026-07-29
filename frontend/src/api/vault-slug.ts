import type { Vault } from "./queries";

export function vaultBySlug(vaults: Vault[] | undefined, slug: string | undefined): Vault | null {
	if (!(vaults && slug)) {
		return null;
	}
	return vaults.find((v) => v.slug === slug) ?? null;
}

// Used only where the URL does NOT name a vault: the bare `/` redirect and the
// legacy `/note/:id` redirect. `hintId` is the last-used vault (localStorage via
// the active-vault store); it is a hint, not authority, so a stale id silently
// degrades to the default vault.
export function preferredVault(vaults: Vault[] | undefined, hintId: string | null): Vault | null {
	if (!vaults || vaults.length === 0) {
		return null;
	}
	return (
		(hintId ? vaults.find((v) => v.id === hintId) : undefined) ??
		vaults.find((v) => v.is_default) ??
		vaults[0] ??
		null
	);
}
