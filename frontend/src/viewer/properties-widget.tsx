import { useEffect, useRef, useState } from "react";
import type * as Y from "yjs";
import {
	addKey,
	frontmatterMaps,
	moveKey,
	type PropertyRow,
	readRows,
	removeKey,
	setType,
	setValue,
	sortRowsOkfFirst,
} from "../crdt/frontmatter-doc";
import { PropertyField } from "./property-fields";
import { PropertyTypeMenu } from "./property-type-menu";
import { coerceValue, effectiveType, type PropertyType } from "./property-types";

// Obsidian's --metadata-label-width is 9em against the 16px root, so 144px,
// and it does NOT shrink — long values never squeeze the key column. The right
// border is Obsidian's --metadata-divider turned on: stock Obsidian ships it
// at 0 width, which leaves an empty value as an invisible target with no hint
// that the row is even editable.
const KEY_CELL =
	"flex min-h-7 w-36 min-w-36 shrink-0 items-center overflow-hidden border-border border-r";

// One box per row so the key/value boundary and the row boundary both read.
const ROW = "flex items-start rounded-md border border-border";

// Anything this editor opens that renders outside its own DOM subtree. Treated
// as "inside" for the click-away rule.
const PORTALLED_SURFACES =
	'[data-radix-popper-content-wrapper],[role="menu"],[role="listbox"],[role="dialog"]';

interface Props {
	doc: Y.Doc;
	/**
	 * Show the editor even with no properties yet, for the `---` gesture.
	 * LOCAL-ONLY state: an "open but empty" block must never reach the Y.Doc,
	 * or every other device would grow an empty properties section.
	 */
	draft?: boolean;
	/** Focus left the editor with nothing added — the draft should close. */
	onAbandonDraft?: () => void;
}

