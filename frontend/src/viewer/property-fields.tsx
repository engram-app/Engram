import { useEffect, useRef, useState } from "react";
import { Checkbox } from "@/components/ui/checkbox";
import { cn } from "@/lib/utils";
import type { PropertyType } from "./property-types";

interface FieldProps {
	type: PropertyType;
	value: unknown;
	onCommit: (value: unknown) => void;
	onFocusChange?: (focused: boolean) => void;
}

const inputCls =
	"w-full rounded border border-border bg-transparent px-2 py-1 text-xs text-foreground focus:outline-none focus:ring-1 focus:ring-ring";

export function PropertyField({ type, value, onCommit, onFocusChange }: FieldProps) {
	if (type === "checkbox") {
		return (
			<Checkbox
				checked={Boolean(value)}
				onCheckedChange={(c) => onCommit(c === true)}
				aria-label="Toggle value"
			/>
		);
	}
	if (type === "list") {
		return (
			<ListField
				value={Array.isArray(value) ? value.map(String) : []}
				onCommit={onCommit}
				onFocusChange={onFocusChange}
			/>
		);
	}
	return (
		<ScalarField type={type} value={value} onCommit={onCommit} onFocusChange={onFocusChange} />
	);
}

function ScalarField({ type, value, onCommit, onFocusChange }: FieldProps) {
	const initial = value == null ? "" : String(value);
	const [draft, setDraft] = useState(initial);
	const inputRef = useRef<HTMLInputElement>(null);
	useEffect(() => {
		if (document.activeElement !== inputRef.current) {
			setDraft(initial);
		}
	}, [initial]);

	const htmlType =
		type === "number"
			? "number"
			: type === "date"
				? "date"
				: type === "datetime"
					? "datetime-local"
					: "text";

	const commit = () => {
		if (type === "number") {
			const n = Number(draft);
			onCommit(draft.trim() === "" || !Number.isFinite(n) ? null : n);
		} else {
			onCommit(draft);
		}
	};

	return (
		<input
			ref={inputRef}
			type={htmlType}
			className={inputCls}
			value={draft}
			onChange={(e) => setDraft(e.target.value)}
			onFocus={() => onFocusChange?.(true)}
			onBlur={() => {
				commit();
				onFocusChange?.(false);
			}}
		/>
	);
}

interface ListFieldProps {
	value: string[];
	onCommit: (v: unknown) => void;
	onFocusChange?: (focused: boolean) => void;
}

function ListField({ value, onCommit, onFocusChange }: ListFieldProps) {
	const [pending, setPending] = useState("");

	const add = () => {
		const item = pending.trim();
		if (item === "") {
			return;
		}
		onCommit([...value, item]);
		setPending("");
	};

	return (
		<div className="flex flex-wrap items-center gap-1">
			{value.map((item, i) => (
				<span
					// biome-ignore lint/suspicious/noArrayIndexKey: list items are plain strings that may duplicate and are removed by position (filter on index), so the array index is the stable identity; the chips hold no internal state, so index-keying cannot mismatch state.
					key={`${item}-${i}`}
					className="inline-flex items-center gap-1 rounded-full bg-secondary px-2 py-0.5 text-secondary-foreground text-xs"
				>
					{item}
					<button
						type="button"
						aria-label={`Remove ${item}`}
						className="text-muted-foreground hover:text-foreground"
						onClick={() => onCommit(value.filter((_, j) => j !== i))}
					>
						x
					</button>
				</span>
			))}
			<input
				className={cn(inputCls, "w-24 flex-1")}
				placeholder="Add item..."
				value={pending}
				onChange={(e) => setPending(e.target.value)}
				onFocus={() => onFocusChange?.(true)}
				onBlur={() => onFocusChange?.(false)}
				onKeyDown={(e) => {
					if (e.key === "Enter") {
						e.preventDefault();
						add();
					}
				}}
			/>
		</div>
	);
}
