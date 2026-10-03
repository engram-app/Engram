import { Navigate, useLocation, useParams } from "react-router";
import { getActiveVaultId } from "../api/active-vault";
import { useVaults } from "../api/queries";
import { preferredVault } from "../api/vault-slug";
import { EmptyVaultState } from "../layout/empty-vault-state";
import { vaultPath } from "../routes";
import LoadingPane from "./loading-pane";

// Old `/note/:id` links. A note id alone does not name its vault, so this is
// best effort: resolve the last-used vault and rewrite. If the note actually
// lives elsewhere the note fetch 404s, which is exactly what happened before
// this change, so no regression. A server-side note-to-vault lookup would make
// it exact and is deliberately out of scope.
export default function LegacyNoteRedirect() {
	const { id } = useParams();
	const { data: vaults, isPending } = useVaults();
	const location = useLocation();

	if (isPending && !vaults) {
		return <LoadingPane />;
	}
	const vault = preferredVault(vaults, getActiveVaultId());
	// No vault to rewrite into. Same state `/` shows; a full-page 404 here
	// would render nested inside the app shell. (`id` is always set: the route
	// is `/note/:id`.)
	if (!(vault && id)) {
		return <EmptyVaultState />;
	}
	return (
		<Navigate
			to={{ pathname: vaultPath(vault.slug, id), search: location.search, hash: location.hash }}
			replace
		/>
	);
}
