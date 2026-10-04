import { dropCursor, EditorView } from "@codemirror/view";
import { type DraggedVaultItem, readDraggedItem, VAULT_ITEM_MIME } from "../vault-item-drag";

/**
 * Drop a sidebar note or attachment onto the text to insert its link/embed at
 * the drop point. `linkText` decides the text (see vault-item-drag.linkTextFor).
 * Anything that is not a vault-item drag is left to the editor's defaults.
 */
export function itemDrop(opts: {
	linkText: (item: DraggedVaultItem) => string;
	/** OS files dropped on the text. Resolves to the link text to insert for them. */
	onFiles?: (files: File[]) => Promise<string[]>;
}) {
	const hasFiles = (dt: DataTransfer | null) =>
		Boolean(opts.onFiles) && dt?.types.includes("Files");
	return [
		// The caret that tracks the pointer so you can see where the drop will land.
		// CodeMirror's default is black, invisible on the dark theme.
		dropCursor(),
		EditorView.baseTheme({ ".cm-dropCursor": { borderLeft: "2px solid var(--primary)" } }),
		EditorView.domEventHandlers({
			dragover(event) {
				const dt = event.dataTransfer;
				if (!(dt?.types.includes(VAULT_ITEM_MIME) || hasFiles(dt))) {
					return false;
				}
				event.preventDefault();
				if (dt) {
					dt.dropEffect = "copy";
				}
				return true;
			},
			drop(event, view) {
				const files = Array.from(event.dataTransfer?.files ?? []);
				if (opts.onFiles && files.length > 0) {
					event.preventDefault();
					const at =
						view.posAtCoords({ x: event.clientX, y: event.clientY }) ?? view.state.doc.length;
					// ponytail: the position is not tracked through edits made during the
					// upload; it is only clamped to the document. Map it through the changes
					// if drops into busy notes land in the wrong place.
					opts
						.onFiles(files)
						.then((links) => {
							if (links.length === 0) {
								return;
							}
							const text = links.join("\n");
							const pos = Math.min(at, view.state.doc.length);
							view.dispatch({
								changes: { from: pos, insert: text },
								selection: { anchor: pos + text.length },
								userEvent: "input.drop",
							});
						})
						.catch(() => undefined);
					return true;
				}
				const item = readDraggedItem(event.dataTransfer);
				if (!item) {
					return false;
				}
				// preventDefault stops CodeMirror also inserting the dragged link's URL text.
				event.preventDefault();
				const pos =
					view.posAtCoords({ x: event.clientX, y: event.clientY }) ?? view.state.doc.length;
				const text = opts.linkText(item);
				view.dispatch({
					changes: { from: pos, insert: text },
					selection: { anchor: pos + text.length },
					userEvent: "input.drop",
				});
				view.focus();
				return true;
			},
		}),
	];
}
