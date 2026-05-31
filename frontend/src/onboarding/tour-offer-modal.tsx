import { useRef } from 'react'
import { Dialog, DialogContent, DialogDescription, DialogHeader, DialogTitle } from '../components/ui/dialog'
import { Button } from '../components/ui/button'

interface Props {
  onTake: () => void
  onSkip: () => void
}

export function TourOfferModal({ onTake, onSkip }: Props) {
  // Radix Dialog auto-focuses the first focusable child, which would be
  // the Skip button (it comes first in DOM order for visual reasons).
  // Steer focus to the primary CTA instead.
  const primaryRef = useRef<HTMLButtonElement>(null)

  return (
    <Dialog
      open
      onOpenChange={(o) => {
        if (!o) onSkip()
      }}
    >
      <DialogContent
        className="sm:max-w-md"
        onOpenAutoFocus={(e) => {
          e.preventDefault()
          primaryRef.current?.focus()
        }}
      >
        <DialogHeader>
          <DialogTitle>Want a quick tour?</DialogTitle>
          <DialogDescription>
            Two minutes. We&rsquo;ll walk through your vault, the editor, search, and where settings live.
          </DialogDescription>
        </DialogHeader>
        <div className="flex justify-end gap-2 pt-2">
          <Button variant="ghost" onClick={onSkip}>
            Skip
          </Button>
          <Button ref={primaryRef} onClick={onTake}>
            Take the tour
          </Button>
        </div>
      </DialogContent>
    </Dialog>
  )
}
