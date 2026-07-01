import matter from 'gray-matter'
import { memo, useMemo } from 'react'
import ReactMarkdown, { defaultUrlTransform } from 'react-markdown'
import rehypeAutolinkHeadings from 'rehype-autolink-headings'
import rehypeHighlight from 'rehype-highlight'
import rehypeKatex from 'rehype-katex'
import rehypeSlug from 'rehype-slug'
import remarkCallouts from '@portaljs/remark-callouts'
import remarkGfm from 'remark-gfm'
import remarkMath from 'remark-math'
import remarkWikiLink from 'remark-wiki-link'
import { useIsFreeTier } from '../billing/use-is-free-tier'
import { AttachmentFallback } from './attachment-fallback'
import AttachmentImg from './attachment-img'
import MermaidBlock from './mermaid-block'

interface NoteViewProps {
  content: string
  tags: string[]
}

// Sentinel marks images rewritten from Obsidian `![[X]]` embed syntax. The
// img component reads it and fetches via the authenticated attachments API.
const ATTACHMENT_SCHEME = 'engram-attachment:'

function rewriteEmbeds(raw: string): string {
  return raw.replace(/!\[\[([^\]]+)\]\]/g, (_match, inner: string) => {
    const [path, alias] = inner.split('|').map((s) => s.trim())
    return `![${alias ?? path}](${ATTACHMENT_SCHEME}${path})`
  })
}

const remarkPlugins = [
  remarkGfm,
  remarkMath,
  remarkCallouts,
  [
    remarkWikiLink,
    {
      hrefTemplate: (permalink: string) => `/notes/${encodeURI(permalink)}`,
      aliasDivider: '|',
    },
  ],
] as const

const rehypePlugins = [
  rehypeSlug,
  [rehypeAutolinkHeadings, { behavior: 'append', properties: { className: 'anchor', ariaHidden: true, tabIndex: -1 } }],
  rehypeKatex,
  rehypeHighlight,
] as const

// Attachment file extensions are anything OTHER than markdown / canvas — those
// are first-class note types that should still link normally on Free.
const TEXT_EMBED = /\.(md|canvas)$/i

// memo: NotePage re-renders on every editor keystroke (draft state) while
// the preview stays force-mounted with identical props; react-markdown has
// no internal memoization, so an unmemoized NoteView re-ran the full
// remark/rehype pipeline (gfm + KaTeX + highlight) per keystroke.
function NoteView({ content, tags }: NoteViewProps) {
  const isFreeTier = useIsFreeTier()
  const body = useMemo(() => {
    try {
      return rewriteEmbeds(matter(content).content)
    } catch {
      return rewriteEmbeds(content)
    }
  }, [content])

  return (
    <article className="w-full">
      <header className="mb-6 empty:hidden">
        {tags.length > 0 && (
          <ul className="flex flex-wrap gap-1.5">
            {tags.map((tag) => (
              <li
                key={tag}
                className="rounded-full bg-secondary px-2 py-0.5 text-xs text-secondary-foreground"
              >
                #{tag}
              </li>
            ))}
          </ul>
        )}
      </header>
      <section className="prose prose-neutral max-w-none dark:prose-invert">
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
            code({ className, children, ...rest }) {
              const lang = /language-(\w+)/.exec(className ?? '')?.[1]
              const code = String(children).replace(/\n$/, '')
              if (lang === 'mermaid') {
                return <MermaidBlock code={code} />
              }
              return (
                <code className={className} {...rest}>
                  {children}
                </code>
              )
            },
            img({ src, alt }) {
              if (typeof src === 'string' && src.startsWith(ATTACHMENT_SCHEME)) {
                const path = src.slice(ATTACHMENT_SCHEME.length)
                // Free tier: gate any non-text attachment (images, pdfs, etc).
                // `.md` / `.canvas` embeds remain free-tier-allowed because
                // they're first-class note types, not stored attachments.
                if (isFreeTier && !TEXT_EMBED.test(path)) {
                  return <AttachmentFallback filename={path} />
                }
                return <AttachmentImg path={path} alt={alt} />
              }
              return <img src={src as string | undefined} alt={alt ?? ''} className="my-2 max-w-full rounded" />
            },
          }}
        >
          {body}
        </ReactMarkdown>
      </section>
    </article>
  )
}

export default memo(NoteView)
