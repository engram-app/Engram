import { Navigate, useLocation, useParams } from "react-router";
import { useSyncManifest } from "../api/queries";
import NotFoundPage from "../not-found";
import LoadingPane from "./loading-pane";
import { resolveWikiTarget } from "./wiki-link";

// `/:slug/wiki/<target>` — the landing route for every wikilink href. Wikilinks
// name a note by path or bare title, but note routes are id-keyed, so this
// resolves the target against the vault manifest (Obsidian rules: exact path,
// then vault-wide basename, shortest path wins) and bounces to `/:slug/:id`.
// The heading hash (already slugged by wikiHref) rides along untouched.
export default function WikiLinkRedirect() {
	const { slug, "*": target } = useParams();
	const location = useLocation();
	const { data: manifest, isPending } = useSyncManifest();

	if (isPending && !manifest) {
		return <LoadingPane />;
	}
	const note = resolveWikiTarget(target ?? "", manifest?.notes ?? []);
	if (!(note && slug)) {
		return <NotFoundPage />;
	}
	return <Navigate to={{ pathname: `/${slug}/${note.id}`, hash: location.hash }} replace />;
}
