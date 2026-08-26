import { useCallback, useSyncExternalStore } from "react";

const supported = () => typeof window !== "undefined" && typeof window.matchMedia === "function";

/**
 * SSR-safe matchMedia hook. Returns `false` on the server (no matchMedia),
 * then re-renders with the real value on mount.
 *
 * useSyncExternalStore, not useState + useEffect: matchMedia IS an external
 * store, and reading it during render removes the one-frame window where the
 * hook reported a stale `false` before the mount effect corrected it.
 */
export function useMediaQuery(query: string): boolean {
	const subscribe = useCallback(
		(onChange: () => void) => {
			if (!supported()) {
				return () => {};
			}
			const mql = window.matchMedia(query);
			mql.addEventListener("change", onChange);
			return () => mql.removeEventListener("change", onChange);
		},
		[query],
	);

	const getSnapshot = useCallback(
		() => (supported() ? window.matchMedia(query).matches : false),
		[query],
	);

	return useSyncExternalStore(subscribe, getSnapshot, () => false);
}
