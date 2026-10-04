import {
	acceptCompletion,
	type Completion,
	completionStatus,
	currentCompletions,
	selectedCompletionIndex,
	setSelectedCompletion,
} from "@codemirror/autocomplete";
import { type EditorState, Prec, StateField } from "@codemirror/state";
import { EditorView, showTooltip, type Tooltip, type TooltipView } from "@codemirror/view";
import { createRoot } from "react-dom/client";
import { ScrollArea } from "@/components/ui/scroll-area";
import { LIST_ROW_GAP, listRowClass } from "@/lib/ui-classes";
import { cn } from "@/lib/utils";

const LIST_ID = "engram-completion-list";
const optionId = (i: number): string => `engram-completion-opt-${i}`;

interface ListProps {
	completions: readonly Completion[];
	selected: number;
	onPick: (index: number) => void;
}

function CompletionList({ completions, selected, onPick }: ListProps) {
	return (
		<div className="engram-completion min-w-72 max-w-md overflow-hidden rounded-lg border border-border bg-popover text-base text-popover-foreground shadow-md">
			{/* py-2 is OUTSIDE the scrolling viewport on purpose: padding inside it scrolls
			    away with the rows, leaving them against the border mid-scroll. */}
			<ScrollArea className="py-2" viewportClassName="max-h-80">
				<div
					id={LIST_ID}
					role="listbox"
					aria-label="Link suggestions"
					// Sides only: the 8px above and below is the ScrollArea's own py-2, which stays put
					// while the rows scroll (a p-2 here would double it at the top of the list).
					className="flex flex-col px-2"
					style={{ gap: LIST_ROW_GAP }}
				>
					{completions.map((c, i) => (
						// biome-ignore lint/a11y/useFocusableInteractive: the editor owns focus; options are driven by the completion keymap (arrows/Enter) and a press
						<div
							key={`${c.label}\u0000${c.detail ?? ""}`}
							// Keyboard moves the selection; keep it on screen.
							ref={(el) => {
								if (i === selected) {
									el?.scrollIntoView?.({ block: "nearest" });
								}
							}}
							id={optionId(i)}
							role="option"
							aria-selected={i === selected}
							// mousedown, not click: a click would first move focus out of the editor.
							onMouseDown={(e) => {
								e.preventDefault();
								onPick(i);
							}}
							// Same row as the tree and the vault picker, two lines tall because it carries
							// the folder under the name.
							className={cn(
								listRowClass({ selected: i === selected }),
								"cursor-default flex-col items-start gap-0 py-1.5 pl-2",
							)}
						>
							<span className="max-w-full truncate font-semibold">{c.label}</span>
							{c.detail ? (
								<span
									className={cn(
										"max-w-full truncate text-xs",
										i === selected ? "opacity-75" : "text-muted-foreground",
									)}
								>
									{c.detail}
								</span>
							) : null}
						</div>
					))}
				</div>
			</ScrollArea>
		</div>
	);
}

function open(state: EditorState): boolean {
	return completionStatus(state) === "active" && currentCompletions(state).length > 0;
}

function createPopup(view: EditorView): TooltipView {
	const dom = document.createElement("div");
	const root = createRoot(dom);
	const render = (state: EditorState) => {
		root.render(
			<CompletionList
				completions={currentCompletions(state)}
				selected={selectedCompletionIndex(state) ?? 0}
				onPick={(index) => {
					view.dispatch({ effects: setSelectedCompletion(index) });
					acceptCompletion(view);
				}}
			/>,
		);
	};
	render(view.state);
	return {
		dom,
		update: (u) => render(u.state),
		// After CM's own teardown, never during a render.
		destroy: () => queueMicrotask(() => root.unmount()),
	};
}

/**
 * The completion list, drawn with the app's own components instead of CodeMirror's
 * built-in popup: the shared ScrollArea and `listRowClass` rows, so it is the same
 * list as the file tree and the vault picker (a `<ul>` CodeMirror renders itself
 * cannot take a React ScrollArea). It is driven by CodeMirror's completion state,
 * so sources, filtering and the arrow/Enter/Escape keys are all still CodeMirror's.
 * Pair with `autocompletion({ tooltipClass: () => NATIVE_POPUP_CLASS })`, which
 * hides the built-in one.
 */
const popupField = StateField.define<Tooltip | null>({
	create: () => null,
	update: (_, tr) =>
		open(tr.state)
			? // Same `create` every time, so CodeMirror keeps one popup and moves it.
				{ pos: tr.state.selection.main.head, above: false, create: createPopup }
			: null,
	provide: (f) => [
		showTooltip.from(f),
		// CodeMirror points the editor's aria-controls / aria-activedescendant at ITS list,
		// which is hidden, so screen readers would hear nothing as you arrow through the
		// suggestions. Point them at ours (this wins over the built-in because it is
		// registered with higher precedence in `completionPopup` below).
		EditorView.contentAttributes.compute(
			[f],
			(state): Record<string, string> =>
				state.field(f)
					? {
							"aria-controls": LIST_ID,
							"aria-activedescendant": optionId(selectedCompletionIndex(state) ?? 0),
						}
					: {},
		),
	],
});

export const NATIVE_POPUP_CLASS = "cm-completion-native";

export const completionPopup = [
	Prec.highest(popupField),
	EditorView.baseTheme({
		// The built-in popup is replaced; keep it from drawing next to ours.
		[`.cm-tooltip.${NATIVE_POPUP_CLASS}`]: { display: "none !important" },
		// CM wraps every tooltip in its own bordered, backgrounded box. Ours draws its own.
		".cm-tooltip:has(> .engram-completion)": {
			border: "none",
			background: "transparent",
			boxShadow: "none",
		},
	}),
];
