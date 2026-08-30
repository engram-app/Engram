import { ChevronRight, Plus, X } from "lucide-react";
import { useEffect, useRef, useState } from "react";
import { toast } from "sonner";
import type * as Y from "yjs";
import { HelpTip } from "@/components/help-tip";
import { Checkbox } from "@/components/ui/checkbox";
import { cn } from "@/lib/utils";
import {
	addKey,
	frontmatterMaps,
	isOkfMatch,
	OKF_FIELD_HELP,
	type PropertyRow,
	readRows,
	removeKey,
	renameKey,
	setType,
	setValue,
} from "../crdt/frontmatter-doc";
import { htmlInputType, PropertyField } from "./property-fields";
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
function PropertyKeyInput({
	doc,
	name,
	okf,
	elRef,
}: {
	doc: Y.Doc;
	name: string;
	/** Key Engram reads AND whose value is the shape that field needs. */
	okf: boolean;
	/** Hands the live input up to the row, which is where the type menu lives. */
	elRef?: (el: HTMLInputElement | null) => void;
}) {
	const [draft, setDraft] = useState(name);
	const ref = useRef<HTMLInputElement>(null);
	useEffect(() => {
		if (document.activeElement !== ref.current) {
			setDraft(name);
		}
	}, [name]);

	const commit = () => {
		const next = draft.trim();
		if (next === name) {
			setDraft(name);
			return;
		}
		if (!renameKey(doc, name, draft)) {
			// Refusing is right; refusing in silence is not. In a chromeless input
			// a value snapping back is easy to miss, and the user walks away
			// believing the rename landed.
			if (next !== "") {
				toast.error(`A property named "${next}" already exists`);
			}
			setDraft(name);
		}
	};

	return (
		<input
			ref={(el) => {
				ref.current = el;
				elRef?.(el);
			}}
			aria-label={`Rename ${name}`}
			// Highlighted when Engram READS the key rather than merely storing it.
			// No tooltip: the `?` beside the heading is where the explanation
			// lives, and a per-key hover repeating it is noise on every row.
			className={cn(
				"w-full min-w-0 truncate border-0 bg-transparent px-2 py-1 text-sm outline-none",
				okf ? "text-primary" : "text-muted-foreground",
			)}
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

/** What the `?` beside the Properties heading says.
 *
 *  Two questions, in the order someone actually asks them: what IS this block,
 *  and does what I put in it matter. The second is the reason this exists --
 *  most keys are stored and handed back unchanged, but a handful are read,
 *  indexed and used by search, and nothing on screen said which. */
function PropertiesHelp() {
	return (
		<>
			<p>
				Properties are the note's <strong>frontmatter</strong>: a block at the very top of the file,
				fenced by <code>---</code>. Obsidian shows the same block as Properties, so a note edited in
				either place reads the same in both.
			</p>
			<p className="mt-2">
				Any property you add is stored and synced. These are the ones Engram also{" "}
				<strong>reads</strong> — it indexes them into their own columns and search uses them, so
				filling them in does more than record a note about the note:
			</p>
			<dl className="mt-2 space-y-1">
				{OKF_FIELD_HELP.map(({ key, aliases, expectsLabel, what }) => (
					<div key={key} className="flex gap-2">
						<dt className="w-24 shrink-0 font-mono text-foreground">{key}</dt>
						<dd className="flex-1 text-muted-foreground">
							{what} Wants {expectsLabel}.
							{aliases.length > 0 ? (
								<span className="block opacity-80">
									also accepts {aliases.map((a) => `\`${a}\``).join(" or ")}
								</span>
							) : null}
						</dd>
					</div>
				))}
			</dl>
			<p className="mt-2">
				These field names come from the{" "}
				<a
					href="https://github.com/GoogleCloudPlatform/knowledge-catalog/tree/main/okf"
					target="_blank"
					rel="noreferrer noopener"
					className="text-primary underline underline-offset-2"
				>
					Open Knowledge Format
				</a>
				, the open standard Engram follows — so using them keeps your notes portable to anything
				else that reads OKF. Any other name is yours to invent; it syncs like everything else.
			</p>
		</>
	);
}

export function PropertiesWidget({ doc, draft = false, onAbandonDraft }: Props) {
	const [rows, setRows] = useState<PropertyRow[]>(() => readRows(doc));
	const newKeyRef = useRef<HTMLInputElement>(null);
	// Holds whichever control the chosen type renders — a checkbox is a
	// button, not an input, so this is widened to HTMLElement.
	const newValueRef = useRef<HTMLElement | null>(null);
	const rootRef = useRef<HTMLElement>(null);
	const detailsRef = useRef<HTMLDetailsElement>(null);
	// Clicking the `?` inside the <summary> also fires the summary's default
	// action, collapsing the very thing you asked about. It cannot be cancelled
	// with preventDefault: Radix ignores a default-prevented click, so that
	// closes the popover too. So let the toggle happen and put it straight back.
	const helpToggle = useRef<{ pending: boolean; wasOpen: boolean }>({
		pending: false,
		wasOpen: true,
	});
	// Key inputs by property name, so choosing a type can put the caret on the
	// name it belongs to. Keyed by name rather than index: a rename swaps the
	// key and an index would then point at a different row.
	const keyEls = useRef(new Map<string, HTMLInputElement>());

	useEffect(() => {
		const refresh = () => setRows(readRows(doc));
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
		// Every new property starts as text. The picker is per-property, not a
		// mode, so carrying the last choice forward silently typed the next
		// property as whatever the previous one happened to be. This is the only
		// path that closes the row (commit, Escape and click-away all land here),
		// so resetting once here covers reopening from anywhere.
		setNewType("text");
		setAdding(false);
		// Always tell the parent the row is gone, committed or not. `draft` is a
		// REQUEST to open, and the parent lowers its flag here; leaving it raised
		// latches the editor shut, because asking again just sets an unchanged
		// flag and React bails out. The `---` gesture would then eat the user's
		// three characters and open nothing.
		onAbandonDraft?.();
	};

	/**
	 * `duplicate` is NOT a failure to discard — the user typed a real name that
	 * happens to be taken. Collapsing it into "nothing was entered" threw away
	 * both the key and the value they had just typed.
	 */
	const commitNewKey = (): "committed" | "empty" | "duplicate" => {
		const key = newKey.trim();
		if (key === "") {
			return "empty";
		}
		if (!addKey(doc, newKey, newType)) {
			toast.error(`A property named "${key}" already exists`);
			return "duplicate";
		}
		if (newValue !== "") {
			setValue(doc, key, coerceValue(newValue, newType));
		}
		cancelAdding();
		return "committed";
	};

	// Read by the click-away effect, which must not re-subscribe on every
	// keystroke just to see the latest text.
	const leaving = useRef<{ commit: typeof commitNewKey; cancel: () => void } | null>(null);
	// biome-ignore lint/nursery/useReactCompiler: latest-ref pattern, deliberate. Writing during render is the point: it keeps the callback identity stable so the consuming effect does not re-fire on every render. See the comment above.
	leaving.current = { commit: commitNewKey, cancel: cancelAdding };

	// The `---` gesture means "I want a property", so it opens the new row
	// directly rather than making the user find the button.
	useEffect(() => {
		if (draft) {
			// biome-ignore lint/nursery/useReactCompiler: opening the new-property row is a reaction to the `---` gesture, not derived state -- `adding` is also cleared by cancelAdding() while `draft` is still set, so deriving it from `draft` would make the row impossible to close.
			setAdding(true);
		}
	}, [draft]);

	useEffect(() => {
		if (!adding) {
			return;
		}
		// The block may be COLLAPSED. Its contents are then not rendered, so
		// focus() is a no-op and the note menu's "Add property" looks like it did
		// nothing — while the dismiss listener is armed, so the next click outside
		// quietly throws the row away. Opening first is what makes the command
		// visible. Set imperatively because `details` is uncontrolled here on
		// purpose: React must not own the state the user toggles.
		if (detailsRef.current) {
			detailsRef.current.open = true;
		}
		newKeyRef.current?.focus();
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
			const target = event.target instanceof Element ? event.target : null;
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
			// as "never mind"; a name that collides keeps the row open so the
			// user can fix it instead of losing what they typed.
			const outcome = leaving.current?.commit();
			if (outcome !== "empty") {
				return;
			}
			leaving.current?.cancel();
		};
		document.addEventListener("pointerdown", dismiss);
		document.addEventListener("focusin", dismiss);
		return () => {
			document.removeEventListener("pointerdown", dismiss);
			document.removeEventListener("focusin", dismiss);
		};
		// `doc` and `onAbandonDraft` are reached through `leaving`, so they are
		// deliberately not deps — re-subscribing on every keystroke would be
		// churn for no behaviour change.
	}, [adding]);

	// A note with no frontmatter gets no bordered strip of nothing. Returning
	// null keeps the component MOUNTED and its Yjs observers live, so the
	// widget reappears the moment a key arrives from a remote peer or the raw
	// editor. Unmounting it at the call site instead would leave nobody
	// listening for that.
	if (rows.length === 0 && !draft && !adding) {
		return null;
	}

	return (
		// Row geometry is Obsidian's app.css: 3px between rows, a 9em key column,
		// 28px row height. The vertical rhythm around the block is NOT theirs.
		//
		// Equal 24px air on both sides of the block, tuned by eye. Up top that is
		// pt-5 against the title's own pb-1; below it is pb-1 plus CodeMirror's
		// 20px top padding, which is why the two paddings are not the same number.
		// Obsidian can nest this inside .cm-content and let one padding do both
		// jobs; ours is a sibling above the editor, so anything set here stacks on
		// top of that 20px instead of sharing it.
		<section className="mb-0 px-5 pt-5 pb-1" data-testid="note-properties" ref={rootRef}>
			{/* Obsidian's collapsible "Properties" heading. `details` carries the
			    open/closed state, the disclosure semantics and the keyboard
			    handling for free, so there is no state to hold here — and unlike a
			    button + conditional render, the rows stay in the DOM while closed,
			    which keeps the Yjs-driven `rows` and its observers untouched.

			    Marker hidden both ways: `list-none` covers Firefox, the
			    ::-webkit-details-marker rule covers Safari. */}
			<details
				ref={detailsRef}
				open
				className="group/props"
				onToggle={(e) => {
					if (!helpToggle.current.pending) {
						return;
					}
					// Restoring fires onToggle a second time; `pending` is already
					// false by then, so it falls through the guard above.
					const { wasOpen } = helpToggle.current;
					helpToggle.current.pending = false;
					e.currentTarget.open = wasOpen;
				}}
			>
				<summary
					data-testid="note-properties-toggle"
					className="group/summary flex cursor-pointer list-none items-center gap-1 pb-1 font-semibold text-base text-muted-foreground hover:text-foreground [&::-webkit-details-marker]:hidden"
				>
					{/* The chevron hangs in the section's own left padding (14px icon +
					    4px gap) so the WORD "Properties" starts on the same x as the
					    title above it. Left in the flow it pushed the label 18px right
					    of everything else and read as a nested item.

					    Revealed on hover, and on keyboard focus too — the summary is
					    focusable, so hover alone leaves a tabbing user pressing Enter
					    on a control with no visible affordance. Faded rather than
					    `hidden`: it keeps its box, so the label never jumps. */}
					<ChevronRight
						aria-hidden="true"
						className="-ml-[18px] size-3.5 opacity-100 transition-[opacity,rotate] group-open/props:rotate-90 group-open/props:opacity-0 group-open/props:group-hover/summary:opacity-100 group-open/props:group-focus-visible/summary:opacity-100"
					/>
					Properties
					{/* Inside the summary so it sits with the label — which means a
					    click on it would also fire the summary's default action and
					    COLLAPSE the thing you just asked about.

					    Undone rather than prevented -- see the ref above for why
					    preventDefault is not available here. */}
					<span
						className="ml-1 inline-flex align-middle"
						// Click, not pointerdown: capture still runs before the summary's
						// default action, and it is the one event every path produces --
						// mouse, touch, keyboard activation and fireEvent alike.
						onClickCapture={() => {
							helpToggle.current = {
								pending: true,
								wasOpen: detailsRef.current?.open ?? true,
							};
						}}
					>
						<HelpTip label="About properties" align="start">
							<PropertiesHelp />
						</HelpTip>
					</span>
				</summary>
				<dl className="flex flex-col gap-[3px]">
					{rows.map((row) => {
						const type = effectiveType(row.value, row.typeOverride);
						return (
							<div key={row.key} className={`group ${ROW}`} data-testid={`property-row-${row.key}`}>
								<dt className={KEY_CELL}>
									<PropertyTypeMenu
										value={type}
										onChange={(t) => setType(doc, row.key, t)}
										focusAfterSelect={() => keyEls.current.get(row.key) ?? null}
									/>
									<PropertyKeyInput
										doc={doc}
										name={row.key}
										okf={isOkfMatch(row.key, type)}
										elRef={(el) => {
											if (el) {
												keyEls.current.set(row.key, el);
											} else {
												keyEls.current.delete(row.key);
											}
										}}
									/>
								</dt>
								<dd className="flex min-h-7 flex-1 items-center gap-1 pl-2">
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
									className="mr-1 flex size-7 shrink-0 items-center justify-center rounded text-muted-foreground opacity-0 transition-opacity hover:bg-destructive/10 hover:text-destructive focus:opacity-100 group-hover:opacity-100"
								>
									<X aria-hidden="true" className="size-3.5" />
								</button>
							</div>
						);
					})}

					{/* The row being authored. Same geometry as a committed one, so
				    naming a property looks like the row it is about to become. */}
					{adding ? (
						<div className={ROW} data-testid="new-property-row">
							<dt className={KEY_CELL}>
								<PropertyTypeMenu
									value={newType}
									onChange={(t) => {
										if (t === newType) {
											return;
										}
										setNewType(t);
										// Reset the pending value with the type. A half-typed
										// string means nothing to the new control (a date input
										// silently drops "hello"), and an unchecked checkbox has
										// to commit `false` rather than commit nothing at all —
										// commitNewKey skips an empty value.
										setNewValue(t === "checkbox" ? "false" : "");
									}}
									focusAfterSelect={() => newKeyRef.current}
								/>
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
							<dd className="flex min-h-7 flex-1 items-center gap-1 pl-2">
								{newType === "checkbox" ? (
									<Checkbox
										ref={(el) => {
											newValueRef.current = el;
										}}
										aria-label="New property value"
										// Every other value control here cancels on Escape. Without
										// this the checkbox branch swallowed it, and tabbing away
										// then COMMITTED the property the user was cancelling.
										// Radix preventDefaults Enter, but composeEventHandlers
										// runs this first, so Enter still commits.
										onKeyDown={(e) => {
											if (e.key === "Enter") {
												e.preventDefault();
												commitNewKey();
											} else if (e.key === "Escape") {
												e.preventDefault();
												cancelAdding();
											}
										}}
										checked={newValue === "true"}
										onCheckedChange={(c) => setNewValue(c === true ? "true" : "false")}
									/>
								) : (
									<input
										ref={(el) => {
											newValueRef.current = el;
										}}
										type={htmlInputType(newType)}
										aria-label="New property value"
										className="w-full min-w-0 border-0 bg-transparent py-1 pr-2 text-foreground text-sm outline-none placeholder:text-muted-foreground/60"
										// A date/datetime/number input draws its own skeleton
										// (mm/dd/yyyy, the spinner); a placeholder on top of that
										// is noise, and browsers ignore it anyway.
										placeholder={newType === "text" || newType === "list" ? "Value" : undefined}
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
								)}
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
			</details>
		</section>
	);
}
