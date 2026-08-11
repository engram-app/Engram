import { startCompletion } from "@codemirror/autocomplete";
import { indentLess, indentMore } from "@codemirror/commands";
import type { EditorView } from "@codemirror/view";
import {
	Bold,
	Brackets,
	Heading,
	IndentDecrease,
	IndentIncrease,
	Italic,
	List,
	ListOrdered,
	Redo2,
	SquareCheckBig,
	Strikethrough,
	Undo2,
} from "lucide-react";
import { useLayoutEffect, useRef, useState } from "react";
import { yUndoManagerKeymap } from "y-codemirror.next";
import { Button } from "@/components/ui/button";
import { useMediaQuery } from "@/hooks/use-media-query";
import { setHeading, toggleCheckbox, toggleList, toggleWrap } from "./format-commands";
import { useEditorFocused } from "./use-editor-focused";
import { useKeyboardInset, useKeyboardOpen } from "./use-keyboard-inset";

/**
 * History lives in Yjs, not CodeMirror. The editor installs yCollab, which owns
 * a Y.UndoManager and binds it to Ctrl+Z / Ctrl+Y through yUndoManagerKeymap;
 * it does NOT install @codemirror/commands' history, so that package's `undo`
 * would find no history extension and silently do nothing.
 *
 * Run the keymap's own bindings rather than reaching for a manager directly.
 * The package does not export its undo/redo commands from its root and its
 * `exports` map blocks deep imports, and the one manager that IS reachable —
 * `ySyncFacet(...).undoManager` — is a decoy: YSyncConfig's constructor mints
 * its own Y.UndoManager, a DIFFERENT instance from the one yCollab registers
 * tracked origins on, so undo() on it silently does nothing against an empty
 * stack. Going through the keymap guarantees the same manager Ctrl+Z drives.
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
	const isDesktop = useMediaQuery("(min-width: 768px)");
	const focused = useEditorFocused();
	const inset = useKeyboardInset();
	const keyboardOpen = useKeyboardOpen();
	const [headingsOpen, setHeadingsOpen] = useState(false);
	const [gesturing, setGesturing] = useState(false);
	const barRef = useRef<HTMLElement>(null);

	// Both conditions are load-bearing, and neither can be the inset. Focus alone
	// stranded the bar over the document after the keyboard was dismissed with
	// the platform's hide button, which leaves the editor focused. A non-zero
	// inset alone hid the bar outright on browsers that resize the LAYOUT
	// viewport, where the inset is 0 with the keyboard fully open — so
	// useKeyboardOpen compares viewport heights instead, and the inset is used
	// only to position.
	//
	// `gesturing` overrides both for the duration of a touch. Panning the command
	// row blurs the editor on browsers where pointerdown is not cancelable, which
	// closes the keyboard and fails BOTH conditions at once — and unmounting
	// mid-gesture detaches the very handler that would put focus back, so the
	// hold is what makes the repair below reachable at all.
	const visible = !isDesktop && (gesturing || (focused && keyboardOpen));

	// No dependency array: the bar's height changes with the heading row, and
	// re-measuring on every render is a single getBoundingClientRect on an
	// element that is already in the layout.
	useLayoutEffect(() => {
		const root = document.documentElement;
		if (!visible) {
			root.style.removeProperty(TOOLBAR_OFFSET_VAR);
			return;
		}
		const height = barRef.current?.getBoundingClientRect().height ?? 0;
		root.style.setProperty(TOOLBAR_OFFSET_VAR, `${height + inset}px`);
		return () => {
			root.style.removeProperty(TOOLBAR_OFFSET_VAR);
		};
	});

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
		<nav
			ref={barRef}
			role="toolbar"
			aria-label="Editor actions"
			// Docked to the bottom of the layout viewport and lifted by the measured
			// inset. Where only the visual viewport shrank (iOS, Chrome 108+) the
			// inset is the keyboard height and this lifts clear of it; where the
			// layout viewport shrank too, the inset is 0 and bottom-0 is already
			// sitting on top of the keyboard. One expression covers both.
			className="fixed inset-x-0 bottom-0 z-40 flex flex-col border-border border-t bg-card"
			style={{ transform: `translateY(-${inset}px)` }}
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
					aria-label="Heading level"
					className="flex items-center justify-around border-border border-b px-2 py-1.5 [&>button]:size-11"
				>
					{HEADING_LEVELS.map((level) => (
						<Button
							key={level}
							variant="ghost"
							size="icon"
							aria-label={`Heading ${level}`}
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
			{/* Eleven buttons at a 44px target (WCAG 2.5.5) are ~580px wide, so the
			    row pans under a finger rather than shrinking below thumb size --
			    a phone gets full-size icons and scrolls, instead of a full set of
			    cramped ones. The scrollbar is hidden because a visible track on a
			    56px strip is noise; the partially-visible last button is the
			    affordance. touch-action keeps the pan working despite the nav's
			    pointerdown preventDefault, which governs focus, not scrolling. */}
			<section
				aria-label="Editor commands"
				className="flex touch-pan-x items-center gap-2 overflow-x-auto px-2 py-1.5 [scrollbar-width:none] [&::-webkit-scrollbar]:hidden [&>button]:size-11 [&>button]:shrink-0"
			>
				<Button variant="ghost" size="icon" aria-label="Undo" onClick={run(undoEdit)}>
					<Undo2 className="size-6" />
				</Button>
				<Button variant="ghost" size="icon" aria-label="Redo" onClick={run(redoEdit)}>
					<Redo2 className="size-6" />
				</Button>
				<Button
					variant="ghost"
					size="icon"
					aria-label="Outdent"
					onClick={run((v) => {
						indentLess(v);
					})}
				>
					<IndentDecrease className="size-6" />
				</Button>
				<Button
					variant="ghost"
					size="icon"
					aria-label="Indent"
					onClick={run((v) => {
						indentMore(v);
					})}
				>
					<IndentIncrease className="size-6" />
				</Button>
				<Button
					variant="ghost"
					size="icon"
					aria-label="Bold"
					onClick={run((v) => toggleWrap(v, "**"))}
				>
					<Bold className="size-6" />
				</Button>
				<Button
					variant="ghost"
					size="icon"
					aria-label="Italic"
					onClick={run((v) => toggleWrap(v, "*"))}
				>
					<Italic className="size-6" />
				</Button>
				<Button
					variant="ghost"
					size="icon"
					aria-label="Strikethrough"
					onClick={run((v) => toggleWrap(v, "~~"))}
				>
					<Strikethrough className="size-6" />
				</Button>
				<Button
					variant="ghost"
					size="icon"
					aria-label="Toggle checkbox"
					onClick={run(toggleCheckbox)}
				>
					<SquareCheckBig className="size-6" />
				</Button>
				<Button
					variant="ghost"
					size="icon"
					aria-label="Heading"
					aria-expanded={headingsOpen}
					onClick={() => setHeadingsOpen((open) => !open)}
				>
					<Heading className="size-6" />
				</Button>
				<Button variant="ghost" size="icon" aria-label="Wiki link" onClick={run(insertWikiLink)}>
					<Brackets className="size-6" />
				</Button>
				<Button
					variant="ghost"
					size="icon"
					aria-label="Bullet list"
					onClick={run((v) => toggleList(v, false))}
				>
					<List className="size-6" />
				</Button>
				<Button
					variant="ghost"
					size="icon"
					aria-label="Numbered list"
					onClick={run((v) => toggleList(v, true))}
				>
					<ListOrdered className="size-6" />
				</Button>
			</section>
		</nav>
	);
}
