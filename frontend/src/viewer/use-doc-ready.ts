import { useCallback, useSyncExternalStore } from "react";
import type * as Y from "yjs";

/** True once an opened note doc holds its content.
 *
 *  A note with no local IndexedDB copy opens on an EMPTY doc, and the server's
 *  state lands a beat later in one update. Painting the editor in between shows
 *  a blank note, then the properties block arrives above it and shoves the body
 *  down: a layout shift (the mobile Lighthouse gate measured 0.146). So the page
 *  holds its placeholder until the doc has any content, unless the server
 *  says the note is empty, which is ready at once. */
export function useDocReady(doc: Y.Doc | null, expectContent: boolean): boolean {
	const subscribe = useCallback(
		(onChange: () => void) => {
			doc?.on("update", onChange);
			return () => doc?.off("update", onChange);
		},
		[doc],
	);
	return useSyncExternalStore(
		subscribe,
		() => doc !== null && (!expectContent || doc.store.clients.size > 0),
	);
}
