import ReactMarkdown from 'react-markdown'
import rehypeHighlight from 'rehype-highlight'
import remarkGfm from 'remark-gfm'

interface NoteViewProps {
  content: string
  title: string
  tags: string[]
  updatedAt: string
}

export default function NoteView({ content, title, tags, updatedAt }: NoteViewProps) {
  return (
    <article>
      <header className="mb-6">
        <h1 className="text-2xl font-bold">{title}</h1>
        <p className="text-sm text-gray-500 dark:text-gray-400">
          Last updated: {new Date(updatedAt).toLocaleDateString()}
        </p>
        {tags.length > 0 && (
          <ul className="mt-2 flex flex-wrap gap-2">
            {tags.map((tag) => (
              <li key={tag} className="rounded bg-gray-100 dark:bg-gray-800 px-2 py-0.5 text-xs text-gray-600 dark:text-gray-300">
                {tag}
              </li>
            ))}
          </ul>
        )}
      </header>
      <section className="prose prose-sm max-w-none dark:prose-invert">
        <ReactMarkdown
          remarkPlugins={[remarkGfm]}
          rehypePlugins={[rehypeHighlight]}
        >
          {content}
        </ReactMarkdown>
      </section>
    </article>
  )
}
