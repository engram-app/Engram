import { Link, useSearchParams } from "react-router";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { type NoteSummary, useFolderNotes, useVaults } from "../api/queries";
import { EmptyVaultState } from "../layout/empty-vault-state";

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
					{note.title || note.path}
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

	return (
		<section
			aria-label="Welcome"
			className="flex h-full flex-col items-center justify-center px-6"
			data-tour="dashboard-root"
		>
			<Card className="max-w-md text-center">
				<CardHeader>
					<CardTitle className="text-xl">Welcome to Engram</CardTitle>
				</CardHeader>
				<CardContent className="space-y-1 text-muted-foreground text-sm">
					<p>Select a folder from the sidebar to browse your notes.</p>
					<p>
						Use the <strong className="font-semibold text-foreground">Search</strong> icon in the
						sidebar to find notes by keyword or semantic query.
					</p>
				</CardContent>
			</Card>
		</section>
	);
}
