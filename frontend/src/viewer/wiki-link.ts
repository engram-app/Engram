import GithubSlugger from "github-slugger";

// Obsidian-style wikilink resolution against the vault manifest. Pure module —
// the /:slug/wiki/* redirect route and both link producers (note-view's
// remark-wiki-link config, note-page's editor resolveWikiLink) share it.

export const stripMd = (p: string) => p.replace(/\.md$/iu, "");

export interface ManifestNote {
	id: string;
	path: string;
}

// One entry per wikilink/embed the backend parsed out of a note's content
// (`GET /api/notes/by-id/:id` → `links`). Resolved links carry the target's
// note id; dangling ones (renamed/deleted/never-created target) don't.
export interface NoteLinkEdge {
	target_text: string;
	target_note_id: string | null;
	target_attachment_id: string | null;
	target_path: string | null;
	alias: string | null;
	anchor: string | null;
	link_type: "wikilink" | "embed";
	dangling: boolean;
}

// Keyed by lowercased target_text so wikiHref's lookup matches Obsidian's
// case-insensitive resolution. Dangling entries stay OUT of the map — a
// missing key and a dangling key both fall back to the wiki resolver route,
// so there's no reason to carry a target_note_id: null entry into the lookup.
export function buildWikiMap(links: NoteLinkEdge[] | undefined): Map<string, NoteLinkEdge> {
	const map = new Map<string, NoteLinkEdge>();
	for (const link of links ?? []) {
		if (!link.dangling && link.target_note_id) {
			map.set(link.target_text.toLowerCase(), link);
		}
	}
	return map;
}

// Split `Page#Heading` and slug the heading with the SAME slugger rehype-slug
// uses in Reading mode, so the hash actually lands on the rendered anchor.
export function parseWikiTarget(raw: string): { page: string; hash: string } {
	const [page = "", ...heading] = raw.split("#");
	const text = heading.join("#").trim();
	const hash = text ? `#${new GithubSlugger().slug(text)}` : "";
	return { page: page.trim(), hash };
}

// Exact path first (with or without `.md`), then Obsidian's vault-wide
// basename lookup — shortest path wins. All case-insensitive, like Obsidian.
export function resolveWikiTarget(page: string, notes: ManifestNote[]): ManifestNote | null {
	if (!page) {
		return null;
	}
	const wanted = stripMd(page).toLowerCase();
	const exact = notes.find((n) => stripMd(n.path).toLowerCase() === wanted);
	if (exact) {
		return exact;
	}
	const byName = notes
		.filter((n) => {
			const base = stripMd(n.path).split("/").at(-1) ?? "";
			return base.toLowerCase() === wanted;
		})
		.sort((a, b) => a.path.length - b.path.length);
	return byName[0] ?? null;
}

// Vault-root-relative create path for the unresolved-wikilink "create this
// note" affordance. Strips #heading/|alias via parseWikiTarget and any
// redundant .md, then splits on the last '/' — bare target creates at the
// vault root, path-qualified target creates (and implicitly folders) along
// that path, matching Obsidian's click-to-create behavior.
export function wikiCreatePath(raw: string): { folder: string; name: string } {
	const { page } = parseWikiTarget(raw);
	const segments = stripMd(page).split("/");
	const name = `${segments.pop() ?? ""}.md`;
	return { folder: segments.join("/"), name };
}

// No slug = rendered outside a vault route (markdown reference panel) —
// nothing to resolve against, so the anchor stays inert. Layered resolution:
// (1) a resolved entry in `map` (from buildWikiMap, server-indexed edges)
// short-circuits straight to the note id; (2) a miss there tries the sync
// manifest (client cache — covers freshly typed links whose edge isn't
// indexed yet); (3) only then the lazy /:slug/wiki/* redirect, kept for deep
// links and the create-affordance on truly nonexistent targets.
export function wikiHref(
	raw: string,
	slug: string | undefined,
	map?: Map<string, NoteLinkEdge>,
	manifestNotes?: ManifestNote[],
): string {
	const { page, hash } = parseWikiTarget(raw);
	if (!page) {
		return hash || "#";
	}
	if (!slug) {
		return "#";
	}
	const resolved = map?.get(page.toLowerCase());
	if (resolved?.target_note_id) {
		return `/${slug}/${resolved.target_note_id}${hash}`;
	}
	const fromManifest = manifestNotes ? resolveWikiTarget(page, manifestNotes) : null;
	if (fromManifest) {
		return `/${slug}/${fromManifest.id}${hash}`;
	}
	const encoded = page.split("/").map(encodeURIComponent).join("/");
	return `/${slug}/wiki/${encoded}${hash}`;
}
