import type { ReactNode } from "react";
import type { UIText } from "@/i18n/ui-text";
import { cn } from "@/lib/utils";

interface Props {
	title: UIText;
	description?: UIText;
	headerAction?: ReactNode;
	// Settings-style row: the action is a form control that lines up with the
	// title block and, once wrapped below it, fills the row (below sm).
	centerAction?: boolean;
	// Irreversible actions: red title and border, but no red fill.
	destructive?: boolean;
	children?: ReactNode;
}

export function SettingsSectionCard({
	title,
	description,
	headerAction,
	centerAction = false,
	destructive = false,
	children,
}: Props) {
	return (
		// Full-bleed on mobile: -mx-4 cancels the container's padding so the card
		// spans edge to edge, leaving its own p-4 as the ONLY horizontal inset
		// between the screen edge and the content — one layer, not two. The
		// container keeps that padding for the page headings, which sit outside
		// any card. Above md it returns to a bordered, rounded card.
		<section
			aria-label={title}
			className={cn(
				"-mx-4 border-y bg-card p-4 md:mx-0 md:rounded-lg md:border md:p-6",
				destructive ? "border-destructive/40" : "border-border",
			)}
		>
			<header
				className={cn(
					"flex flex-wrap justify-between gap-3",
					centerAction ? "items-center" : "items-start",
					Boolean(children) && "mb-4",
				)}
			>
				<div>
					<h2
						className={cn(
							"font-semibold text-base",
							destructive ? "text-destructive" : "text-foreground",
						)}
					>
						{title}
					</h2>
					{Boolean(description) && (
						<p className="mt-1 text-muted-foreground text-sm">{description}</p>
					)}
				</div>
				{Boolean(headerAction) && (
					<div className={cn("shrink-0", centerAction && "max-sm:grow")}>{headerAction}</div>
				)}
			</header>
			{children}
		</section>
	);
}
