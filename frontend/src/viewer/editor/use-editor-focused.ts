import { useEffect, useState } from "react";

/**
 * True while focus is inside a CodeMirror editor — i.e. while the on-screen
 * keyboard is up on a touch device.
 *
 * This, not the keyboard inset, is what gates the mobile toolbar. Browsers
 * disagree about which viewport the keyboard resizes: where only the VISUAL
 * viewport shrinks (iOS Safari, Chrome 108+) the inset is the keyboard's
 * height, but where the LAYOUT viewport shrinks too (older Chrome, or any
 * browser with `interactive-widget=resizes-content`) window.innerHeight drops
 * by the same amount and the inset is legitimately 0 with the keyboard fully
 * open. Gating on a non-zero inset therefore hides the bar on exactly those
 * browsers. Focus means the same thing everywhere.
 */
export function useEditorFocused(): boolean {
	const [focused, setFocused] = useState(false);

	useEffect(() => {
		const isInEditor = () => Boolean(document.activeElement?.closest(".cm-editor"));
		const sync = () => setFocused(isInEditor());
		sync();
		// focusin/focusout bubble (focus/blur do not), so one document-level pair
		// covers every editor instance without per-view wiring.
		document.addEventListener("focusin", sync);
		document.addEventListener("focusout", sync);
		return () => {
			document.removeEventListener("focusin", sync);
			document.removeEventListener("focusout", sync);
		};
	}, []);

	return focused;
}
