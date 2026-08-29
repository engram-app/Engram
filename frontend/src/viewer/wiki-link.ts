import GithubSlugger from "github-slugger";
import { vaultPath } from "../routes";

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
		return `${vaultPath(slug, resolved.target_note_id)}${hash}`;
	}
	const fromManifest = manifestNotes ? resolveWikiTarget(page, manifestNotes) : null;
	if (fromManifest) {
		return `${vaultPath(slug, fromManifest.id)}${hash}`;
	}
	const encoded = page.split("/").map(encodeURIComponent).join("/");
	return `${vaultPath(slug)}/wiki/${encoded}${hash}`;
}

// Markdown-syntax link resolution (#1302). Obsidian writes
// `[label](Target.md)` instead of `[[Target]]` when "Use [[Wikilinks]]" is
// off, and the backend indexes both as note_links edges — so the viewer
// resolves them through the SAME two layers wikiHref uses (indexed edge,
// then sync manifest) rather than emitting a plain <a> that full-page
// navigates to a path which isn't a route.
//
// Two deliberate differences from wikiHref:
//   * the href arrives percent-encoded (`My%20Note.md`) while `target_text`
//     and manifest paths are decoded, so it is decoded before lookup;
//   * an UNRESOLVED target returns null (caller leaves the plain <a>) rather
//     than falling through to the /:slug/wiki/* create affordance. A markdown
//     link can legitimately point at an attachment or a relative file, and
//     offering to create a note for those would be wrong.
//
// Returns null for anything that isn't a vault-relative note reference.
export function markdownLinkHref(
	href: string | undefined,
	slug: string | undefined,
	map?: Map<string, NoteLinkEdge>,
	manifestNotes?: ManifestNote[],
): string | null {
	if (!(href && slug)) {
		return null;
	}
	// Absolute app route, external scheme, protocol-relative, or same-page
	// anchor — all already correct as plain hrefs.
	if (/^(?:[a-z][a-z0-9+.-]*:|\/\/|\/|#)/iu.test(href)) {
		return null;
	}

	let decoded: string;
	try {
		decoded = decodeURI(href);
	} catch {
		// Malformed escape — treat the href as literal rather than throwing.
		decoded = href;
	}

	const { page, hash } = parseWikiTarget(decoded);
	if (!page) {
		return null;
	}

	const resolved = map?.get(page.toLowerCase());
	if (resolved?.target_note_id) {
		return `${vaultPath(slug, resolved.target_note_id)}${hash}`;
	}
	const fromManifest = manifestNotes ? resolveWikiTarget(page, manifestNotes) : null;
	return fromManifest ? `${vaultPath(slug, fromManifest.id)}${hash}` : null;
}
