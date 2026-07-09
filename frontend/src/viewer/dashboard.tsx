import { useEffect } from "react";
import { Link, useSearchParams } from "react-router";
import { type NoteSummary, useFolderNotes, useVaults } from "../api/queries";
import { EmptyVaultState } from "../layout/empty-vault-state";
import { useRightSidebar } from "../layout/right-sidebar-context";
import { noteName } from "../lib/note-name";
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
	return (
		<article className="border-gray-100 border-b py-3 last:border-0 dark:border-gray-800">
			<Link to={`/note/${note.id}`} className="block hover:text-blue-700">
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
	const { setContent: setRightContent } = useRightSidebar();

	// No note open still looks like an open (empty) document: mount the same
	// right-panel content an open note gets, so the panel chrome is present.
	const showEmptyDoc = !folder && vaults !== undefined && vaults.length > 0;
	useEffect(() => {
		if (!showEmptyDoc) {
			return;
		}
		setRightContent(<NoteToc content="" />);
		return () => setRightContent(null);
	}, [showEmptyDoc, setRightContent]);

	// Deleting the last vault leaves zero active vaults. Show a create-a-vault
	// prompt instead of the (empty) note browser. Guard against the loading
	// state (vaults === undefined) so the empty state doesn't flash while the
	// vault list is still in flight.
	if (vaults && vaults.length === 0) {
		return <EmptyVaultState />;
	}

	if (folder) {
		return (
			<section data-tour="dashboard-root">
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
			className="mx-auto flex h-full min-h-0 w-full min-w-0 max-w-[840px] flex-col overflow-hidden border-border border-x bg-card text-card-foreground md:-my-6 md:h-[calc(100%+3rem)]"
			data-tour="dashboard-root"
		>
			<p className="m-auto text-muted-foreground text-sm">No note is open</p>
		</section>
	);
}
