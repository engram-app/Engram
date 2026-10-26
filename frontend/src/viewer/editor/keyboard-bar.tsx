import { startCompletion } from "@codemirror/autocomplete";
import { EditorView } from "@codemirror/view";
import type { LucideIcon } from "lucide-react";
import {
	Bold,
	Brackets,
	Code,
	Heading,
	IndentDecrease,
	IndentIncrease,
	Italic,
	Link,
	List,
	ListOrdered,
	Quote,
	Redo2,
	SquareCheckBig,
	Strikethrough,
	Undo2,
} from "lucide-react";
import { useLayoutEffect, useRef, useState } from "react";
import { yUndoManagerKeymap } from "y-codemirror.next";
import { Button } from "@/components/ui/button";
import { useMediaQuery } from "@/hooks/use-media-query";
import { useT } from "@/i18n/locale-provider";
import { msg } from "@/i18n/msg";
import type { MsgKey } from "@/i18n/ui-text";
import {
	indentSelection,
	insertLink,
	outdentSelection,
	setHeading,
	toggleCheckbox,
	toggleCode,
	toggleList,
	toggleQuote,
	toggleWrap,
} from "./format-commands";
import { EDITOR_TOOLBAR, useEditorFocused } from "./use-editor-focused";
import { readViewportBox, useKeyboardOpen, useVisualViewportBox } from "./use-keyboard-inset";

/**
 * History lives in Yjs, not CodeMirror. The editor installs yCollab, which owns
 * a Y.UndoManager and binds it to Ctrl+Z / Ctrl+Y through yUndoManagerKeymap;
 * it does NOT install @codemirror/commands' history, so that package's `undo`
 * would find no history extension and silently do nothing.
 *
 * Run the keymap's own bindings rather than reaching for a manager directly.
 * The package does not export its undo/redo commands from its root and its
 * `exports` map blocks deep imports. `ySyncFacet(...).undoManager` is a decoy:
 * YSyncConfig's constructor mints its own Y.UndoManager, not the one yCollab
 * is given. The real one is crdt/undo.ts's undoManagerFor(doc), but this bar
 * only holds the view; the keymap reaches that same manager from it.
 */
function runBinding(key: string, view: EditorView): void {
	yUndoManagerKeymap.find((b) => b.key === key)?.run?.(view);
}

function undoEdit(view: EditorView): void {
	runBinding("Mod-z", view);
}

function redoEdit(view: EditorView): void {
	runBinding("Mod-y", view);
}

/**
 * `[[ ]]` around the selection (or an empty pair with the caret inside), then
 * open the note picker.
 *
 * The picker does not open by itself: CM6's autocompletion activates on
 * transactions it recognises as typing, and a programmatic dispatch is not one
 * — so the button would otherwise leave you with empty brackets and no list.
 * startCompletion runs the same wikiCompletionSource `[[` typed by hand does,
 * and its apply() already handles the closing brackets being there ahead of it.
 */
function insertWikiLink(view: EditorView): void {
	toggleWrap(view, "[[", "]]");
	startCompletion(view);
}

const HEADING_LEVELS = [1, 2, 3, 4, 5, 6];

/**
 * The command row, grouped by kind: history, inline marks, block structure and
 * everything that acts on a list item, then inserts.
 *
 * The grouping is nested arrays rather than comments between JSX blocks so that
 * the order IS the data — half the row is off screen at any time, so where a
 * button sits is a decision worth being able to read at a glance. `Indent` and
 * `Outdent` sit in the third group deliberately: on a phone their only real use
 * is nesting a list item, so beside `Undo` they read as history controls.
 */
const COMMAND_GROUPS: ReadonlyArray<
	ReadonlyArray<{ label: MsgKey; Icon: LucideIcon; act?: (view: EditorView) => void }>
> = [
	[
		{ label: msg("Undo edit"), Icon: Undo2, act: undoEdit },
		{ label: msg("Redo edit"), Icon: Redo2, act: redoEdit },
	],
	[
		{ label: msg("Bold"), Icon: Bold, act: (v) => toggleWrap(v, "**") },
		{ label: msg("Italic"), Icon: Italic, act: (v) => toggleWrap(v, "*") },
		{ label: msg("Strikethrough"), Icon: Strikethrough, act: (v) => toggleWrap(v, "~~") },
		{ label: msg("Code"), Icon: Code, act: toggleCode },
	],
	[
		// No `act`: this is the one button that opens a panel — the level row —
		// rather than editing the document.
		{ label: msg("Heading"), Icon: Heading },
		{ label: msg("Quote"), Icon: Quote, act: toggleQuote },
		{ label: msg("Bullet list"), Icon: List, act: (v) => toggleList(v, false) },
		{ label: msg("Numbered list"), Icon: ListOrdered, act: (v) => toggleList(v, true) },
		{ label: msg("Toggle checkbox"), Icon: SquareCheckBig, act: toggleCheckbox },
		{
			label: msg("Outdent"),
			Icon: IndentDecrease,
			act: (v) => {
				outdentSelection(v);
			},
		},
		{
			label: msg("Indent"),
			Icon: IndentIncrease,
			act: (v) => {
				indentSelection(v);
			},
		},
	],
	[
		// Two link buttons on purpose: the wikilink one opens the note picker,
		// the other is for an external URL you are about to paste.
		{ label: msg("Wiki link"), Icon: Brackets, act: insertWikiLink },
		{ label: msg("Link"), Icon: Link, act: insertLink },
	],
];

