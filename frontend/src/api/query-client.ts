import {
	MutationCache,
	type MutationCacheNotifyEvent,
	QueryCache,
	type QueryCacheNotifyEvent,
	QueryClient,
} from "@tanstack/react-query";
import { discardRetriedFailure, noteEarlierAttempts } from "./client";

// A final failure's report counts React Query's earlier tries in `attempt`.
// Both onErrors run synchronously in the rejection, before the report's timer.
// A query's fetchFailureCount already includes the final failure; a
// mutation's failureCount does not yet.
const queryClient = new QueryClient({
	queryCache: new QueryCache({
		onError: (error, query) => noteEarlierAttempts(error, query.state.fetchFailureCount - 1),
	}),
	mutationCache: new MutationCache({
		onError: (error, _variables, _context, mutation) =>
			noteEarlierAttempts(error, mutation.state.failureCount),
	}),
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
