import GithubSlugger from "github-slugger";

// Obsidian-style wikilink resolution against the vault manifest. Pure module —
// the /:slug/wiki/* redirect route and both link producers (note-view's
// remark-wiki-link config, note-page's editor resolveWikiLink) share it.

const stripMd = (p: string) => p.replace(/\.md$/iu, "");

export interface ManifestNote {
	id: string;
	path: string;
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

// No slug = rendered outside a vault route (markdown reference panel) —
// nothing to resolve against, so the anchor stays inert.
export function wikiHref(raw: string, slug: string | undefined): string {
	const { page, hash } = parseWikiTarget(raw);
	if (!page) {
		return hash || "#";
	}
	if (!slug) {
		return "#";
	}
	const encoded = page.split("/").map(encodeURIComponent).join("/");
	return `/${slug}/wiki/${encoded}${hash}`;
}
