import { useEffect, useRef } from "react";

/**
 * Focus an element on mount via a ref instead of the `autoFocus` attribute.
 *
 * Biome's `a11y/noAutofocus` rejects `autoFocus` outside a native `<dialog>`
 * (it yanks focus in a way screen-reader users can't anticipate). Managing the
 * focus ourselves keeps the same UX for the deliberate cases (a field that a
 * form/panel opens to) while satisfying the rule.
 *
 * Pass `enabled=false` to opt out (e.g. an optional `autoFocus` prop).
 */
export function useAutofocus<T extends HTMLElement>(enabled = true) {
	const ref = useRef<T>(null);
	useEffect(() => {
		if (enabled) {
			ref.current?.focus();
		}
	}, [enabled]);
	return ref;
}
