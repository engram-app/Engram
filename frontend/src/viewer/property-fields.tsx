import { useRef, useState } from "react";
import { Checkbox } from "@/components/ui/checkbox";
import { useT } from "@/i18n/locale-provider";
import { formatPropertyDate } from "@/lib/format-date";
import { FIELD_TEXT } from "@/lib/ui-classes";
import { cn } from "@/lib/utils";
import type { PropertyType } from "./property-types";
import { RenameInput } from "./tree-actions/rename-input";

interface FieldProps {
	type: PropertyType;
	value: unknown;
	onCommit: (value: unknown) => void;
	/** Property name, so the field announces as more than "edit text". */
	label?: string;
}

// Obsidian's value inputs carry no border and no fill, in any state — the
// caret is the only affordance. See docs/context/obsidian-properties-parity.md.
// No LEFT inset here on purpose. Every value renderer must start on the same x,
// and only the inputs can carry their own padding — chips and the checkbox are
// not inputs, so they sat flush against the divider. The `dd` owns the inset now
// (properties-widget), which makes the next field type correct by default.
const inputCls = `w-full rounded-md border-0 bg-transparent px-0 py-1 pr-2 text-foreground outline-none ${FIELD_TEXT}`;

/**
 * The at-rest look of a tap-to-edit cell: the value as plain text in a button,
 * on the same box as the input it turns into, so tapping does not shift it.
 *
 * Why not a live input: iOS's prev/next arrows walk the page's text inputs,
 * and these render right above the editor, so "previous" from the note body
 * landed in the last property value. A button is not on that walk. Same
 * pattern as the inline title (inline-title.tsx): a button that swaps to
 * RenameInput while editing.
 */
const CELL_BUTTON = `block min-w-0 cursor-text self-stretch truncate text-left ${inputCls}`;

function ScalarField({ type, value, onCommit, label }: FieldProps) {
	const { t, renderedLocale } = useT();
	const [editing, setEditing] = useState(false);
	const initial = value === null || value === undefined ? "" : String(value);
	// At rest a date reads the way the native date input showed it; the raw
	// stored string is what the input edits.
	const shown =
		(type === "date" || type === "datetime") && initial !== ""
			? formatPropertyDate(initial, type, renderedLocale)
			: initial;
	const name = label ? t("{label} value", { label }) : t("Value");

	if (!editing) {
		return (
			<button
				type="button"
				// The name must contain the text shown (WCAG 2.5.3 label-in-name);
				// the key in front says which property it is.
				aria-label={shown === "" ? name : `${name}: ${shown}`}
				className={CELL_BUTTON}
				onClick={() => setEditing(true)}
			>
				{shown}
			</button>
		);
	}

	// RenameInput owns Enter (commit), Escape (abandon), commit-on-blur and
	// committing only a real change. trim false: the value must round-trip
	// byte-exact, so opening and closing " foo" or a block scalar's trailing
	// newline writes nothing back, and an edit is stored as typed. A window
	// blur (app switch) commits, as every blur here always did.
	return (
		<RenameInput
			initial={initial}
			label={name}
			type={htmlInputType(type)}
			allowEmpty
			trim={false}
			commitOnBlur
			commitOnWindowBlur
			className={inputCls}
			onCommit={(next) => {
				setEditing(false);
				if (type === "number") {
					const n = Number(next);
					onCommit(next === "" || !Number.isFinite(n) ? null : n);
				} else {
					onCommit(next);
				}
			}}
			onCancel={() => setEditing(false)}
		/>
	);
}

interface ListFieldProps {
	value: string[];
	onCommit: (v: unknown) => void;
	label?: string;
}

function ListField({ value, onCommit, label }: ListFieldProps) {
	const { t } = useT();
	const [pending, setPending] = useState("");
	// The adder is a button until tapped, for the same prev/next reason as
	// CELL_BUTTON. It stays open across Enter so several items go in at once.
	const [adding, setAdding] = useState(false);
	// Escape has to survive the blur it triggers: the blur handler still sees
	// the typed text (state updates are async), so a flag tells it to drop it.
	const discard = useRef(false);
	const name = label ? t("{label} value", { label }) : t("Value");

	const add = () => {
		const item = pending.trim();
		if (item === "") {
			return;
		}
		onCommit([...value, item]);
		setPending("");
	};

	return (
		<div className="flex flex-wrap items-center gap-1 py-1">
			{value.map((item, i) => (
				<span
					// biome-ignore lint/suspicious/noArrayIndexKey: list items are plain strings that may duplicate and are removed by position (filter on index), so the array index is the stable identity; the chips hold no internal state, so index-keying cannot mismatch state.
					key={`${item}-${i}`}
					className="inline-flex items-center gap-1 rounded-full bg-secondary px-2 py-0.5 text-secondary-foreground text-xs"
				>
					{item}
					<button
						type="button"
						aria-label={t("Remove {item}", { item })}
						className="text-muted-foreground hover:text-foreground"
						onClick={() => onCommit(value.filter((_, j) => j !== i))}
					>
						x
					</button>
				</span>
			))}
			{adding ? (
				<input
					// Focus on mount, inside the tap that opened it, which is what lets
					// iOS raise the keyboard for a programmatic focus.
					ref={(el) => el?.focus()}
					aria-label={name}
					className={cn(inputCls, "w-24 flex-1")}
					placeholder={t("Add item...")}
					autoComplete="off"
					enterKeyHint="done"
					value={pending}
					onChange={(e) => setPending(e.target.value)}
					// Leaving with a typed item keeps it, the way a scalar value
					// commits on blur; on a phone, tapping outside is how you finish.
					onBlur={() => {
						if (discard.current) {
							discard.current = false;
							setPending("");
						} else {
							add();
						}
						setAdding(false);
					}}
					onKeyDown={(e) => {
						if (e.key === "Enter") {
							e.preventDefault();
							add();
						} else if (e.key === "Escape") {
							e.preventDefault();
							discard.current = true;
							e.currentTarget.blur();
						}
					}}
				/>
			) : (
				<button
					type="button"
					aria-label={`${name}: ${t("Add item...")}`}
					// Full muted, not /60: as a placeholder this text was exempt from
					// the contrast audit; as a button's text it is not.
					className={cn(CELL_BUTTON, "w-24 flex-1 text-muted-foreground")}
					onClick={() => setAdding(true)}
				>
					{t("Add item...")}
				</button>
			)}
		</div>
	);
}

export function PropertyField({ type, value, onCommit, label }: FieldProps) {
	const { t } = useT();
	if (type === "checkbox") {
		return (
			<Checkbox
				checked={Boolean(value)}
				onCheckedChange={(c) => onCommit(c === true)}
				aria-label={label ? t("{label} value", { label }) : t("Toggle value")}
			/>
		);
	}
	if (type === "list") {
		return (
			<ListField
				value={Array.isArray(value) ? value.map(String) : []}
				onCommit={onCommit}
				label={label}
			/>
		);
	}
	return <ScalarField type={type} value={value} onCommit={onCommit} label={label} />;
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
