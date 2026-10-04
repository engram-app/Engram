import type { ReactNode } from "react";

// The strip across the top of a document: folder crumb, the item's name, and
// actions on the right. Notes and attachment previews both render it, so the two
// read as one kind of page. `name` is a node so a note can swap in a rename input.
export function DocumentHeader({
	folder,
	name,
	title,
	actions,
}: {
	folder?: string;
	name: ReactNode;
	title?: string;
	actions?: ReactNode;
}) {
	return (
		<div className="flex shrink-0 items-center gap-2 border-border border-b px-4 py-2">
			<p className="flex min-w-0 flex-1 items-baseline gap-1 text-sm" title={title}>
				{Boolean(folder) && (
					<span className="min-w-0 shrink truncate text-muted-foreground">{folder}/</span>
				)}
				{name}
			</p>
			{actions}
		</div>
	);
}
