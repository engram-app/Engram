import { useCallback, useSyncExternalStore } from "react";
import type * as Y from "yjs";

/**
 * Whether a live Y.Text currently holds anything.
 *
 * `useSyncExternalStore`, not state-in-an-effect: an effect only corrects the
 * value AFTER the first commit, so a note switch would render one frame using
 * the PREVIOUS note's doc state — long enough to flash the seed over a warm
 * note, or the blank editor over a cold one. This reads the live doc during
 * render, so the first frame is already right.
 *
 * Deliberately not `useLiveContent`, which debounces by 300ms: this drives the
 * handover to the real editor, and a debounce would delay editability.
 */
export function useDocHasContent(ytext: Y.Text | null): boolean {
	const subscribe = useCallback(
		(onChange: () => void) => {
			const doc = ytext?.doc;
			if (!doc) {
				return () => undefined;
			}
			doc.on("update", onChange);
			return () => doc.off("update", onChange);
		},
		[ytext],
	);
	const getSnapshot = useCallback(() => (ytext ? ytext.length > 0 : false), [ytext]);
	return useSyncExternalStore(subscribe, getSnapshot, getSnapshot);
}
