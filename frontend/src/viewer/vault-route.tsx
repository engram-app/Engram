import { useEffect } from "react";
import { Outlet, useParams } from "react-router";
import { setActiveVaultId, useActiveVaultId } from "../api/active-vault";
import { useVaults } from "../api/queries";
import { vaultBySlug } from "../api/vault-slug";
import NotFoundPage from "../not-found";
import LoadingPane from "./loading-pane";

// The URL is the source of truth for the active vault. This is the ONLY place
// that writes the store from a route; ~30 consumers (queries.ts, use-channel,
// folder-tree, trace, remote-log) read it unchanged.
export default function VaultRoute() {
	const { slug } = useParams();
	const { data: vaults, isPending } = useVaults();
	const activeId = useActiveVaultId();
	const vault = vaultBySlug(vaults, slug);

	useEffect(() => {
		if (vault) {
			setActiveVaultId(vault.id);
		}
	}, [vault]);

	// The list is normally already warm: useAppBootstrap seeds ["vaults"] and
	// runs in OnboardingGate, above this route. This only gates a genuine cold
	// fetch, and must come before the 404 so a slow list is not mistaken for a
	// bad slug.
	if (isPending && !vaults) {
		return <LoadingPane />;
	}
	if (!vault) {
		return <NotFoundPage />;
	}
	// Load-bearing: the effect above lands AFTER this render. Without the hold,
	// one pass escapes with the PREVIOUS vault id and every descendant query and
	// the channel join fire against the wrong vault.
	if (activeId !== vault.id) {
		return <LoadingPane />;
	}
	return <Outlet />;
}
