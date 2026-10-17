import type { ReactNode } from "react";
import { ScrollArea } from "@/components/ui/scroll-area";
import { cn } from "@/lib/utils";

interface AuthPanelProps {
	children: ReactNode;
	className?: string;
	/** Off for a page that fills the card itself: it lays its children out as
	 *  a flex column and gives one of them `min-h-0 flex-1` to absorb the
	 *  height (the terms page's legal text). */
	scroll?: boolean;
}

// Each panel is one self-contained step (sign in, terms, a wizard question).
const card = "rounded-2xl border border-border bg-background";

// Never taller than the screen below the header: a step that does not fit
// scrolls inside its card, so the page itself never scrolls. Flex all the way
// down because the area above only caps the height (`max-h-full`); a
// percentage height would resolve to auto and never scroll.
export default function AuthPanel({ children, className, scroll = true }: AuthPanelProps) {
	return (
		<section className="m-auto flex max-h-full min-h-0 w-full max-w-2xl flex-col p-4 sm:py-6">
			{scroll ? (
				<ScrollArea
					className={cn("flex min-h-0 flex-col", card)}
					viewportClassName="h-auto min-h-0 flex-1 rounded-2xl"
				>
					<article className={cn("p-4 sm:p-6", className)}>{children}</article>
				</ScrollArea>
			) : (
				<article className={cn("flex min-h-0 flex-col p-4 sm:p-6", card, className)}>
					{children}
				</article>
			)}
		</section>
	);
}
