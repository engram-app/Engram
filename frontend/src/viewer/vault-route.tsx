import { useEffect } from "react";
import { Navigate, Outlet, useParams } from "react-router";
import { toast } from "sonner";
import { setActiveVaultId, useActiveVaultId } from "../api/active-vault";
import { useVaults } from "../api/queries";
import { vaultBySlug } from "../api/vault-slug";
import { ROUTES } from "../routes";
import LoadingPane from "./loading-pane";

// A slug that names none of the user's vaults: a typo, a renamed vault, or a
// link from someone else's account. This renders INSIDE the app shell, so a
// full-page 404 ends up nested in the content pane beside a sidebar still
// showing the previous vault. Say what happened and hand off to `/`, which
// picks the vault to land on — the same way a missing note lands on its vault
// root.
function UnknownVault({ slug }: { slug: string }) {
	useEffect(() => {
		// Fixed id: StrictMode runs this twice in dev, and sonner dedupes by id.
		toast.error(`No vault named "${slug}".`, { id: `unknown-vault:${slug}` });
	}, [slug]);
	return <Navigate to={ROUTES.HOME} replace />;
}

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
		return <UnknownVault slug={slug ?? ""} />;
	}
	// Load-bearing: the effect above lands AFTER this render. Without the hold,
	// one pass escapes with the PREVIOUS vault id and every descendant query and
	// the channel join fire against the wrong vault.
	if (activeId !== vault.id) {
		return <LoadingPane />;
	}
	return <Outlet />;
}