export function PropertiesWidget({ doc, draft = false, onAbandonDraft }: Props) {
	const [rows, setRows] = useState<PropertyRow[]>(() => sortRowsOkfFirst(readRows(doc)));
	const newKeyRef = useRef<HTMLInputElement>(null);
	const newValueRef = useRef<HTMLInputElement>(null);
	const rootRef = useRef<HTMLElement>(null);

	useEffect(() => {
		const refresh = () => setRows(sortRowsOkfFirst(readRows(doc)));
		const { values, order, types } = frontmatterMaps(doc);
		values.observeDeep(refresh);
		order.observe(refresh);
		types.observe(refresh);
		refresh();
		return () => {
			values.unobserveDeep(refresh);
			order.unobserve(refresh);
			types.unobserve(refresh);
		};
	}, [doc]);

	const [newKey, setNewKey] = useState("");
	const [newValue, setNewValue] = useState("");
	const [newType, setNewType] = useState<PropertyType>("text");

	const commitNewKey = ({ refocus = true } = {}) => {
		const key = newKey.trim();
		if (!addKey(doc, newKey, newType)) {
			return false;
		}
		if (newValue !== "") {
			setValue(doc, key, coerceValue(newValue, newType));
		}
		setNewKey("");
		setNewValue("");
		if (refocus) {
			// Straight back to the key field, ready for the next one.
			newKeyRef.current?.focus();
		}
		return true;
	};

	// Read by the click-away effect, which must not re-subscribe on every
	// keystroke just to see the latest draft text.
	const commitOnLeave = useRef<() => boolean>(() => false);
	commitOnLeave.current = () => commitNewKey({ refocus: false });

	// The `---` gesture opens this with nothing in it, so the caret has to land
	// in the name field — otherwise there is nothing to click away FROM.
	useEffect(() => {
		if (draft) {
			newKeyRef.current?.focus();
		}
	}, [draft]);

	// An empty draft closes as soon as the user goes elsewhere. Watched on the
	// document rather than as an onBlur prop: clicking dead space blurs the
	// input without focusing anything, so a relatedTarget check would miss the
	// most ordinary way to dismiss this. pointerdown covers the mouse, focusin
	// covers tabbing away. Reads the doc, not `rows`, so a key added in this
	// same interaction already counts.
	useEffect(() => {
		if (!draft) {
			return;
		}
		const dismiss = (event: Event) => {
			const root = rootRef.current;
			const target = event.target as Element | null;
			if (!root || root.contains(target)) {
				return;
			}
			// Radix portals menus to document.body, so a click on a type option is
			// physically outside `root` while being very much inside this editor.
			// Without this the type picker destroyed the draft it was opened from.
			if (target?.closest?.(PORTALLED_SURFACES)) {
				return;
			}
			if (readRows(doc).length > 0) {
				return;
			}
			// Nothing committed yet — but a half-filled row is still the user's
			// work, so leaving saves it rather than throwing it away. Only a row
			// with no key at all counts as "never mind".
			if (commitOnLeave.current()) {
				return;
			}
			onAbandonDraft?.();
		};
		document.addEventListener("pointerdown", dismiss);
		document.addEventListener("focusin", dismiss);
		return () => {
			document.removeEventListener("pointerdown", dismiss);
			document.removeEventListener("focusin", dismiss);
		};
	}, [draft, doc, onAbandonDraft]);

	// A note with no frontmatter gets no bordered strip of nothing. Returning
	// null keeps the component MOUNTED and its Yjs observers live, so the
	// widget reappears the moment a key arrives — from the note menu's "Add
	// property" or from a remote peer. Unmounting it at the call site instead
	// would leave nobody listening for that.
	if (rows.length === 0 && !draft) {
		return null;
	}

	return (
		// Geometry lifted from Obsidian's app.css: 8px block padding, a 2rem gap
		// down to the body, 3px between rows, a 9em key column, 28px row height.
		<section className="mb-8 px-5 py-2" data-testid="note-properties" ref={rootRef}>
			<dl className="flex flex-col gap-[3px]">
				{rows.map((row) => {
					const type = effectiveType(row.value, row.typeOverride);
					return (
						<div key={row.key} className={`group ${ROW}`} data-testid={`property-row-${row.key}`}>
							<dt className={KEY_CELL}>
								<PropertyTypeMenu value={type} onChange={(t) => setType(doc, row.key, t)} />
								<span className="truncate px-1 text-muted-foreground text-sm">{row.key}</span>
							</dt>
							<dd className="flex min-h-7 flex-1 items-center gap-1">
								<PropertyField
									type={type}
									value={row.value}
									onCommit={(v) => setValue(doc, row.key, v)}
								/>
							</dd>
							{/* Obsidian keeps row actions in a right-click menu, so the
							    default view stays clean. We surface ours on hover/focus
							    rather than dropping the capability. */}
							<div className="flex min-h-7 items-center gap-0.5 text-muted-foreground opacity-0 transition-opacity focus-within:opacity-100 group-hover:opacity-100">
								<button
									type="button"
									aria-label={`Move ${row.key} up`}
									onClick={() => moveKey(doc, row.key, "up")}
									className="rounded px-1 hover:bg-muted"
								>
									^
								</button>
								<button
									type="button"
									aria-label={`Move ${row.key} down`}
									onClick={() => moveKey(doc, row.key, "down")}
									className="rounded px-1 hover:bg-muted"
								>
									v
								</button>
								<button
									type="button"
									aria-label={`Remove ${row.key}`}
									onClick={() => removeKey(doc, row.key)}
									className="rounded px-1 hover:bg-muted hover:text-destructive"
								>
									x
								</button>
							</div>
						</div>
					);
				})}
			</dl>

			{/* The adder wears the same row geometry, so a property being named
			    looks like the row it is about to become. */}
			<div className={`mt-[3px] ${ROW}`}>
				<div className={KEY_CELL}>
					<PropertyTypeMenu value={newType} onChange={setNewType} />
					<input
						ref={newKeyRef}
						className="w-full min-w-0 border-0 bg-transparent px-1 text-muted-foreground text-sm outline-none placeholder:text-muted-foreground/60"
						placeholder="Property name"
						value={newKey}
						onChange={(e) => setNewKey(e.target.value)}
						// Enter moves along the row instead of committing: on a note with
						// no properties this IS the only row, so committing from the key
						// would close the one place a value can be typed.
						onKeyDown={(e) => {
							if (e.key === "Enter") {
								e.preventDefault();
								newValueRef.current?.focus();
							}
						}}
					/>
				</div>
				<div className="flex min-h-7 flex-1 items-center gap-1">
					<input
						ref={newValueRef}
						className="w-full min-w-0 border-0 bg-transparent px-2 py-1 text-foreground text-sm outline-none placeholder:text-muted-foreground/60"
						placeholder="Value"
						value={newValue}
						onChange={(e) => setNewValue(e.target.value)}
						onKeyDown={(e) => {
							if (e.key === "Enter") {
								e.preventDefault();
								commitNewKey();
							}
						}}
					/>
				</div>
				<button
					type="button"
					aria-label="Add property"
					className="min-h-7 shrink-0 rounded px-1.5 text-muted-foreground text-sm hover:text-foreground"
					onClick={() => commitNewKey()}
				>
					Add
				</button>
			</div>
		</section>
	);
}
