import { useEffect, useRef } from "react";
import { wipeCrdtIndexedDb } from "../crdt/idb-wipe";

/** Delete all CRDT IndexedDB content when the authenticated user changes
 *  (switch or logout). Mirrors useClearQueryCacheOnUserChange: skips first
 *  mount, fires on any subsequent identity change. Fire-and-forget — the
 *  channel teardown (useChannel cleanup → stopCrdtSession) closes live DB
 *  connections in parallel; deleteDatabase resolves best-effort on blocked. */
export function useWipeCrdtOnUserChange(userId: string | undefined): void {
	const prevRef = useRef<string | undefined>(undefined);
	useEffect(() => {
		if (prevRef.current === userId) {
			return;
		}
		if (prevRef.current !== undefined) {
			wipeCrdtIndexedDb().catch((e) => console.warn("CRDT IndexedDB wipe failed", e));
		}
		prevRef.current = userId;
	}, [userId]);
}
