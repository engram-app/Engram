import type { ReactNode } from "react";

interface Props {
	title: string;
	description?: string;
	headerAction?: ReactNode;
	children: ReactNode;
}

export function SettingsSectionCard({ title, description, headerAction, children }: Props) {
	return (
		<section aria-label={title} className="rounded-lg border border-border bg-card p-4 sm:p-6">
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
