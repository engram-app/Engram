import { useEffect, useState } from "react";

/**
 * Height in px the on-screen keyboard covers at the bottom of the viewport,
 * or 0 when it's down.
 *
 * This is the ONLY part of the keyboard toolbar that depends on the real
 * device. Isolating it to a number means every consumer is testable by passing
 * one in — no desktop browser has a soft keyboard, and CDP device emulation
 * doesn't simulate one either (visualViewport never shrinks under it), so
 * without this seam the toolbar could not be exercised anywhere we develop.
 */

/** Simulated keyboard height for `?keyboard` in dev. Roughly an iPhone's. */
const DEV_INSET_PX = 300;

/**
 * Below this we assume browser chrome, not a keyboard. Mobile Safari's
 * collapsing address bar moves visualViewport by ~60-90px during scroll, and
 * treating that as a keyboard would flash the toolbar on every swipe.
 */
const KEYBOARD_MIN_PX = 120;

function devKeyboardFlag(): boolean {
	// Dev-only escape hatch so the bar can be driven and screenshotted in a
	// desktop browser at mobile width. Never reachable in a production build.
	return import.meta.env.DEV && new URLSearchParams(window.location.search).has("keyboard");
}

/**
 * Tallest visual-viewport height seen at the current width.
 *
 * The keyboard makes the visual viewport SHORTER under both browser models —
 * the ones that resize only the visual viewport, and the ones that resize the
 * layout viewport with it — so a drop from the tallest height seen is the one
 * signal that means "keyboard is up" everywhere. The inset alone is not: it is
 * legitimately 0 on the second kind.
 *
 * Keyed by width so a rotation starts a fresh baseline instead of comparing
 * portrait against landscape.
 */
let tallest = { width: 0, height: 0 };

function readKeyboardOpen(): boolean {
	if (typeof window === "undefined") {
		return false;
	}
	if (devKeyboardFlag()) {
		return true;
	}
	const vv = window.visualViewport;
	if (!vv) {
		return false;
	}
	if (vv.width !== tallest.width || vv.height > tallest.height) {
		tallest = { width: vv.width, height: vv.height };
	}
	return tallest.height - vv.height >= KEYBOARD_MIN_PX;
}

function readInset(): number {
	if (typeof window === "undefined") {
		return 0;
	}
	if (devKeyboardFlag()) {
		return DEV_INSET_PX;
	}
	const vv = window.visualViewport;
	if (!vv) {
		return 0;
	}
	// What the layout viewport has that the visual one doesn't, below the fold.
	// offsetTop matters when the page is pinch-zoomed or scrolled under the
	// keyboard; without it the inset reads short and the bar sits too low.
	const obscured = window.innerHeight - (vv.height + vv.offsetTop);
	return obscured >= KEYBOARD_MIN_PX ? Math.round(obscured) : 0;
}

/** Subscribe `read` to the visual viewport's resize/scroll events. */
function useViewportValue<T>(read: () => T): T {
	const [value, setValue] = useState(read);

	useEffect(() => {
		const vv = window.visualViewport;
		if (!vv) {
			return;
		}
		const update = () => setValue(read());
		// resize fires when the keyboard opens/closes; scroll fires when the
		// visual viewport pans under it, which changes offsetTop and therefore
		// the inset even though nothing resized.
		vv.addEventListener("resize", update);
		vv.addEventListener("scroll", update);
		return () => {
			vv.removeEventListener("resize", update);
			vv.removeEventListener("scroll", update);
		};
		// `read` is a module-level function, stable across renders.
	}, [read]);

	return value;
}

export function useKeyboardInset(): number {
	return useViewportValue(readInset);
}

/**
 * Whether the on-screen keyboard is up.
 *
 * Deliberately NOT `useKeyboardInset() > 0`: on browsers that resize the layout
 * viewport the inset is 0 with the keyboard fully open, which is why the
 * toolbar used to gate on focus alone — and that in turn left the bar stranded
 * over the document whenever the editor kept focus after the keyboard was
 * dismissed. This compares against the tallest viewport seen instead, which
 * shrinks under both models.
 */
export function useKeyboardOpen(): boolean {
	return useViewportValue(readKeyboardOpen);
}
