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
// One source for the heading's type so the rename box cannot drift out of
// step with the h1 it stands in for.
const TITLE_TYPE = "font-semibold text-3xl tracking-tight";

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
					// Chromeless: no border, no fill, no padding of its own, so the
					// caret simply appears in the title. p-0 also keeps the text on
					// the same left edge as the button it replaced.
					className={`${TITLE_TYPE} rounded-none border-0 bg-transparent p-0`}
					onCommit={onCommitRename}
					onCancel={onCancelRename}
				/>
			</section>
		);
	}

	return (
		<h1 className={`${FRAME} ${TITLE_TYPE}`}>
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
