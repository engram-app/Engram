import { Popover as PopoverPrimitive } from "radix-ui";
import type * as React from "react";

import { cn } from "@/lib/utils";

function Popover({ ...props }: React.ComponentProps<typeof PopoverPrimitive.Root>) {
	return <PopoverPrimitive.Root data-slot="popover" {...props} />;
}

function PopoverTrigger({ ...props }: React.ComponentProps<typeof PopoverPrimitive.Trigger>) {
	return <PopoverPrimitive.Trigger data-slot="popover-trigger" {...props} />;
}

function PopoverAnchor({ ...props }: React.ComponentProps<typeof PopoverPrimitive.Anchor>) {
	return <PopoverPrimitive.Anchor data-slot="popover-anchor" {...props} />;
}

function PopoverContent({
	className,
	align = "center",
	sideOffset = 4,
	children,
	...props
}: React.ComponentProps<typeof PopoverPrimitive.Content>) {
	return (
		<PopoverPrimitive.Portal>
			<PopoverPrimitive.Content
				data-slot="popover-content"
				align={align}
				sideOffset={sideOffset}
				// collisionPadding keeps a wide popover off the viewport edge when the
				// trigger sits in a narrow side panel, which is where these live.
				collisionPadding={8}
				className={cn(
					"fade-in-0 zoom-in-95 data-[state=closed]:fade-out-0 data-[state=closed]:zoom-out-95 z-50 w-72 origin-(--radix-popover-content-transform-origin) animate-in rounded-md border border-border bg-popover p-3 text-popover-foreground shadow-md outline-none data-[state=closed]:animate-out",
					className,
				)}
				{...props}
			>
				{children}
				<PopoverPrimitive.Arrow className="fill-popover stroke-border" />
			</PopoverPrimitive.Content>
		</PopoverPrimitive.Portal>
	);
}

export { Popover, PopoverAnchor, PopoverContent, PopoverTrigger };
