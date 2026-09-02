import { Link, useParams } from "react-router";
import { useBacklinks } from "../api/queries";
import { noteName } from "../lib/note-name";
import { noteHref } from "../routes";

export default function BacklinksPanel({ noteId }: { noteId: string | null }) {
	const { slug } = useParams();
	const { data, isLoading } = useBacklinks(noteId);

	if (isLoading) {
		return null;
	}

	const backlinks = data ?? [];

	return (
		<nav aria-label="Backlinks" className="text-sm">
			<header className="border-border border-b px-3 py-2">
				<p className="font-medium text-[10px] text-muted-foreground uppercase tracking-wide">
					Backlinks
				</p>
			</header>
			{backlinks.length === 0 ? (
				<p className="px-3 py-2 text-muted-foreground text-xs">No backlinks yet</p>
			) : (
				<ul className="space-y-px py-2">
					{backlinks.map((b) => (
						<li key={b.source_note_id}>
							<Link
								to={noteHref(slug, b.source_note_id)}
								className="flex items-center gap-1 truncate rounded px-3 py-0.5 text-foreground/80 hover:bg-muted hover:text-foreground"
							>
								{b.source_title ?? noteName(b.source_path)}
							</Link>
						</li>
					))}
				</ul>
			)}
		</nav>
	);
}
