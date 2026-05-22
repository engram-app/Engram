import { GripVertical } from "lucide-react"
import type { ComponentProps } from "react"
import * as ResizablePrimitive from "react-resizable-panels"

import { cn } from "@/lib/utils"

function ResizablePanelGroup({
  className,
  ...props
}: ComponentProps<typeof ResizablePrimitive.Group>) {
  return (
    <ResizablePrimitive.Group
      data-slot="resizable-panel-group"
      className={cn("h-full w-full", className)}
      {...props}
    />
  )
}

const ResizablePanel = ResizablePrimitive.Panel

function ResizableHandle({
  withHandle,
  className,
  ...props
}: ComponentProps<typeof ResizablePrimitive.Separator> & {
  withHandle?: boolean
}) {
  return (
    <ResizablePrimitive.Separator
      data-slot="resizable-handle"
      className={cn(
        "group/handle relative flex w-1 items-center justify-center bg-border transition-colors hover:bg-primary/40 active:bg-primary focus-visible:bg-primary/60 focus-visible:outline-hidden cursor-col-resize",
        "aria-[orientation=horizontal]:h-1 aria-[orientation=horizontal]:w-full aria-[orientation=horizontal]:cursor-row-resize",
        "[&[aria-orientation=horizontal]>div]:rotate-90",
        className,
      )}
      {...props}
    >
      {withHandle && (
        <div className="z-10 flex h-8 w-4 items-center justify-center rounded-md border border-border bg-card shadow-sm transition group-hover/handle:border-primary/60 group-active/handle:border-primary group-active/handle:bg-primary/10">
          <GripVertical className="size-3 text-muted-foreground group-hover/handle:text-foreground group-active/handle:text-primary" />
        </div>
      )}
    </ResizablePrimitive.Separator>
  )
}

export { ResizableHandle, ResizablePanel, ResizablePanelGroup }
