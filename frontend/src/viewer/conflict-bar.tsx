import { Button } from '@/components/ui/button'

interface ConflictBarProps {
  // Keep the local draft (already in the editor) and persist it over the
  // newly-adopted remote base.
  onKeepMine: () => void
  // Replace the draft with the incoming remote content.
  onTakeTheirs: () => void
  // Apply the 3-way merge WITH git-style conflict markers for manual resolution.
  onViewMerge: () => void
  // Dismiss without an explicit choice — keeps the draft (same as Keep mine).
  onDismiss: () => void
}

// Non-blocking conflict affordance. The default behavior on a conflicting
// remote change is to KEEP the local draft visible (never silently overwrite
// it with conflict markers); this bar gives the user agency to pick a
// resolution. It sits above the editor rather than overlaying it, so editing
// stays possible while it's shown.
export function ConflictBar({
  onKeepMine,
  onTakeTheirs,
  onViewMerge,
  onDismiss,
}: ConflictBarProps) {
  return (
    <aside
      role="status"
      aria-label="Conflicting change from another device"
      data-testid="conflict-bar"
      className="flex shrink-0 flex-wrap items-center gap-2 border-b border-border bg-muted px-4 py-2 text-xs text-muted-foreground"
    >
      <span className="min-w-0 flex-1">
        Another device changed this note in a way that conflicts with your unsaved edits.
      </span>
      <Button variant="ghost" size="sm" onClick={onKeepMine}>
        Keep mine
      </Button>
      <Button variant="ghost" size="sm" onClick={onTakeTheirs}>
        Take theirs
      </Button>
      <Button variant="ghost" size="sm" onClick={onViewMerge}>
        View merge
      </Button>
      <Button variant="ghost" size="sm" aria-label="Dismiss" onClick={onDismiss}>
        ✕
      </Button>
    </aside>
  )
}
