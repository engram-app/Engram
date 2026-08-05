import remarkCallouts from "@portaljs/remark-callouts";
import matter from "gray-matter";
import { type CSSProperties, memo, useMemo } from "react";
import ReactMarkdown, { defaultUrlTransform } from "react-markdown";
import { Link, useParams } from "react-router";
import rehypeAutolinkHeadings from "rehype-autolink-headings";
import rehypeHighlight from "rehype-highlight";
import rehypeKatex from "rehype-katex";
import rehypeSlug from "rehype-slug";
import remarkGfm from "remark-gfm";
import remarkMath from "remark-math";
import remarkWikiLink from "remark-wiki-link";
// hljs + KaTeX styles ride this lazy chunk, not the eager main stylesheet.
import "./markdown.css";
import { useIsFreeTier } from "../billing/use-is-free-tier";
import { AttachmentFallback } from "./attachment-fallback";
import AttachmentImg from "./attachment-img";
import MermaidBlock from "./mermaid-block";
import { buildWikiMap, type ManifestNote, type NoteLinkEdge, wikiHref } from "./wiki-link";

interface NoteViewProps {
	content: string;
	tags: string[];
	// Optional: the markdown reference panel's preview call site renders
	// outside a note context and has no links to resolve — wikilinks there
	// fall back to the lazy /:slug/wiki/* route same as before this prop existed.
	links?: NoteLinkEdge[];
	// Optional second resolution layer (see wikiHref): the sync manifest covers
	// freshly typed links whose server-indexed edge isn't in `links` yet.
	// NotePage threads its already-subscribed useSyncManifest data; the
	// reference panel omits it (no vault context to resolve against anyway).
	manifestNotes?: ManifestNote[];
}

// Sentinel marks images rewritten from Obsidian `![[X]]` embed syntax. The
// img component reads it and fetches via the authenticated attachments API.
const ATTACHMENT_SCHEME = "engram-attachment:";

function rewriteEmbeds(raw: string): string {
	return raw.replace(/!\[\[(?<inner>[^\]]+)\]\]/gu, (_match, inner: string) => {
		const [path, alias] = inner.split("|").map((s) => s.trim());
		return `![${alias ?? path}](${ATTACHMENT_SCHEME}${path})`;
	});
}

// Slug-parameterized: wikilinks route through the vault-scoped resolver
// (`/:slug/wiki/*`, see wiki-link.ts). pageResolver is identity — the default
// would mangle names (`My Note` → `my_note`) before the resolver ever saw them.
const remarkPluginsFor = (
	slug: string | undefined,
	map: Map<string, NoteLinkEdge>,
	manifestNotes?: ManifestNote[],
) =>
	[
		remarkGfm,
		remarkMath,
		remarkCallouts,
		[
			remarkWikiLink,
			{
				pageResolver: (name: string) => [name],
				hrefTemplate: (permalink: string) => wikiHref(permalink, slug, map, manifestNotes),
				aliasDivider: "|",
			},
		],
	] as const;

const rehypePlugins = [
	rehypeSlug,
	[
		rehypeAutolinkHeadings,
		{ behavior: "append", properties: { className: "anchor", ariaHidden: true, tabIndex: -1 } },
	],
	rehypeKatex,
	rehypeHighlight,
] as const;

// Attachment file extensions are anything OTHER than markdown / canvas — those
// are first-class note types that should still link normally on Free.
const TEXT_EMBED = /\.(?:md|canvas)$/iu;

