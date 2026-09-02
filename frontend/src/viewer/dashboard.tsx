import { useMemo } from "react";
import { Link, Navigate, useSearchParams } from "react-router";
import { type NoteSummary, useFolderNotes, useSyncManifest, useVaults } from "../api/queries";
import { useActiveVaultSlug } from "../api/vault-slug";
import { EmptyVaultState } from "../layout/empty-vault-state";
import { useRightToolSlot } from "../layout/right-tools-context";
import { noteName } from "../lib/note-name";
import { noteHref } from "../routes";
import LoadingPane from "./loading-pane";
import NoteToc from "./note-toc";

function formatDate(iso: string): string {
	return new Date(iso).toLocaleDateString(undefined, {
		year: "numeric",
		month: "short",
		day: "numeric",
	});
}

interface NoteRowProps {
	note: NoteSummary;
}

function NoteRow({ note }: NoteRowProps) {
	const slug = useActiveVaultSlug();
	return (
		<article className="border-gray-100 border-b py-3 last:border-0 dark:border-gray-800">
			<Link to={noteHref(slug, note.id)} className="block hover:text-blue-700">
				<h3 className="font-medium text-gray-900 text-sm dark:text-gray-100">
					{noteName(note.path) || note.path}
				</h3>
			</Link>
			<footer className="mt-1 flex flex-wrap items-center gap-3 text-gray-500 text-xs dark:text-gray-400">
				{Boolean(note.folder) && <span>{note.folder}</span>}
				{note.tags.length > 0 && (
					<ul className="flex gap-1" aria-label="Tags">
						{note.tags.map((tag) => (
							<li
								key={tag}
								className="rounded bg-gray-100 px-1.5 py-0.5 text-gray-600 dark:bg-gray-800 dark:text-gray-300"
							>
								{tag}
							</li>
						))}
					</ul>
				)}
				<time dateTime={note.updated_at}>{formatDate(note.updated_at)}</time>
			</footer>
		</article>
	);
}

function FolderNotes({ folder }: { folder: string }) {
	const { data: notes, isLoading, isError } = useFolderNotes(folder);

	if (isLoading) {
		return <p className="text-gray-500 text-sm dark:text-gray-400">Loading…</p>;
	}
	if (isError) {
		return <p className="text-red-600 text-sm dark:text-red-400">Failed to load notes.</p>;
	}
	if (!notes || notes.length === 0) {
		return <p className="text-gray-500 text-sm dark:text-gray-400">No notes in this folder.</p>;
	}

	return (
		<section aria-label={`Notes in ${folder}`}>
			<ul>
				{notes.map((note) => (
					<li key={note.path}>
						<NoteRow note={note} />
					</li>
				))}
			</ul>
		</section>
	);
}

export default function Dashboard() {
	const [searchParams] = useSearchParams();
	const folder = searchParams.get("folder") ?? "";
	const { data: vaults } = useVaults();
	const slug = useActiveVaultSlug();
	// A vault holding exactly ONE note opens it instead of showing an empty
	// pane. That is every brand-new vault: `Engram.Vaults.WelcomeNote` seeds
	// "Welcome to Engram.md" on create, and landing on "No note is open" with a
	// welcome note sitting unread one click away is the wrong first screen.
	//
	// Deliberately keyed on the COUNT, not on the welcome note's path: the path
	// lives in Elixir, and a frontend copy of it would drift silently and take
	// this behavior with it. One note means there is nothing to choose between.
	// Self-disables the moment a second note exists, or the note is deleted.
	const { data: manifest, isPending: manifestPending } = useSyncManifest();
	const onlyNote = manifest?.notes?.length === 1 ? manifest.notes[0] : null;
	// Once per vault per tab. Two reasons, one mechanism:
	//
	// 1. NotePage bounces a 404'd note back to the vault root (note-page.tsx,
	//    `navigate(vaultRootHref(slug), {replace: true})`). With an unconditional
	//    redirect, a manifest that still lists that note sends the user straight
	//    back to it — the two ping-pong until React throws "Maximum update depth
	//    exceeded". Having fired once, this stops.
	// 2. A vault the user deliberately keeps at one note would otherwise be
	//    impossible to view the root of at all.
	//
	// sessionStorage, not a ref: NotePage and Dashboard are different route
	// elements, so navigating between them remounts this component.
	// Keyed on the slug rather than the vault id: the slug is already in hand
	// here and identifies the vault just as well. A rename re-arms the auto-open
	// once, which is harmless.
	const autoOpenKey = slug ? `engram:auto-opened:${slug}` : null;
	const alreadyOpened = autoOpenKey !== null && sessionStorage.getItem(autoOpenKey) === "1";

	// No note open still looks like an open (empty) document: mount the same
	// right-panel content an open note gets, so the panel chrome is present.
	const showEmptyDoc = !folder && vaults !== undefined && vaults.length > 0;
	const emptyToc = useMemo(() => (showEmptyDoc ? <NoteToc content="" /> : null), [showEmptyDoc]);
	useRightToolSlot("outline", emptyToc);

	// Deleting the last vault leaves zero active vaults. Show a create-a-vault
	// prompt instead of the (empty) note browser. Guard against the loading
	// state (vaults === undefined) so the empty state doesn't flash while the
	// vault list is still in flight.
	if (vaults && vaults.length === 0) {
		return <EmptyVaultState />;
	}

	// Only at the true vault root — a ?folder= browse is a deliberate
	// destination, not a landing.
	if (!folder) {
		// Hold rather than paint "No note is open" and then yank it away: on a
		// brand-new vault that flash IS the whole first impression.
		if (manifestPending && !manifest) {
			return <LoadingPane />;
		}
		if (onlyNote && slug && !alreadyOpened) {
			if (autoOpenKey) {
				sessionStorage.setItem(autoOpenKey, "1");
			}
			return <Navigate to={noteHref(slug, onlyNote.id)} replace />;
		}
	}

	if (folder) {
		return (
			<section>
				<header className="mb-4">
					<h2 className="font-semibold text-base text-gray-800 dark:text-gray-200">{folder}</h2>
				</header>
				<FolderNotes folder={folder} />
			</section>
		);
	}

	// Empty document — the same pane shell NotePage renders, with nothing open.
	return (
		<section
			aria-label="No note open"
			className="mx-auto flex size-full min-h-0 min-w-0 max-w-[840px] flex-col overflow-hidden border-border border-x bg-card text-card-foreground md:-my-6 md:h-[calc(100%+3rem)]"
		>
			<p className="m-auto text-muted-foreground text-sm">No note is open</p>
		</section>
	);
}
