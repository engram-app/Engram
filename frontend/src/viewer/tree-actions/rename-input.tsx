import { useEffect, useRef, useState } from "react";

interface Props {
	initial: string;
	kind: "file" | "folder";
	error?: string;
	onCommit: (next: string) => void;
	onCancel: () => void;
}

export function RenameInput({ initial, kind, error, onCommit, onCancel }: Props) {
	const [value, setValue] = useState(initial);
	const inputRef = useRef<HTMLInputElement>(null);

	useEffect(() => {
		const el = inputRef.current;
		if (!el) return;
		el.focus();
		if (kind === "file") {
			const dot = initial.lastIndexOf(".");
			el.setSelectionRange(0, dot > 0 ? dot : initial.length);
		} else {
			el.setSelectionRange(0, initial.length);
		}
	}, [initial, kind]);

	return (
		<div className="flex w-full flex-col gap-0.5">
			<input
				ref={inputRef}
				type="text"
				value={value}
				onChange={(e) => setValue(e.target.value)}
				onKeyDown={(e) => {
					if (e.key === "Enter") {
						e.preventDefault();
						if (value && value !== initial) onCommit(value);
						else onCancel();
					} else if (e.key === "Escape") {
						e.preventDefault();
						onCancel();
					}
				}}
				onBlur={() => onCancel()}
				className="w-full rounded border border-blue-400 bg-white px-1 py-0.5 text-sm text-gray-900 dark:bg-gray-900 dark:text-gray-100"
			/>
			{error && (
				<span className="text-xs text-red-600 dark:text-red-400" role="alert">
					{error}
				</span>
			)}
		</div>
	);
}
