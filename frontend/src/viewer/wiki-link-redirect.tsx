import { Navigate, useLocation, useNavigate, useParams } from "react-router";
import { Button } from "@/components/ui/button";
import { heading } from "@/lib/ui-classes";
import { useCreateNote, useSyncManifest } from "../api/queries";
import { uuid7 } from "../crdt/uuid7";
import AuthPanel from "../layout/auth-panel";
import AuthShell from "../layout/auth-shell";
import NotFoundPage from "../not-found";
import LoadingPane from "./loading-pane";
import { resolveWikiTarget, stripMd, wikiCreatePath } from "./wiki-link";

// `/:slug/wiki/<target>` — the landing route for every wikilink href. Wikilinks
// name a note by path or bare title, but note routes are id-keyed, so this
// resolves the target against the vault manifest (Obsidian rules: exact path,
// then vault-wide basename, shortest path wins) and bounces to `/:slug/:id`.
// The heading hash (already slugged by wikiHref) rides along untouched.
//
// Unresolved (dangling) targets get an inline "create this note" affordance
// instead of a dead-end 404 — Obsidian parity. Creating goes through the same
// useCreateNote mutation the sidebar "New note" button uses, so success
// navigation and failure toasts come for free; the dangling edges self-heal
// server-side once the note exists.
export default function WikiLinkRedirect() {
	const { slug, "*": target } = useParams();
	const location = useLocation();
	const navigate = useNavigate();
	const { data: manifest, isPending } = useSyncManifest();
	const createNote = useCreateNote();

	if (isPending && !manifest) {
		return <LoadingPane />;
	}
	const note = resolveWikiTarget(target ?? "", manifest?.notes ?? []);
	if (note && slug) {
		return <Navigate to={{ pathname: `/${slug}/${note.id}`, hash: location.hash }} replace />;
	}
	// Route always provides :slug in practice; this guard just keeps the type
	// narrowed for the mutate() call below, same as the old resolved-branch check.
	if (!slug) {
		return <NotFoundPage />;
	}

	const { folder, name } = wikiCreatePath(target ?? "");
	const title = stripMd(name);

	return (
		<AuthShell>
			<AuthPanel className="flex flex-col items-center gap-4 text-center">
				<h1 className={heading}>"{title}" doesn't exist yet.</h1>
				<div className="mt-2 flex flex-wrap items-center justify-center gap-3">
					<Button variant="outline" onClick={() => navigate(-1)}>
						Back
					</Button>
					<Button
						onClick={() => createNote.mutate({ folder, id: uuid7(), name })}
						disabled={createNote.isPending}
					>
						Create "{title}"
					</Button>
				</div>
			</AuthPanel>
		</AuthShell>
	);
}
