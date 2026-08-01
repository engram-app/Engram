import { defaultKeymap } from "@codemirror/commands";
import { yaml } from "@codemirror/lang-yaml";
import { EditorState } from "@codemirror/state";
import { EditorView, keymap } from "@codemirror/view";
import { useEffect, useRef, useState } from "react";
import type * as Y from "yjs";
import { parseFrontmatter } from "../../crdt/frontmatter-codec";
import {
	applyParsedFrontmatter,
	emitFrontmatterText,
	frontmatterMaps,
} from "../../crdt/frontmatter-doc";

export const COMMIT_DEBOUNCE_MS = 400;

/**
 * Parse `text` as a frontmatter block and apply it to the doc's frontmatter
 * Y.Map. Returns "invalid" and leaves the Y.Map untouched on a parse
 * failure — last-valid state stays authoritative until the user fixes the
 * YAML.
 */
export function commitYaml(doc: Y.Doc, text: string): "ok" | "invalid" {
	const block = text.endsWith("\n") ? text : `${text}\n`;
	const parsed = parseFrontmatter(block);
	if (parsed === null) {
		return "invalid";
	}
	applyParsedFrontmatter(doc, parsed);
	return "ok";
}

export function RawFrontmatterEditor({ doc }: { doc: Y.Doc }) {
	const hostRef = useRef<HTMLDivElement>(null);
	const viewRef = useRef<EditorView | null>(null);
	const [invalid, setInvalid] = useState(false);
	const timer = useRef<ReturnType<typeof setTimeout> | null>(null);

	useEffect(() => {
		const parent = hostRef.current;
		if (!parent) {
			return;
		}

		const view = new EditorView({
			state: EditorState.create({
				doc: emitFrontmatterText(doc),
				extensions: [
					yaml(),
					keymap.of(defaultKeymap),
					EditorView.updateListener.of((update) => {
						if (!update.docChanged) {
							return;
						}
						if (timer.current) {
							clearTimeout(timer.current);
						}
						const text = update.state.doc.toString();
						timer.current = setTimeout(() => {
							setInvalid(commitYaml(doc, text) === "invalid");
						}, COMMIT_DEBOUNCE_MS);
					}),
				],
			}),
			parent,
		});
		viewRef.current = view;

		// Re-seed from the maps on remote changes, but only while the editor is
		// unfocused — otherwise a remote pill edit yanks the caret mid-type.
		// Local edits always win over a re-seed.
		const { values, order } = frontmatterMaps(doc);
		const refresh = () => {
			const { current } = viewRef;
			if (!current || current.hasFocus) {
				return;
			}
			const next = emitFrontmatterText(doc);
			if (next !== current.state.doc.toString()) {
				current.dispatch({
					changes: { from: 0, to: current.state.doc.length, insert: next },
				});
			}
		};
		values.observeDeep(refresh);
		order.observe(refresh);

		return () => {
			values.unobserveDeep(refresh);
			order.unobserve(refresh);
			if (timer.current) {
				clearTimeout(timer.current);
			}
			view.destroy();
			viewRef.current = null;
		};
	}, [doc]);

	return (
		<section aria-label="Frontmatter (raw YAML)" className="border-b">
			<div className="select-none px-3 pt-2 font-mono text-muted-foreground text-xs">---</div>
			<div ref={hostRef} className="px-1" />
			<div className="select-none px-3 pb-2 font-mono text-muted-foreground text-xs">---</div>
			{invalid ? (
				<p className="px-3 pb-1 text-destructive text-xs">Invalid YAML — not saved yet</p>
			) : null}
		</section>
	);
}
