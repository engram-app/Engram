import { useEffect, useRef, useState } from "react";
import { Checkbox } from "@/components/ui/checkbox";
import { cn } from "@/lib/utils";
import type { PropertyType } from "./property-types";

interface FieldProps {
	type: PropertyType;
	value: unknown;
	onCommit: (value: unknown) => void;
	onFocusChange?: (focused: boolean) => void;
	/** Property name, so the field announces as more than "edit text". */
	label?: string;
}

// Obsidian's value inputs carry no border and no fill, in any state — the
// caret is the only affordance. See docs/context/obsidian-properties-parity.md.
// No LEFT inset here on purpose. Every value renderer must start on the same x,
// and only the inputs can carry their own padding — chips and the checkbox are
// not inputs, so they sat flush against the divider. The `dd` owns the inset now
// (properties-widget), which makes the next field type correct by default.
const inputCls =
	"w-full rounded-md border-0 bg-transparent py-1 pr-2 text-foreground text-sm outline-none";

function ScalarField({ type, value, onCommit, onFocusChange, label }: FieldProps) {
	const initial = value === null || value === undefined ? "" : String(value);
	const [draft, setDraft] = useState(initial);
	const inputRef = useRef<HTMLInputElement>(null);
	useEffect(() => {
		if (document.activeElement !== inputRef.current) {
			setDraft(initial);
		}
	}, [initial]);

	const htmlType = htmlInputType(type);

	const commit = () => {
		if (type === "number") {
			const n = Number(draft);
			onCommit(draft.trim() === "" || !Number.isFinite(n) ? null : n);
		} else {
			onCommit(draft);
		}
	};

	// Escape has to survive a round trip through blur. Reverting the draft and
	// blurring in the same handler would not work: the state update is async, so
	// the blur handler's `commit` still closes over the typed text and writes the
	// value Escape was meant to throw away. The flag lets blur decide instead.
	const cancelled = useRef(false);

	return (
		<input
			ref={inputRef}
			type={htmlType}
			aria-label={label ? `${label} value` : undefined}
			className={inputCls}
			value={draft}
			onChange={(e) => setDraft(e.target.value)}
			onFocus={() => onFocusChange?.(true)}
			// Enter and Escape both leave the field, and blur is already the commit
			// point — so they route through it rather than duplicating the write.
			// Every other input in this widget (the list chips, the adder row, the
			// key rename box) takes both keys; the value field was the one place
			// where Enter did nothing at all.
			onKeyDown={(e) => {
				if (e.key === "Enter") {
					e.preventDefault();
					e.currentTarget.blur();
				} else if (e.key === "Escape") {
					e.preventDefault();
					cancelled.current = true;
					e.currentTarget.blur();
				}
			}}
			onBlur={() => {
				if (cancelled.current) {
					cancelled.current = false;
					setDraft(initial);
				} else {
					commit();
				}
				onFocusChange?.(false);
			}}
		/>
	);
}

interface ListFieldProps {
	value: string[];
	onCommit: (v: unknown) => void;
	onFocusChange?: (focused: boolean) => void;
	label?: string;
}

function ListField({ value, onCommit, onFocusChange, label }: ListFieldProps) {
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
				aria-label={label ? `${label} value` : undefined}
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

export function PropertyField({ type, value, onCommit, onFocusChange, label }: FieldProps) {
	if (type === "checkbox") {
		return (
			<Checkbox
				checked={Boolean(value)}
				onCheckedChange={(c) => onCommit(c === true)}
				aria-label={label ? `${label} value` : "Toggle value"}
			/>
		);
	}
	if (type === "list") {
		return (
			<ListField
				value={Array.isArray(value) ? value.map(String) : []}
				onCommit={onCommit}
				onFocusChange={onFocusChange}
				label={label}
			/>
		);
	}
	return (
		<ScalarField
			type={type}
			value={value}
			onCommit={onCommit}
			onFocusChange={onFocusChange}
			label={label}
		/>
	);
}

/** The native input type a property type is edited with.
 *
 *  Exported because the new-property row needs the SAME control a committed row
 *  gets. It used to hardcode a plain text box, so choosing `date` or `datetime`
 *  gave you a text field with no picker and no mm/dd/yyyy skeleton until the
 *  row was committed and re-rendered as a real field. One mapping, both rows. */
export function htmlInputType(type: PropertyType): string {
	switch (type) {
		case "number":
			return "number";
		case "date":
			return "date";
		case "datetime":
			return "datetime-local";
		default:
			return "text";
	}
}
