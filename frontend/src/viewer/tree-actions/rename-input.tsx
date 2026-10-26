import { useEffect, useRef, useState } from "react";
import { useT } from "@/i18n/locale-provider";
import { FIELD_TEXT } from "@/lib/ui-classes";
import { cn } from "@/lib/utils";

interface Props {
	initial: string;
	/** Names the box "Rename file" / "Rename folder". Ignored when `label` is set. */
	kind?: "file" | "folder";
	/** Accessible name, for a box that edits something other than a path. */
	label?: string;
	/** Native input type. Property values pass number/date/datetime-local. */
	type?: string;
	/** Commit an emptied box instead of treating it as a cancel. A path cannot
	 *  be empty; a property value can. */
	allowEmpty?: boolean;
	error?: string;
	// Fired on every keystroke, in addition to onCommit. Headless-tree's own
	// hotkeys-core feature listens for Enter/Escape on the tree container in
	// the native bubble phase, which fires before this input's React
	// onKeyDown (React's delegated listener sits higher up the DOM, so it
	// runs later in the same bubble). That means HT's built-in
	// completeRenaming/abortRenaming hotkeys can win the race and read HT's
	// own `renamingValue` state before onCommit ever runs. Keeping that state
	// in sync on every change (not just at commit time) makes either commit
	// path read the correct, up-to-date value.
	onChange?: (value: string) => void;
	onCommit: (next: string) => void;
	onCancel: () => void;
	/**
	 * Save when focus leaves, instead of abandoning the edit.
	 *
	 * Opt-in rather than the default because the two callers want opposite
	 * things. The note header is a title field you click, retype and click away
	 * from, where losing the edit is a surprise. In the TREE, a rename box is
	 * dismissed by clicking elsewhere in the tree — and that path also races
	 * headless-tree's own Enter/Escape hotkeys (see onChange above), so
	 * committing there is a behaviour change worth making deliberately rather
	 * than as a side effect of this one.
	 */
	commitOnBlur?: boolean;
	/**
	 * With commitOnBlur, also commit when the WINDOW loses focus (alt-tab, an
	 * iPhone app switch) instead of leaving the edit open. Property values want
	 * this: their blur always committed, and a phone app switch may never come
	 * back to the page. A path rename does not: a half-typed name there renames
	 * the file and cascades to the tree, links and sync.
	 */
	commitOnWindowBlur?: boolean;
	/**
	 * Trim before comparing and committing (the default). A path must not gain
	 * edge spaces; a property value must round-trip byte-exact, so it passes
	 * false.
	 */
	trim?: boolean;
	/**
	 * Restyle the input. Merged with `cn`, so Tailwind conflicts REPLACE the
	 * defaults rather than stacking — the inline title passes heading
	 * typography and a transparent, borderless look so renaming reads as
	 * typing into the title instead of a form field appearing in its place.
	 */
	className?: string;
}

export function RenameInput({
	initial,
	kind = "file",
	label,
	type = "text",
	allowEmpty,
	error,
	onChange,
	onCommit,
	onCancel,
	commitOnBlur,
	commitOnWindowBlur,
	trim = true,
	className,
}: Props) {
	const { t } = useT();
	const [value, setValue] = useState(initial);
	const inputRef = useRef<HTMLInputElement>(null);
	// Enter commits, and the blur that follows as focus moves away would commit
	// AGAIN: a second rename against a path that no longer exists. Escape is
	// worse: its blur would save the very edit just abandoned. So the first of
	// commit/cancel to fire wins and the rest are ignored.
	const settled = useRef(false);

	// Mount only. `value` is this box's own draft and is never resynced from
	// `initial`, so a remote change to the thing being edited cannot rewrite
	// the text under the caret; re-running this on an `initial` change would
	// still SELECT the draft, and the next keystroke would replace it all.
	useEffect(() => {
		const el = inputRef.current;
		if (!el) {
			return;
		}
		el.focus();
		// Whole value: every caller seeds this with a base name, never a leaf
		// with an extension, so a dot in "Node.js guide" is title text. Only text
		// boxes have a selection; number and date inputs throw on this.
		if (el.type === "text") {
			el.setSelectionRange(0, el.value.length);
		}
	}, []);

	// `commit` false means "abandon", whatever triggered it.
	const settle = (commit: boolean) => {
		if (settled.current) {
			return;
		}
		// Paths are trimmed before comparing AND before committing: untrimmed,
		// "  " was truthy and different from `initial`, so it renamed the file to
		// a path of literal spaces. Values (trim false) compare raw, so opening
		// and closing " foo" is the no-op it looks like.
		const next = trim ? value.trim() : value;
		settled.current = true;
		if (commit && (next || allowEmpty) && next !== initial) {
			onCommit(next);
		} else {
			onCancel();
		}
	};

	return (
		<div className="flex w-full flex-col gap-0.5">
			<input
				ref={inputRef}
				data-testid="tree-rename-input"
				aria-label={label ?? (kind === "file" ? t("Rename file") : t("Rename folder"))}
				type={type}
				// Every caller commits on Enter. autocomplete off keeps iOS from
				// offering contact or password AutoFill for a name or a value.
				autoComplete="off"
				enterKeyHint="done"
				value={value}
				onChange={(e) => {
					setValue(e.target.value);
					onChange?.(e.target.value);
				}}
				onKeyDown={(e) => {
					if (e.key === "Enter") {
						e.preventDefault();
						settle(true);
					} else if (e.key === "Escape") {
						e.preventDefault();
						settle(false);
					}
				}}
				// A blur while the document still has focus is a real click-away inside
				// the page. When the WINDOW is deactivated (alt-tab, another app),
				// browsers also fire blur on the focused element. Committing a rename
				// there renamed the note to whatever half-typed text was in the box,
				// and cancelling threw the typed text away, so a commitOnBlur box
				// returns without settling: the edit stays open with its draft, and
				// refocusing the window carries on. commitOnWindowBlur opts back into
				// committing (property values). The tree (no commitOnBlur) still
				// abandons on any blur.
				onBlur={() => {
					const windowBlur = !document.hasFocus();
					if (commitOnBlur && windowBlur && !commitOnWindowBlur) {
						return;
					}
					settle(Boolean(commitOnBlur));
				}}
				className={cn(
					"w-full rounded border border-ring bg-background px-1 py-0.5 text-foreground outline-none",
					FIELD_TEXT,
					className,
				)}
			/>
			{Boolean(error) && (
				<span className="text-destructive text-xs" role="alert">
					{error}
				</span>
			)}
		</div>
	);
}
