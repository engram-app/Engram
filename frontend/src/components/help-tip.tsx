import { CircleHelp } from "lucide-react";
import type { ReactNode } from "react";
import { Popover, PopoverContent, PopoverTrigger } from "@/components/ui/popover";

/**
 * The `?` affordance: a quiet icon beside a control that explains it on click.
 *
 * A POPOVER, not a Tooltip, despite the name people give this. A tooltip is
 * hover-triggered, `role="tooltip"`, and closes when the pointer leaves — which
 * makes anything inside it unclickable and unreachable by keyboard. These
 * explanations carry links, so the content has to be focusable and to stay open
 * while you move onto it. Click-to-open also means it works on touch, where
 * hover does not exist at all.
 *
 * Deliberately generic: this is the first of these, and the point is that the
 * next one looks and behaves identically instead of each surface inventing its
 * own help affordance.
 *
 * @param label What the `?` explains, e.g. "About markdown". Becomes the button's
 *   accessible name, so it must name the SUBJECT and not just say "help" — a
 *   screen reader listing several of these needs to tell them apart.
 */
export function HelpTip({
	label,
	children,
	className = "",
	align = "end",
}: {
	label: string;
	children: ReactNode;
	className?: string;
	align?: "start" | "center" | "end";
}) {
	return (
		<Popover>
			<PopoverTrigger
				type="button"
				aria-label={label}
				title={label}
				className={`inline-flex shrink-0 items-center justify-center rounded-full text-muted-foreground outline-none transition-colors hover:text-foreground focus-visible:ring-2 focus-visible:ring-ring data-[state=open]:text-foreground ${className}`}
			>
				<CircleHelp className="size-4" />
			</PopoverTrigger>
			{/* max-h + scroll: the trigger is usually pinned near the top of a panel,
			    so a long explanation would otherwise run off the bottom of a short
			    viewport with no way to reach the end of it. */}
			<PopoverContent
				align={align}
				className="max-h-[min(28rem,70vh)] overflow-y-auto text-xs leading-relaxed"
			>
				{children}
			</PopoverContent>
		</Popover>
	);
}
