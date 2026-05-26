import ReactMarkdown from "react-markdown"
import remarkGfm from "remark-gfm"

export function LegalDoc({ source }: { source: string }) {
  return (
    <div className="prose prose-sm dark:prose-invert max-w-none">
      <ReactMarkdown remarkPlugins={[remarkGfm]}>{source}</ReactMarkdown>
    </div>
  )
}
