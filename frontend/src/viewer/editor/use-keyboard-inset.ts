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

function readInset(): number {
	if (typeof window === "undefined") {
		return 0;
	}
	// Dev-only escape hatch so the bar can be driven and screenshotted in a
	// desktop browser at mobile width. Never reachable in a production build.
	if (import.meta.env.DEV && new URLSearchParams(window.location.search).has("keyboard")) {
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

export function useKeyboardInset(): number {
	const [inset, setInset] = useState(readInset);

	useEffect(() => {
		const vv = window.visualViewport;
		if (!vv) {
			return;
		}
		const update = () => setInset(readInset());
		// resize fires when the keyboard opens/closes; scroll fires when the
		// visual viewport pans under it, which changes offsetTop and therefore
		// the inset even though nothing resized.
		vv.addEventListener("resize", update);
		vv.addEventListener("scroll", update);
		return () => {
			vv.removeEventListener("resize", update);
			vv.removeEventListener("scroll", update);
		};
	}, []);

	return inset;
}