/**
 * How much bottom-edge space the toolbar is currently eating, published for the
 * other things anchored to that edge — today the setup-checklist FAB, which was
 * landing on top of the bar as soon as the keyboard opened.
 *
 * A CSS variable rather than a React context: the consumers are unrelated
 * subtrees that only need a number, and CSS can do the arithmetic in `calc()`.
 * MEASURED, not a constant, because the bar grows a second row when the heading
 * picker is open — a hardcoded height would be covered again exactly then.
 */
const TOOLBAR_OFFSET_VAR = "--editor-toolbar-offset";

/**
 * Tells CodeMirror how much of the visible area the bar covers, so scrolling
 * the caret into view keeps it above the bar. CodeMirror measures against the
 * visual viewport, which knows nothing about this bar; without the margin,
 * typing on the last visible line put the caret behind it.
 *
 * Measured from the live element at scroll time rather than published from
 * React: the bar's height changes with the heading row, and its position with
 * the keyboard, and the DOM is the one place both are already true.
 */
export const toolbarScrollMargin = EditorView.scrollMargins.of(() => {
	const bar = document.querySelector<HTMLElement>(EDITOR_TOOLBAR);
	if (!bar) {
		return null;
	}
	const { top, height } = readViewportBox();
	return { bottom: Math.max(0, top + height - bar.getBoundingClientRect().top) };
});

/**
 * The strip of editor actions docked above the on-screen keyboard, Obsidian's
 * mobile toolbar in miniature.
 *
 * Scope is the commands a soft keyboard cannot reach or makes tedious: indent
 * and outdent have no Tab key to bind to on a phone, and every marker-based
 * format means hunting the symbol layer for characters that come in pairs.
 *
 * Mobile only, and only while the keyboard is actually up: on desktop the
 * markdown shortcuts and Tab/Shift-Tab already cover this, and a bar pinned
 * over the document with no keyboard under it is just lost height.
 */
