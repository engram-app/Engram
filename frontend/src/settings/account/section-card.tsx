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
					<h2 className="text-base font-semibold text-foreground">{title}</h2>
					{description && <p className="mt-1 text-sm text-muted-foreground">{description}</p>}
				</div>
				{headerAction && <div className="shrink-0">{headerAction}</div>}
			</header>
			{children}
		</section>
	);
}
