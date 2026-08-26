import { useEffect, useState } from "react";
import type * as Y from "yjs";

const DEBOUNCE_MS = 300;

/** The current string content of a live Y.Text, re-read (debounced) on every
 *  doc update — local AND remote origins, because the reading view must
 *  reflect both. Falls back to `fallback` (the REST-materialized content)
 *  while no doc handle exists. */
export function useLiveContent(ytext: Y.Text | null, fallback: string): string {
	const [text, setText] = useState<string>(() => (ytext ? ytext.toString() : fallback));

	useEffect(() => {
		if (!ytext) {
			// biome-ignore lint/nursery/useReactCompiler: this effect IS the external-system subscription the rule asks for -- it observes a Y.Text. The write is the debounced re-read; a synchronous getSnapshot (useSyncExternalStore) would drop the debounce and re-render the reading view on every keystroke.
			setText(fallback);
			return;
		}
		setText(ytext.toString());
		let timer: ReturnType<typeof setTimeout> | null = null;
		const onUpdate = () => {
			if (timer) {
				return;
			}
			timer = setTimeout(() => {
				timer = null;
				setText(ytext.toString());
			}, DEBOUNCE_MS);
		};
		const { doc } = ytext;
		doc?.on("update", onUpdate);
		return () => {
			doc?.off("update", onUpdate);
			if (timer) {
				clearTimeout(timer);
			}
		};
	}, [ytext, fallback]);

	return text;
}
