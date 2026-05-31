import { Dialog, DialogContent, DialogDescription, DialogHeader, DialogTitle } from '../components/ui/dialog'
import { Button } from '../components/ui/button'

interface Props {
  onTake: () => void
  onSkip: () => void
}

export function TourOfferModal({ onTake, onSkip }: Props) {
  return (
    <Dialog
      open
      onOpenChange={(o) => {
        if (!o) onSkip()
      }}
    >
      <DialogContent className="sm:max-w-md">
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
          <Button onClick={onTake}>Take the tour</Button>
        </div>
      </DialogContent>
    </Dialog>
  )
}
