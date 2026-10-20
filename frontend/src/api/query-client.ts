import {
	type MutationCacheNotifyEvent,
	type QueryCacheNotifyEvent,
	QueryClient,
} from "@tanstack/react-query";
import { discardRetriedFailure } from "./client";

const queryClient = new QueryClient({
	defaultOptions: {
		queries: {
			staleTime: 30_000,
			retry: 1,
		},
	},
});

// A `failed` action means "this attempt failed and a retry is coming"; the
// final failure dispatches `error` instead. Cache listeners run synchronously
// inside the rejection, before the api client's deferred report fires.
function discardIfRetrying(event: QueryCacheNotifyEvent | MutationCacheNotifyEvent) {
	if (event.type === "updated" && event.action.type === "failed") {
		discardRetriedFailure(event.action.error);
	}
}
queryClient.getQueryCache().subscribe(discardIfRetrying);
queryClient.getMutationCache().subscribe(discardIfRetrying);

export { queryClient };
