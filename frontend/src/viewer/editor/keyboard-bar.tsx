import { indentLess, indentMore } from "@codemirror/commands";
import type { EditorView } from "@codemirror/view";
import { IndentDecrease, IndentIncrease, List, SquareCheckBig } from "lucide-react";
import { Button } from "@/components/ui/button";
import { useMediaQuery } from "@/hooks/use-media-query";
import { toggleCheckbox, toggleLinePrefix } from "./format-commands";
import { useKeyboardInset } from "./use-keyboard-inset";

/**
 * The strip of editor actions docked above the on-screen keyboard, Obsidian's
 * mobile toolbar in miniature.
 *
 * Scope is deliberately the commands a soft keyboard CANNOT otherwise reach:
 * indent and outdent have no Tab key to bind to on a phone, and toggling a
 * checkbox by hand means typing six characters mid-line. Bold/italic are
 * omitted on purpose — `**` is two taps and already works.
 *
 * Mobile only, and only while the keyboard is actually up: on desktop the
 * markdown shortcuts and Tab/Shift-Tab already cover this, and a bar pinned
 * over the document with no keyboard under it is just lost height.
 */
export function KeyboardBar({ getView }: { getView: () => EditorView | null }) {
	const isDesktop = useMediaQuery("(min-width: 768px)");
	const inset = useKeyboardInset();

	if (isDesktop || inset === 0) {
		return null;
	}

	const run = (fn: (v: EditorView) => void) => () => {
		const v = getView();
		if (v) {
			fn(v);
		}
	};

	return (
		<nav
			role="toolbar"
			aria-label="Editor actions"
			// Docked to the bottom of the LAYOUT viewport and lifted by the measured
			// inset, rather than positioned in the visual viewport: iOS does not
			// reflow the layout viewport for the keyboard, so bottom-0 alone sits
			// behind it.
			className="fixed inset-x-0 bottom-0 z-40 flex items-center gap-1 border-border border-t bg-card px-2 py-1.5"
			style={{ transform: `translateY(-${inset}px)` }}
			// Keep the keyboard up. A pointerdown that reaches the document blurs
			// the editor, iOS dismisses the keyboard, and the bar this lives on
			// slides away mid-tap — so the press must never move focus.
			onPointerDown={(e) => e.preventDefault()}
		>
			<Button
				variant="ghost"
				size="icon"
				aria-label="Outdent"
				onClick={run((v) => {
					indentLess(v);
				})}
			>
				<IndentDecrease className="size-5" />
			</Button>
			<Button
				variant="ghost"
				size="icon"
				aria-label="Indent"
				onClick={run((v) => {
					indentMore(v);
				})}
			>
				<IndentIncrease className="size-5" />
			</Button>
			<Button
				variant="ghost"
				size="icon"
				aria-label="Toggle checkbox"
				onClick={run(toggleCheckbox)}
			>
				<SquareCheckBig className="size-5" />
			</Button>
			<Button
				variant="ghost"
				size="icon"
				aria-label="Bullet list"
				onClick={run((v) => toggleLinePrefix(v, "- "))}
			>
				<List className="size-5" />
			</Button>
		</nav>
	);
}
