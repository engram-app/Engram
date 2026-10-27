import { useEffect, useState } from "react";

/**
 * Where the on-screen keyboard is, read from `window.visualViewport`.
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

/** How long to keep sampling after a keyboard-shaped event. The iOS keyboard
 *  animates for ~300ms and the QuickType row can arrive after it. */
const SETTLE_MS = 600;

/**
 * Subscribe `read` to the visual viewport, and keep sampling it every frame
 * for SETTLE_MS after each change or focus move.
 *
 * Events alone are not enough on iOS: rows that appear or grow above the
 * keyboard after it opens (QuickType, AutoFill, the accessory bar) can change
 * the visual viewport without firing a resize. The per-frame sampling costs
 * one layout read per frame, and only while the keyboard is moving.
 */
function useViewportValue<T>(read: () => T, same: (a: T, b: T) => boolean, enabled: boolean): T {
	const [value, setValue] = useState(read);

	useEffect(() => {
		const vv = window.visualViewport;
		if (!(enabled && vv)) {
			return;
		}
		const update = () => {
			const next = read();
			setValue((prev) => (same(prev, next) ? prev : next));
		};
		let raf = 0;
		let until = 0;
		const tick = () => {
			update();
			raf = performance.now() < until ? requestAnimationFrame(tick) : 0;
		};
		const settle = () => {
			update();
			until = performance.now() + SETTLE_MS;
			if (!raf) {
				raf = requestAnimationFrame(tick);
			}
		};
		// resize fires when the keyboard opens/closes; scroll fires when the
		// visual viewport pans under it, which changes offsetTop even though
		// nothing resized. Focus moving is when the keyboard is about to move.
		// Read once now: a hook re-enabled (crossing the desktop breakpoint)
		// would otherwise hold the value from mount until the next event.
		update();
		vv.addEventListener("resize", settle);
		vv.addEventListener("scroll", settle);
		document.addEventListener("focusin", settle);
		document.addEventListener("focusout", settle);
		return () => {
			cancelAnimationFrame(raf);
			vv.removeEventListener("resize", settle);
			vv.removeEventListener("scroll", settle);
			document.removeEventListener("focusin", settle);
			document.removeEventListener("focusout", settle);
		};
		// `read` and `same` are module-level functions, stable across renders.
	}, [read, same, enabled]);

	return value;
}

const sameBox = (a: ViewportBox, b: ViewportBox) => a.top === b.top && a.height === b.height;

/** The part of the window the user can actually see, in layout-viewport px. */
export interface ViewportBox {
	top: number;
	height: number;
}

/**
 * The visual viewport's top and height: the visible area above the keyboard
 * and whatever rows iOS stacks on it.
 *
 * This replaces lifting a bottom-pinned bar by a computed inset. On iOS 26 a
 * fixed element moved with a transform drifts out of step with the visual
 * viewport when the keyboard opens, closes or the viewport scrolls (WebKit
 * bugs 297779 and 300523); a fixed frame sized to this box does not. On
 * Android with `interactive-widget=resizes-content` the layout viewport
 * shrinks too, `offsetTop` is 0 and `height` is the shrunk window, so the same
 * box is right there as well.
 */
export function readViewportBox(): ViewportBox {
	if (typeof window === "undefined") {
		return { top: 0, height: 0 };
	}
	if (devKeyboardFlag()) {
		return { top: 0, height: window.innerHeight - DEV_INSET_PX };
	}
	const vv = window.visualViewport;
	return vv ? { top: vv.offsetTop, height: vv.height } : { top: 0, height: window.innerHeight };
}

/** The visible area, live. See readViewportBox. */
export function useVisualViewportBox(enabled = true): ViewportBox {
	return useViewportValue(readViewportBox, sameBox, enabled);
}

/**
 * Whether the on-screen keyboard is up.
 *
 * Deliberately NOT "the visible box is shorter than the window": on browsers
 * that resize the layout viewport the two are equal with the keyboard open, which is why the
 * toolbar used to gate on focus alone — and that in turn left the bar stranded
 * over the document whenever the editor kept focus after the keyboard was
 * dismissed. This compares against the tallest viewport seen instead, which
 * shrinks under both models.
 */
export function useKeyboardOpen(enabled = true): boolean {
	return useViewportValue(readKeyboardOpen, Object.is, enabled);
}
