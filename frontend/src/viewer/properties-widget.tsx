import { Plus, X } from "lucide-react";
import { useEffect, useRef, useState } from "react";
import type * as Y from "yjs";
import {
	addKey,
	frontmatterMaps,
	type PropertyRow,
	readRows,
	removeKey,
	renameKey,
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

/**
 * The property's name, editable in place like Obsidian's key input.
 *
 * Keeps its own draft so a remote edit elsewhere in the doc cannot rewrite the
 * text under the caret — the same guard the value fields use. A rejected
 * rename (empty, unchanged, or a name already taken) snaps back rather than
 * leaving the input showing a name the doc does not have.
 */
function PropertyKeyInput({ doc, name }: { doc: Y.Doc; name: string }) {
	const [draft, setDraft] = useState(name);
	const ref = useRef<HTMLInputElement>(null);
	useEffect(() => {
		if (document.activeElement !== ref.current) {
			setDraft(name);
		}
	}, [name]);

	const commit = () => {
		if (draft.trim() === name) {
			setDraft(name);
			return;
		}
		if (!renameKey(doc, name, draft)) {
			setDraft(name);
		}
	};

	return (
		<input
			ref={ref}
			aria-label={`Rename ${name}`}
			className="w-full min-w-0 truncate border-0 bg-transparent px-2 py-1 text-muted-foreground text-sm outline-none"
			value={draft}
			onChange={(e) => setDraft(e.target.value)}
			onBlur={commit}
			onKeyDown={(e) => {
				if (e.key === "Enter") {
					e.preventDefault();
					commit();
				} else if (e.key === "Escape") {
					e.preventDefault();
					setDraft(name);
				}
			}}
		/>
	);
}

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
	// Obsidian shows no placeholder row: the list is exactly the properties you
	// have, and "Add property" appends one to author. `adding` is that row.
	const [adding, setAdding] = useState(false);

	const cancelAdding = () => {
		setNewKey("");
		setNewValue("");
		setAdding(false);
	};

	const commitNewKey = () => {
		const key = newKey.trim();
		if (!addKey(doc, newKey, newType)) {
			return false;
		}
		if (newValue !== "") {
			setValue(doc, key, coerceValue(newValue, newType));
		}
		cancelAdding();
		return true;
	};

	// Read by the click-away effect, which must not re-subscribe on every
	// keystroke just to see the latest text.
	const leaving = useRef<{ commit: () => boolean; cancel: () => void } | null>(null);
	leaving.current = { commit: commitNewKey, cancel: cancelAdding };

	// The `---` gesture means "I want a property", so it opens the new row
	// directly rather than making the user find the button.
	useEffect(() => {
		if (draft) {
			setAdding(true);
		}
	}, [draft]);

	useEffect(() => {
		if (adding) {
			newKeyRef.current?.focus();
		}
	}, [adding]);

	// An empty draft closes as soon as the user goes elsewhere. Watched on the
	// document rather than as an onBlur prop: clicking dead space blurs the
	// input without focusing anything, so a relatedTarget check would miss the
	// most ordinary way to dismiss this. pointerdown covers the mouse, focusin
	// covers tabbing away. Reads the doc, not `rows`, so a key added in this
	// same interaction already counts.
	useEffect(() => {
		if (!adding) {
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
			// A half-filled row is still the user's work, so leaving saves it
			// rather than throwing it away. Only a row with no key at all counts
			// as "never mind".
			if (leaving.current?.commit()) {
				return;
			}
			leaving.current?.cancel();
			// Nothing typed and nothing stored: the `---` gesture opened an editor
			// the user turned out not to want.
			if (readRows(doc).length === 0) {
				onAbandonDraft?.();
			}
		};
		document.addEventListener("pointerdown", dismiss);
		document.addEventListener("focusin", dismiss);
		return () => {
			document.removeEventListener("pointerdown", dismiss);
			document.removeEventListener("focusin", dismiss);
		};
	}, [adding, doc, onAbandonDraft]);

	// A note with no frontmatter gets no bordered strip of nothing. Returning
	// null keeps the component MOUNTED and its Yjs observers live, so the
	// widget reappears the moment a key arrives — from the note menu's "Add
	// property" or from a remote peer. Unmounting it at the call site instead
	// would leave nobody listening for that.
	if (rows.length === 0 && !draft && !adding) {
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
								<PropertyKeyInput doc={doc} name={row.key} />
							</dt>
							<dd className="flex min-h-7 flex-1 items-center gap-1">
								<PropertyField
									type={type}
									value={row.value}
									label={row.key}
									onCommit={(v) => setValue(doc, row.key, v)}
								/>
							</dd>
							{/* Remove only. Reordering was two permanent buttons per row for
							    something you do once in a while; `moveKey` is still there
							    for a right-click menu, which is where Obsidian keeps it. */}
							<button
								type="button"
								aria-label={`Remove ${row.key}`}
								onClick={() => removeKey(doc, row.key)}
								className="mr-1 flex h-7 w-7 shrink-0 items-center justify-center rounded text-muted-foreground opacity-0 transition-opacity hover:bg-destructive/10 hover:text-destructive focus:opacity-100 group-hover:opacity-100"
							>
								<X aria-hidden="true" className="size-3.5" />
							</button>
						</div>
					);
				})}

				{/* The row being authored. Same geometry as a committed one, so
				    naming a property looks like the row it is about to become. */}
				{adding ? (
					<div className={ROW}>
						<dt className={KEY_CELL}>
							<PropertyTypeMenu value={newType} onChange={setNewType} />
							<input
								ref={newKeyRef}
								className="w-full min-w-0 border-0 bg-transparent px-2 py-1 text-muted-foreground text-sm outline-none placeholder:text-muted-foreground/60"
								placeholder="Property name"
								value={newKey}
								onChange={(e) => setNewKey(e.target.value)}
								// Enter moves ALONG the row rather than committing —
								// committing from the key would close the row before its
								// value could be typed.
								onKeyDown={(e) => {
									if (e.key === "Enter") {
										e.preventDefault();
										newValueRef.current?.focus();
									} else if (e.key === "Escape") {
										e.preventDefault();
										cancelAdding();
									}
								}}
							/>
						</dt>
						<dd className="flex min-h-7 flex-1 items-center gap-1">
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
									} else if (e.key === "Escape") {
										e.preventDefault();
										cancelAdding();
									}
								}}
							/>
						</dd>
					</div>
				) : null}
			</dl>

			<button
				type="button"
				aria-label="Add property"
				// Obsidian's .metadata-add-button: 6px inline-start, 0.5em above,
				// at the label's font size.
				className="mt-2 flex items-center gap-1 pl-1.5 text-muted-foreground text-sm hover:text-foreground"
				onClick={() => setAdding(true)}
			>
				<Plus aria-hidden="true" className="size-3.5" />
				Add property
			</button>
		</section>
	);
}