export function KeyboardBar({ getView }: { getView: () => EditorView | null }) {
	const { t } = useT();
	const isDesktop = useMediaQuery("(min-width: 768px)");
	const focused = useEditorFocused();
	const box = useVisualViewportBox();
	const keyboardOpen = useKeyboardOpen();
	const [headingsOpen, setHeadingsOpen] = useState(false);
	const [gesturing, setGesturing] = useState(false);
	const barRef = useRef<HTMLElement>(null);

	// Both conditions are load-bearing, and neither can be "the visible box is
	// shorter than the window". Focus alone stranded the bar over the document
	// after the keyboard was dismissed with the platform's hide button, which
	// leaves the editor focused. A non-zero inset alone hid the bar outright on
	// browsers that resize the LAYOUT viewport, where the inset is 0 with the
	// keyboard fully open — so useKeyboardOpen compares viewport heights
	// instead, and the box is used only to position.
	//
	// `gesturing` overrides both for the duration of a touch. Panning the command
	// row blurs the editor on browsers where pointerdown is not cancelable, which
	// closes the keyboard and fails BOTH conditions at once — and unmounting
	// mid-gesture detaches the very handler that would put focus back, so the
	// hold is what makes the repair below reachable at all.
	const visible = !isDesktop && (gesturing || (focused && keyboardOpen));

	// Observes the bar instead of re-measuring on every render.
	// getBoundingClientRect forces a synchronous layout, and this component
	// re-renders on every visualViewport scroll event — those fire continuously
	// while the caret moves.
	//
	// A ResizeObserver also removes the need to ENUMERATE what changes the
	// height. Depending on `headingsOpen` would be depending on a proxy for the
	// real thing, which is the rendered height — and would silently miss the next
	// cause (a wrapped row, a late-loading font, a third row).
	useLayoutEffect(() => {
		const root = document.documentElement;
		const bar = barRef.current;
		if (!(visible && bar)) {
			root.style.removeProperty(TOOLBAR_OFFSET_VAR);
			return;
		}
		// From the bar's top to the bottom of the window: the bottom-anchored FAB
		// is fixed to the layout viewport, so this is what it has to clear.
		const publish = () => {
			root.style.setProperty(
				TOOLBAR_OFFSET_VAR,
				`${Math.round(window.innerHeight - bar.getBoundingClientRect().top)}px`,
			);
		};
		publish();
		const observer = new ResizeObserver(publish);
		observer.observe(bar);
		return () => {
			observer.disconnect();
			root.style.removeProperty(TOOLBAR_OFFSET_VAR);
		};
	}, [visible, box.top, box.height]);

	if (!visible) {
		return null;
	}

	const run = (fn: (v: EditorView) => void) => () => {
		const v = getView();
		if (v) {
			fn(v);
		}
	};

	// Put the caret — and with it the keyboard — back when the gesture ends.
	// Still inside the user gesture, which is what lets a programmatic focus()
	// re-open the on-screen keyboard rather than being ignored.
	const endGesture = () => {
		getView()?.focus();
		setGesturing(false);
	};

	return (
		// A fixed frame exactly the size of the visible area, with the bar docked
		// to its bottom: above the keyboard on every browser, with no transform.
		// See readViewportBox for why not a bottom-0 bar lifted by an inset.
		// pointer-events-none so the frame never eats a tap on the document.
		<div
			className="pointer-events-none fixed inset-x-0 z-40"
			style={{ top: box.top, height: box.height }}
		>
			<nav
				ref={barRef}
				role="toolbar"
				aria-label={t("Editor actions")}
				// Android docks flat against the keyboard. iOS floats it as a rounded
				// pill with a gap: iOS 26 draws its AutoFill/accessory row as a
				// separate floating bubble, and a flush bar reads as swallowed by it.
				className="pointer-events-auto absolute inset-x-0 bottom-0 flex flex-col border-border border-t bg-card ios:inset-x-2 ios:bottom-2 ios:overflow-hidden ios:rounded-2xl ios:border ios:shadow-lg"
				// Marks this subtree as still "the editor" for useEditorFocused, so a
				// pan that lands focus on the bar does not unmount it mid-drag.
				data-editor-toolbar=""
				// Keep the keyboard up. A pointerdown that reaches the document blurs
				// the editor, iOS dismisses the keyboard, and the bar this lives on
				// slides away mid-tap — so the press must never move focus. The heading
				// row lives INSIDE this nav rather than in a portalled popover so it is
				// covered by the same guard.
				//
				// This is NOT sufficient on its own. `touch-action: pan-x` on the
				// command row is what lets it scroll, and it also makes pointerdown
				// non-cancelable for touch in Chrome — the browser reserves the right
				// to start a pan — so preventDefault silently becomes a no-op there and
				// the drag blurs the editor anyway. Hence the hold and the repair.
				onPointerDown={(e) => {
					e.preventDefault();
					setGesturing(true);
				}}
				// BOTH endings are needed: a tap ends in pointerup, but a pan the
				// browser takes over ends in pointercancel and never fires pointerup —
				// which is why repairing focus on pointerup alone did not help.
				onPointerUp={endGesture}
				onPointerCancel={endGesture}
			>
				{headingsOpen ? (
					<section
						aria-label={t("Heading level")}
						className="flex items-center justify-around border-border border-b px-2 py-1.5 [&>button]:size-11"
					>
						{HEADING_LEVELS.map((level) => (
							<Button
								key={level}
								variant="ghost"
								size="icon"
								aria-label={t("Heading {level}", { level })}
								onClick={run((v) => {
									setHeading(v, level);
									setHeadingsOpen(false);
								})}
							>
								<span className="font-semibold text-base">H{level}</span>
							</Button>
						))}
					</section>
				) : null}
				{/* A dozen buttons at a 44px target (WCAG 2.5.5) run past 600px, so the
			    row pans under a finger rather than shrinking below thumb size --
			    a phone gets full-size icons and scrolls, instead of a full set of
			    cramped ones. The scrollbar is hidden because a visible track on a
			    56px strip is noise; the partially-visible last button is the
			    affordance. touch-action keeps the pan working despite the nav's
			    pointerdown preventDefault, which governs focus, not scrolling.
			    Order is grouped by kind, since half the row is always off screen. */}
				<section
					aria-label={t("Editor commands")}
					className="flex touch-pan-x items-center gap-2 overflow-x-auto px-2 py-1.5 [scrollbar-width:none] [&::-webkit-scrollbar]:hidden [&>button]:size-11 [&>button]:shrink-0"
				>
					{COMMAND_GROUPS.flat().map(({ label, Icon, act }) => (
						<Button
							key={label}
							variant="ghost"
							size="icon"
							aria-label={t(label)}
							// No `act` means the panel button; see COMMAND_GROUPS.
							aria-expanded={act ? undefined : headingsOpen}
							onClick={act ? run(act) : () => setHeadingsOpen((open) => !open)}
						>
							<Icon className="size-6" />
						</Button>
					))}
				</section>
			</nav>
		</div>
	);
}
