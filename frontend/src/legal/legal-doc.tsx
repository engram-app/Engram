import ReactMarkdown from "react-markdown"
import remarkGfm from "remark-gfm"

export function LegalDoc({ source }: { source: string }) {
  return (
    <div className="prose prose-sm dark:prose-invert max-w-none prose-h1:text-lg prose-h1:mb-2 prose-h2:text-base prose-h2:mb-1 prose-h2:mt-6 prose-h2:border-t prose-h2:border-border prose-h2:pt-4 prose-h3:mb-1 prose-h3:mt-5 prose-h3:text-sm">
      <ReactMarkdown remarkPlugins={[remarkGfm]}>{source}</ReactMarkdown>
    </div>
  )
}
