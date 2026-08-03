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
import { effectiveType, type PropertyType } from "./property-types";

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
	const rootRef = useRef<HTMLDivElement>(null);

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
	const [newType, setNewType] = useState<PropertyType>("text");

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
			if (!root || root.contains(event.target as Node | null)) {
				return;
			}
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
		<div className="border-border border-b px-5 py-3" data-testid="note-properties" ref={rootRef}>
			<dl className="grid grid-cols-[max-content_max-content_1fr_max-content] items-center gap-x-2 gap-y-1 text-xs">
				{rows.map((row) => {
					const type = effectiveType(row.value, row.typeOverride);
					return (
						<div key={row.key} className="contents" data-testid={`property-row-${row.key}`}>
							<dt className="font-medium text-muted-foreground">{row.key}</dt>
							<PropertyTypeMenu value={type} onChange={(t) => setType(doc, row.key, t)} />
							<dd>
								<PropertyField
									type={type}
									value={row.value}
									onCommit={(v) => setValue(doc, row.key, v)}
								/>
							</dd>
							<div className="flex items-center gap-0.5 text-muted-foreground">
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
			<div className="mt-2 flex items-center gap-2">
				<input
					ref={newKeyRef}
					className="rounded border border-border bg-transparent px-2 py-1 text-foreground text-xs focus:outline-none focus:ring-1 focus:ring-ring"
					placeholder="Property name"
					value={newKey}
					onChange={(e) => setNewKey(e.target.value)}
				/>
				<PropertyTypeMenu value={newType} onChange={setNewType} />
				<button
					type="button"
					aria-label="Add property"
					className="rounded border border-border px-2 py-1 text-muted-foreground text-xs hover:bg-muted"
					onClick={() => {
						if (addKey(doc, newKey, newType)) {
							setNewKey("");
						}
					}}
				>
					Add property
				</button>
			</div>
		</div>
	);
}
