import { useEffect, useState } from "react";
import type * as Y from "yjs";

/**
 * Whether a live Y.Text currently holds anything, tracked on every doc update.
 *
 * Deliberately NOT `useLiveContent`, which debounces by 300ms: this drives the
 * swap from the read-only seed to the real editor, so a debounce here would
 * delay the moment the note becomes editable. It answers a boolean, so it
 * re-renders only on the empty↔non-empty transition rather than per keystroke.
 */
export function useDocHasContent(ytext: Y.Text | null): boolean {
	const [hasContent, setHasContent] = useState(() => (ytext ? ytext.length > 0 : false));

	useEffect(() => {
		if (!ytext) {
			setHasContent(false);
			return;
		}
		setHasContent(ytext.length > 0);
		const onUpdate = () => setHasContent(ytext.length > 0);
		const { doc } = ytext;
		doc?.on("update", onUpdate);
		return () => {
			doc?.off("update", onUpdate);
		};
	}, [ytext]);

	return hasContent;
}
