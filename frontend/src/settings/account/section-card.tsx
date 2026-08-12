import type { ReactNode } from "react";

interface Props {
	title: string;
	description?: string;
	headerAction?: ReactNode;
	children: ReactNode;
}

export function SettingsSectionCard({ title, description, headerAction, children }: Props) {
	return (
		// Full-bleed on mobile: -mx-4 cancels the container's padding so the card
		// spans edge to edge, leaving its own p-4 as the ONLY horizontal inset
		// between the screen edge and the content — one layer, not two. The
		// container keeps that padding for the page headings, which sit outside
		// any card. Above md it returns to a bordered, rounded card.
		<section
			aria-label={title}
			className="-mx-4 border-border border-y bg-card p-4 md:mx-0 md:rounded-lg md:border md:p-6"
		>
			<header className="mb-4 flex items-start justify-between gap-3">
				<div>
					<h2 className="font-semibold text-base text-foreground">{title}</h2>
					{Boolean(description) && (
						<p className="mt-1 text-muted-foreground text-sm">{description}</p>
					)}
				</div>
				{Boolean(headerAction) && <div className="shrink-0">{headerAction}</div>}
			</header>
			{children}
		</section>
	);
}
