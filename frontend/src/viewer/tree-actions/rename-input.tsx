import { useEffect, useRef, useState } from "react";

interface Props {
	initial: string;
	kind: "file" | "folder";
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
}

export function RenameInput({
	initial,
	kind,
	error,
	onChange,
	onCommit,
	onCancel,
	commitOnBlur,
}: Props) {
	const [value, setValue] = useState(initial);
	const inputRef = useRef<HTMLInputElement>(null);
	// Enter commits, and the blur that follows as focus moves away would commit
	// AGAIN — a second rename against a path that no longer exists. Escape is
	// worse: its blur would save the very edit just abandoned. So the first of
	// commit/cancel to fire wins and the rest are ignored.
	const settled = useRef(false);

	useEffect(() => {
		const el = inputRef.current;
		if (!el) {
			return;
		}
		settled.current = false;
		el.focus();
		// Whole value: every caller seeds this with a base name, never a leaf
		// with an extension, so a dot in "Node.js guide" is title text.
		el.setSelectionRange(0, initial.length);
	}, [initial]);

	// `commit` false means "abandon", whatever triggered it.
	const settle = (commit: boolean) => {
		if (settled.current) {
			return;
		}
		settled.current = true;
		if (commit && value && value !== initial) {
			onCommit(value);
		} else {
			onCancel();
		}
	};

	return (
		<div className="flex w-full flex-col gap-0.5">
			<input
				ref={inputRef}
				data-testid="tree-rename-input"
				aria-label={`Rename ${kind}`}
				type="text"
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
				onBlur={() => settle(Boolean(commitOnBlur))}
				className="w-full rounded border border-ring bg-background px-1 py-0.5 text-foreground text-sm outline-none"
			/>
			{Boolean(error) && (
				<span className="text-destructive text-xs" role="alert">
					{error}
				</span>
			)}
		</div>
	);
}
