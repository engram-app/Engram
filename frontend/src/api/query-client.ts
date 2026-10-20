import {
	MutationCache,
	type MutationCacheNotifyEvent,
	type Query,
	type QueryCacheNotifyEvent,
	QueryClient,
} from "@tanstack/react-query";
import {
	discardRetriedFailure,
	noteEarlierAttempts,
	type QueryAttempt,
	runInQueryAttempt,
} from "./client";

// Each query's latest attempt, so its `failed` event can mark it retried.
const attempts = new WeakMap<Query, QueryAttempt>();

const queryClient = new QueryClient({
	// A mutation's final failure counts its earlier tries in `attempt`. This
	// onError runs synchronously in the rejection, before the report's timer,
	// and failureCount does not yet include the final failure.
	mutationCache: new MutationCache({
		onError: (error, _variables, _context, mutation) =>
			noteEarlierAttempts(error, mutation.state.failureCount),
	}),
	defaultOptions: {
		queries: {
			staleTime: 30_000,
			retry: 1,
			// Runs every queryFn attempt inside a QueryAttempt (client.ts), so a
			// retried attempt's request failures are dropped however the queryFn
			// combined or wrapped them. React Query's own hook for wrapping the
			// fetch (infinite queries replace it; this app has none).
			behavior: {
				onFetch: (context, query) => {
					const { fetchFn } = context;
					context.fetchFn = () => {
						// Reset to 0 by each fetch, raised by each retried failure.
						const attempt = { earlier: query.state.fetchFailureCount, retried: false };
						attempts.set(query, attempt);
						return runInQueryAttempt(attempt, fetchFn);
					};
				},
			},
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
queryClient.getQueryCache().subscribe((event) => {
	if (event.type === "updated" && event.action.type === "failed") {
		const attempt = attempts.get(event.query);
		if (attempt) {
			attempt.retried = true;
		}
	}
	discardIfRetrying(event);
});
queryClient.getMutationCache().subscribe(discardIfRetrying);

export { queryClient };
