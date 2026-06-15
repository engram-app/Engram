import { Loader2 } from 'lucide-react'

// Centered loading state for full-pane content — route/lazy fallbacks, notes,
// and attachment previews. Fills the pane when it has a height and falls back to
// a sensible minimum otherwise, so the spinner lands in the middle instead of a
// bare "Loading…" in the top-left corner.
export default function LoadingPane({ label }: { label?: string }) {
  return (
    <div
      role="status"
      aria-busy="true"
      className="flex h-full min-h-[60vh] w-full flex-col items-center justify-center gap-3 text-muted-foreground"
    >
      <Loader2 aria-hidden className="size-8 animate-spin" />
      {label ? <p className="text-sm">{label}</p> : <span className="sr-only">Loading</span>}
    </div>
  )
}
