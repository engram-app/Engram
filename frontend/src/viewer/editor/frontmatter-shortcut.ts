import type { Extension } from "@codemirror/state";
import { EditorView } from "@codemirror/view";

export const FRONTMATTER_FENCE = "---";

/**
 * Obsidian's gesture: typing `---` on the first line opens the properties
 * editor rather than leaving a horizontal rule behind.
 *
 * Frontmatter is NOT part of the body here — it lives in its own Y.Map /
 * Y.Array (see `crdt/frontmatter-doc`). So the fence can never become
 * frontmatter by being typed; it is a trigger, and this extension's job is to
 * report it and then take the characters back out of the body.
 *
 * `onTrigger` decides whether the gesture applies — it declines when the note
 * already has frontmatter, in which case the fence stays as an ordinary rule.
 * Only a `true` return removes it.
 */
export function frontmatterShortcut(onTrigger: () => boolean): Extension {
	return EditorView.updateListener.of((update) => {
		if (!update.docChanged) {
			return;
		}
		// Typed only. A paste keeps its literal `---`, and an undo restoring the
		// fence must not re-fire — that would delete it again and the two would
		// fight forever.
		if (!update.transactions.some((tr) => tr.isUserEvent("input.type"))) {
			return;
		}
		const first = update.state.doc.lineAt(0);
		if (first.text !== FRONTMATTER_FENCE) {
			return;
		}
		// A body that legitimately opens with a horizontal rule would otherwise
		// lose it the moment you typed anywhere else in the note: the first line
		// reads `---` on every keystroke. Only react when the edit actually
		// landed INSIDE that line.
		//
		// Not `touchesRange`: it takes pre-change coordinates while `first` is
		// post-change, and it counts an insertion AT the endpoint as touching —
		// so pressing Enter at the end of an existing `---` rule deleted it.
		// iterChanges reports fromB/toB in the new document, and the comparison
		// is exclusive at both ends.
		let touchedFence = false;
		update.changes.iterChanges((_fromA, _toA, fromB, toB) => {
			if (fromB < first.to && toB > first.from) {
				touchedFence = true;
			}
		});
		if (!touchedFence) {
			return;
		}
		if (!onTrigger()) {
			return;
		}
		// Deferred: dispatching inside an update listener throws.
		queueMicrotask(() => {
			const { view } = update;
			const line = view.state.doc.lineAt(0);
			// Re-checked because anything — a remote CRDT delta, an undo — may
			// have landed between the update and this microtask.
			if (line.text !== FRONTMATTER_FENCE) {
				return;
			}
			view.dispatch({
				// Takes the trailing newline too, so the body does not inherit a
				// blank first line.
				changes: { from: 0, to: Math.min(view.state.doc.length, line.to + 1) },
				userEvent: "delete.frontmatter",
			});
		});
	});
}
