import type { ReactNode } from 'react'
import { ScrollArea } from '@/components/ui/scroll-area'

// Shared surface for full-pane attachment previews (image, PDF). Mirrors the
// note view's reading column — a centered max-w-[840px] track with a ScrollArea
// — so files and notes share one visual frame. Callers render their own content
// (image / pdf pages) inside, centered with a shadow.
export default function PreviewColumn({ children }: { children: ReactNode }) {
  return (
    <section className="mx-auto -my-6 flex h-[calc(100%+3rem)] min-h-0 w-full min-w-0 max-w-[840px] flex-col overflow-hidden">
      <ScrollArea className="min-h-0 flex-1">{children}</ScrollArea>
    </section>
  )
}
