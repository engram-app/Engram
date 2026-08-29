import { Navigate, useLocation, useParams } from "react-router";
import { getActiveVaultId } from "../api/active-vault";
import { useVaults } from "../api/queries";
import { preferredVault } from "../api/vault-slug";
import NotFoundPage from "../not-found";
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
	if (!(vault && id)) {
		return <NotFoundPage />;
	}
	return (
		<Navigate
			to={{ pathname: vaultPath(vault.slug, id), search: location.search, hash: location.hash }}
			replace
		/>
	);
}
