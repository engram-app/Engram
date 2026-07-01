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
			className={cn("h-full w-full", className)}
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
				// 2px hairline; a transparent `before` overlay widens the grab zone
				// without changing layout or the visible width.
				"relative w-0.5 cursor-col-resize bg-border transition-colors hover:bg-primary/40 focus-visible:bg-primary/60 focus-visible:outline-hidden active:bg-primary",
				"before:absolute before:inset-y-0 before:left-1/2 before:w-3 before:-translate-x-1/2 before:content-['']",
				"aria-[orientation=horizontal]:h-0.5 aria-[orientation=horizontal]:w-full aria-[orientation=horizontal]:cursor-row-resize",
				"aria-[orientation=horizontal]:before:inset-x-0 aria-[orientation=horizontal]:before:inset-y-auto aria-[orientation=horizontal]:before:top-1/2 aria-[orientation=horizontal]:before:h-3 aria-[orientation=horizontal]:before:w-full aria-[orientation=horizontal]:before:-translate-x-0 aria-[orientation=horizontal]:before:-translate-y-1/2",
				className,
			)}
			{...props}
		/>
	);
}

export { ResizableHandle, ResizablePanel, ResizablePanelGroup };
