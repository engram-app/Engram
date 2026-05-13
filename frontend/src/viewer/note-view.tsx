import matter from 'gray-matter'
import { useMemo } from 'react'
import ReactMarkdown from 'react-markdown'
import rehypeAutolinkHeadings from 'rehype-autolink-headings'
import rehypeHighlight from 'rehype-highlight'
import rehypeKatex from 'rehype-katex'
import rehypeSlug from 'rehype-slug'
import remarkCallouts from '@portaljs/remark-callouts'
import remarkGfm from 'remark-gfm'
import remarkMath from 'remark-math'
import remarkWikiLink from 'remark-wiki-link'
import AttachmentImg from './attachment-img'
import MermaidBlock from './mermaid-block'

interface NoteViewProps {
  content: string
  title: string
  tags: string[]
  updatedAt: string
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

export default function NoteView({ content, title, tags, updatedAt }: NoteViewProps) {
  const { frontmatter, body } = useMemo(() => {
    try {
      const parsed = matter(content)
      return { frontmatter: parsed.data as Record<string, unknown>, body: rewriteEmbeds(parsed.content) }
    } catch {
      return { frontmatter: {}, body: rewriteEmbeds(content) }
    }
  }, [content])

  const frontmatterEntries = Object.entries(frontmatter).filter(([, v]) => v != null && v !== '')

  return (
    <article className="w-full px-4 py-6 sm:px-8 sm:py-8 lg:px-12 lg:py-10">
      <header className="mb-6 border-b border-border pb-4">
        <h1 className="mb-1 text-3xl font-bold tracking-tight text-foreground">{title}</h1>
        <p className="text-xs text-muted-foreground">
          Updated {new Date(updatedAt).toLocaleString()}
        </p>
        {tags.length > 0 && (
          <ul className="mt-3 flex flex-wrap gap-1.5">
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
        {frontmatterEntries.length > 0 && (
          <dl className="mt-3 grid grid-cols-[max-content_1fr] gap-x-3 gap-y-1 text-xs">
            {frontmatterEntries.map(([k, v]) => (
              <div key={k} className="contents">
                <dt className="font-medium text-muted-foreground">{k}</dt>
                <dd className="text-foreground/90">{String(Array.isArray(v) ? v.join(', ') : v)}</dd>
              </div>
            ))}
          </dl>
        )}
      </header>
      <section className="prose prose-neutral max-w-none dark:prose-invert lg:prose-lg">
        <ReactMarkdown
          remarkPlugins={remarkPlugins as never}
          rehypePlugins={rehypePlugins as never}
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
                return <AttachmentImg path={src.slice(ATTACHMENT_SCHEME.length)} alt={alt} />
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
