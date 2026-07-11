/**
 * Display name for a note: the filename without its extension.
 *
 * The web app always displays a note by its file name (Obsidian behavior),
 * never by the server-derived `title` (frontmatter/H1) — that field feeds
 * search and embeddings, not display.
 */
export function noteName(path: string): string {
	const base = path.split("/").pop() ?? path;
	const dot = base.lastIndexOf(".");
	return dot > 0 ? base.slice(0, dot) : base;
}