// memo: NotePage re-renders on every editor keystroke (draft state) while
// the preview stays force-mounted with identical props; react-markdown has
// no internal memoization, so an unmemoized NoteView re-ran the full
// remark/rehype pipeline (gfm + KaTeX + highlight) per keystroke.
function NoteView({ content, tags, links, manifestNotes }: NoteViewProps) {
	const isFreeTier = useIsFreeTier();
	const { slug } = useParams();
	const wikiMap = useMemo(() => buildWikiMap(links), [links]);
	// TanStack's structural sharing keeps manifestNotes referentially stable
	// across no-change refetches, so this memo (and the memo(NoteView) above
	// it) only re-runs when the manifest actually changed.
	const remarkPlugins = useMemo(
		() => remarkPluginsFor(slug, wikiMap, manifestNotes),
		[slug, wikiMap, manifestNotes],
	);
	const body = useMemo(() => {
		try {
			return rewriteEmbeds(matter(content).content);
		} catch {
			return rewriteEmbeds(content);
		}
	}, [content]);

	return (
		<article className="w-full">
			<header className="mb-6 empty:hidden">
				{tags.length > 0 && (
					<ul className="flex flex-wrap gap-1.5">
						{tags.map((tag) => (
							<li
								key={tag}
								className="rounded-full bg-secondary px-2 py-0.5 text-secondary-foreground text-xs"
							>
								#{tag}
							</li>
						))}
					</ul>
				)}
			</header>
			<section className="prose prose-neutral dark:prose-invert max-w-none">
				<ReactMarkdown
					remarkPlugins={remarkPlugins as never}
					rehypePlugins={rehypePlugins as never}
					// react-markdown@10 strips URLs with schemes outside its safe list;
					// preserve our internal `engram-attachment:` sentinel so the img
					// component override can route it to AttachmentImg / fallback.
					urlTransform={(url) =>
						url.startsWith(ATTACHMENT_SCHEME) ? url : defaultUrlTransform(url)
					}
					components={{
						// In-app hrefs (wikilinks) go through the router — a plain <a>
						// would full-page-reload the SPA on every note hop.
						a({ node: _node, href, children, ...rest }) {
							if (href?.startsWith("/")) {
								return (
									<Link to={href} {...rest}>
										{children}
									</Link>
								);
							}
							return (
								<a href={href} {...rest}>
									{children}
								</a>
							);
						},
						code({ node: _node, className, children, ...rest }) {
							const lang = /language-(?<lang>\w+)/u.exec(className ?? "")?.[1];
							const code = String(children).replace(/\n$/u, "");
							if (lang === "mermaid") {
								return <MermaidBlock code={code} />;
							}
							return (
								<code className={className} {...rest}>
									{children}
								</code>
							);
						},
						// remark-callouts inlines `border-left-color` per type, from the same
						// map the CodeMirror live preview reads. Republish it as a custom
						// property so CSS can reuse that exact colour (for the title text)
						// without keeping a second palette that drifts from it.
						blockquote({ node: _node, children, ...rest }) {
							const style = rest.style as CSSProperties | undefined;
							const color = style?.borderLeftColor;
							return (
								<blockquote
									{...rest}
									style={color ? ({ ...style, "--callout-color": color } as CSSProperties) : style}
								>
									{children}
								</blockquote>
							);
						},
						// The library ALSO inlines a tinted background on the callout title.
						// The editor's live preview has no such bar, and an inline style
						// cannot be overridden from a stylesheet without !important — so it
						// gets dropped here instead.
						div({ node: _node, className, children, ...rest }) {
							const cls = String(className ?? "");
							if (cls.includes("callout-title")) {
								const { style: _tint, ...untinted } = rest as Record<string, unknown>;
								return (
									<div className={cls} {...untinted}>
										{children}
									</div>
								);
							}
							return (
								<div className={className} {...rest}>
									{children}
								</div>
							);
						},
						img({ src, alt }) {
							if (typeof src === "string" && src.startsWith(ATTACHMENT_SCHEME)) {
								const path = src.slice(ATTACHMENT_SCHEME.length);
								// Free tier: gate any non-text attachment (images, pdfs, etc).
								// `.md` / `.canvas` embeds remain free-tier-allowed because
								// they're first-class note types, not stored attachments.
								if (isFreeTier && !TEXT_EMBED.test(path)) {
									return <AttachmentFallback filename={path} />;
								}
								return <AttachmentImg path={path} alt={alt} />;
							}
							return (
								<img
									src={src as string | undefined}
									alt={alt ?? ""}
									className="my-2 max-w-full rounded"
								/>
							);
						},
					}}
				>
					{body}
				</ReactMarkdown>
			</section>
		</article>
	);
}

export default memo(NoteView);
