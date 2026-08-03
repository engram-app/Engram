import { RenameInput } from "./tree-actions/rename-input";

interface Props {
	/** Base name, no extension — the caller strips it. */
	name: string;
	renaming: boolean;
	onStartRename: () => void;
	onCommitRename: (next: string) => void;
	onCancelRename: () => void;
}

const FRAME = "px-5 pt-6 pb-1";

/**
 * Obsidian-style inline title: part of the document flow, not the chrome, so
 * it scrolls away with the content. Click to rename — `commitOnBlur` because
 * this reads as a title field you retype and then click into the body from,
 * where losing the edit would be a surprise.
 *
 * The rename box replaces the `h1` rather than nesting inside it: `h1` takes
 * phrasing content only, and an input that IS the heading is not a heading.
 */
export function InlineTitle({
	name,
	renaming,
	onStartRename,
	onCommitRename,
	onCancelRename,
}: Props) {
	if (renaming) {
		return (
			<section className={FRAME} aria-label="Rename note">
				<RenameInput
					initial={name}
					kind="file"
					commitOnBlur
					onCommit={onCommitRename}
					onCancel={onCancelRename}
				/>
			</section>
		);
	}

	return (
		<h1 className={`${FRAME} font-semibold text-3xl tracking-tight`}>
			<button
				type="button"
				// -mx-1 cancels the padding so the hover target is roomier than the
				// text without shifting the title off the left margin.
				className="-mx-1 block w-full truncate rounded px-1 text-left hover:bg-accent"
				title="Click to rename"
				onClick={onStartRename}
			>
				{name}
			</button>
		</h1>
	);
}
