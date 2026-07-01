import type { QueryClient } from "@tanstack/react-query";
import { useEffect, useRef } from "react";

// Wipe the React Query cache whenever the signed-in user changes. The cache is
// a module singleton (api/query-client.ts) and survives Clerk sign-out, so
// without this, a sign-out → sign-up in the same tab serves the previous
// account's cached `/api/onboarding/status` (`staleTime: Infinity`) to the new
// user and the onboarding gate lets them straight into the vault. Only clear
// on transitions away from a previously-known identity; first-mount and
// first-sign-in shouldn't fire (there's nothing to wipe).
export function useClearQueryCacheOnUserChange(
	queryClient: QueryClient,
	userId: string | undefined,
): void {
	const prevRef = useRef<string | undefined>(undefined);
	useEffect(() => {
		if (prevRef.current === userId) return;
		if (prevRef.current !== undefined) queryClient.clear();
		prevRef.current = userId;
	}, [queryClient, userId]);
}
