// Single source of truth for the onboarding tour's fake vault ids.
//
// These are client-only fixtures. `active-vault.ts` must never persist them (a
// persisted demo id poisons the real active vault: every request then ships
// `X-Vault-Id: demo-vault-N` and the backend 404s), and `queries.ts` synthesizes
// the fake vaults from this prefix. Keeping the prefix in one place stops the two
// from drifting apart and silently reopening that bug.
//
// Leaf module with no imports so both `active-vault.ts` (api layer) and
// `demo-vault-provider.tsx` (onboarding layer) can depend on it without a cycle.
export const DEMO_VAULT_ID_PREFIX = "demo-vault-";

export function isDemoVaultId(id: string | null | undefined): boolean {
	return id?.startsWith(DEMO_VAULT_ID_PREFIX) ?? false;
}
