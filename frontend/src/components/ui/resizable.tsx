import type { ComponentProps } from "react";
import * as ResizablePrimitive from "react-resizable-panels";

import { cn } from "@/lib/utils";

function ResizablePanelGroup({
	className,
	...props
}: ComponentProps<typeof ResizablePrimitive.Group>) {
	return (
		<ResizablePrimitive.Group
			data-slot="resizable-panel-group"
			className={cn("size-full", className)}
			// The invisible grab band around each 1px separator, in px.
			resizeTargetMinimumSize={{ coarse: 24, fine: 10 }}
			{...props}
		/>
	);
}

const ResizablePanel = ResizablePrimitive.Panel;

function ResizableHandle({
	className,
	...props
}: ComponentProps<typeof ResizablePrimitive.Separator>) {
	return (
		<ResizablePrimitive.Separator
			data-slot="resizable-handle"
			className={cn(
				// The separator IS the border: a hairline drawn as a real `border`, which
				// the browser snaps to one device pixel like every other border (a
				// background-filled 1 CSS px box paints as two on a 1.33x display), so
				// panels need no thick edge of their own to be grabbable. The grab zone is the Group's invisible
				// resizeTargetMinimumSize band around it, and `after` is the bar that
				// reveals itself over that band, driven by the library's own
				// `data-separator` state so the reveal always matches what a drag would hit.
				"relative z-10 w-px border-border border-l focus-visible:outline-hidden",
				"after:pointer-events-none after:absolute after:inset-y-0 after:left-1/2 after:w-1 after:-translate-x-1/2 after:rounded-full after:bg-primary/50 after:opacity-0 after:transition-opacity after:content-['']",
				"data-[separator=active]:after:bg-primary data-[separator=active]:after:opacity-100 data-[separator=focus]:after:opacity-100 data-[separator=hover]:after:opacity-100 data-[separator=hover]:after:delay-100",
				"aria-[orientation=horizontal]:h-px aria-[orientation=horizontal]:w-full aria-[orientation=horizontal]:border-t aria-[orientation=horizontal]:border-l-0",
				"aria-[orientation=horizontal]:after:inset-x-0 aria-[orientation=horizontal]:after:inset-y-auto aria-[orientation=horizontal]:after:top-1/2 aria-[orientation=horizontal]:after:h-1 aria-[orientation=horizontal]:after:w-full aria-[orientation=horizontal]:after:-translate-x-0 aria-[orientation=horizontal]:after:-translate-y-1/2",
				className,
			)}
			{...props}
		/>
	);
}

export { ResizableHandle, ResizablePanel, ResizablePanelGroup };
