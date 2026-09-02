import { Navigate, useLocation } from "react-router";
import { getActiveVaultId } from "../api/active-vault";
import { useVaults } from "../api/queries";
import { preferredVault } from "../api/vault-slug";
import { EmptyVaultState } from "../layout/empty-vault-state";
import { vaultPath } from "../routes";
import LoadingPane from "./loading-pane";

// Bare `/` does not name a vault, so pick one: last-used, else default, else
// first. Search and hash are carried across so links like
// `/?highlight=<id>#settings/vaults` (the vault-deleted email) survive.
export default function VaultRedirect() {
	const { data: vaults, isPending } = useVaults();
	const location = useLocation();

	if (isPending && !vaults) {
		return <LoadingPane />;
	}
	const vault = preferredVault(vaults, getActiveVaultId());
	if (!vault) {
		return <EmptyVaultState />;
	}
	return (
		<Navigate
			to={{ pathname: vaultPath(vault.slug), search: location.search, hash: location.hash }}
			replace
		/>
	);
}
